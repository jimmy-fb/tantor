"""Manages Prometheus + Grafana installation and exporter deployment."""

import json
import logging
import os
import platform
import signal
import shutil
import subprocess
from pathlib import Path

from sqlalchemy.orm import Session

from app.config import settings
from app.models.cluster import Cluster
from app.models.host import Host
from app.models.monitoring import MonitoringConfig
from app.models.service import Service
from app.services.ssh_manager import SSHManager

logger = logging.getLogger("tantor.monitoring")

# In-memory task tracking for install/deploy
_monitoring_tasks: dict[str, dict] = {}

# Track background processes started without systemd
_bg_processes: dict[str, subprocess.Popen] = {}


def _is_systemd_available() -> bool:
    """Check if systemd is actually functional (not just installed)."""
    try:
        result = subprocess.run(
            ["systemctl", "is-system-running"],
            capture_output=True, text=True, timeout=5,
        )
        # Returns 'running', 'degraded', etc. on real systemd; fails otherwise
        return result.returncode == 0 or result.stdout.strip() in ("running", "degraded")
    except Exception:
        return False


def _start_service(name: str, binary: str, args: list[str] | None = None, log_file: str | None = None):
    """Start a service — tries systemctl, falls back to direct background process."""
    if _is_systemd_available():
        subprocess.run(f"systemctl enable {name}", shell=True, capture_output=True, timeout=30)
        subprocess.run(f"systemctl start {name}", shell=True, capture_output=True, timeout=30)
    else:
        # Kill any existing process
        _stop_service(name, binary)
        # Start as background process
        cmd = [binary] + (args or [])
        log_path = log_file or f"/tmp/{name}.log"
        log_fh = open(log_path, "a")
        proc = subprocess.Popen(
            cmd, stdout=log_fh, stderr=log_fh,
            start_new_session=True,
        )
        _bg_processes[name] = proc
        logger.info(f"Started {name} (PID {proc.pid}), log: {log_path}")


def _stop_service(name: str, binary: str):
    """Stop a service — tries systemctl, falls back to killing process."""
    if _is_systemd_available():
        subprocess.run(f"systemctl stop {name}", shell=True, capture_output=True, timeout=30)
    else:
        # Kill existing background process
        if name in _bg_processes:
            try:
                _bg_processes[name].terminate()
                _bg_processes[name].wait(timeout=5)
            except Exception:
                _bg_processes[name].kill()
            del _bg_processes[name]
        # Also kill by binary name
        subprocess.run(f"pkill -f {binary}", shell=True, capture_output=True, timeout=5)


def _is_service_running(name: str, port: int) -> bool:
    """Check if a service is running — tries systemctl, falls back to port check."""
    if _is_systemd_available():
        try:
            result = subprocess.run(
                ["systemctl", "is-active", name],
                capture_output=True, text=True, timeout=5,
            )
            return result.stdout.strip() == "active"
        except Exception:
            return False
    else:
        # Check if process is alive via bg_processes or port check
        if name in _bg_processes and _bg_processes[name].poll() is None:
            return True
        # Check port
        try:
            import socket
            s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            s.settimeout(1)
            s.connect(("127.0.0.1", port))
            s.close()
            return True
        except Exception:
            return False


def _detect_os_family() -> str:
    """Detect OS family from /etc/os-release → 'debian', 'redhat', 'suse', or 'unknown'."""
    try:
        os_release = Path("/etc/os-release").read_text()
        os_id = ""
        id_like = ""
        for line in os_release.splitlines():
            if line.startswith("ID="):
                os_id = line.split("=", 1)[1].strip().strip('"').lower()
            elif line.startswith("ID_LIKE="):
                id_like = line.split("=", 1)[1].strip().strip('"').lower()
        combined = f"{os_id} {id_like}"
        if any(d in combined for d in ("debian", "ubuntu")):
            return "debian"
        if any(d in combined for d in ("rhel", "centos", "fedora", "rocky", "alma", "amzn", "redhat")):
            return "redhat"
        if any(d in combined for d in ("suse", "sles", "opensuse")):
            return "suse"
    except FileNotFoundError:
        pass
    # Fallback: check package managers
    if shutil.which("apt-get"):
        return "debian"
    if shutil.which("dnf") or shutil.which("yum"):
        return "redhat"
    if shutil.which("zypper"):
        return "suse"
    return "unknown"


def get_monitoring_task(task_id: str) -> dict | None:
    return _monitoring_tasks.get(task_id)


def init_monitoring_task(task_id: str):
    _monitoring_tasks[task_id] = {"task_id": task_id, "status": "running", "logs": []}


class MonitoringManager:
    """Manages Prometheus + Grafana installation on Tantor server
    and exporter deployment to cluster hosts."""

    @staticmethod
    def _log(task_id: str, message: str):
        task = _monitoring_tasks.get(task_id)
        if task:
            task["logs"].append(message)
        logger.info(message)

    @staticmethod
    def get_or_create_config(db: Session) -> MonitoringConfig:
        config = db.query(MonitoringConfig).first()
        if not config:
            config = MonitoringConfig()
            db.add(config)
            db.commit()
            db.refresh(config)
        return config

    @staticmethod
    def get_monitoring_status(db: Session) -> dict:
        """Check if Prometheus/Grafana are installed and running."""
        config = MonitoringManager.get_or_create_config(db)

        prom_running = _is_service_running("prometheus", config.prometheus_port) if config.prometheus_installed else False
        grafana_running = _is_service_running("grafana-server", config.grafana_port) if config.grafana_installed else False

        return {
            "prometheus_installed": config.prometheus_installed,
            "grafana_installed": config.grafana_installed,
            "prometheus_running": prom_running,
            "grafana_running": grafana_running,
            "prometheus_port": config.prometheus_port,
            "grafana_port": config.grafana_port,
            "grafana_url": config.grafana_url,
            "prometheus_url": config.prometheus_url,
        }

    @staticmethod
    def install_prometheus_grafana(task_id: str, db: Session):
        """Install Prometheus and Grafana on the local Tantor server."""
        log = lambda msg: MonitoringManager._log(task_id, msg)  # noqa: E731
        config = MonitoringManager.get_or_create_config(db)

        try:
            # Detect OS family
            os_family = _detect_os_family()
            log(f"Detected OS family: {os_family}")

            if os_family == "unknown":
                log("ERROR: Unsupported OS. Supported: Debian/Ubuntu, RHEL/CentOS/Rocky/Alma/Fedora, SUSE")
                _monitoring_tasks[task_id]["status"] = "error"
                return

            # Install Prometheus
            if not config.prometheus_installed:
                log("Installing Prometheus...")
                prom_bin = None

                if os_family == "debian":
                    # ── Debian / Ubuntu — install from apt ──
                    cmds = [
                        "apt-get update -qq",
                        "apt-get install -y prometheus",
                    ]
                    for cmd in cmds:
                        log(f"  $ {cmd}")
                        result = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=300)
                        if result.returncode != 0:
                            log(f"  Warning: {result.stderr[:200]}")
                    prom_bin = shutil.which("prometheus") or (
                        "/usr/bin/prometheus" if Path("/usr/bin/prometheus").exists() else None
                    )

                else:
                    # ── RHEL / SUSE — install from official tarball ──
                    prom_version = getattr(settings, "PROMETHEUS_VERSION", "2.51.0")
                    arch = platform.machine()
                    if arch == "x86_64":
                        arch = "amd64"
                    elif arch == "aarch64":
                        arch = "arm64"

                    tarball_name = f"prometheus-{prom_version}.linux-{arch}.tar.gz"
                    local_tarball = Path(settings.MONITORING_REPO_DIR) / tarball_name

                    cmds = ["mkdir -p /opt/prometheus /etc/prometheus /var/lib/prometheus"]
                    if local_tarball.exists():
                        log(f"  Using local tarball: {tarball_name}")
                        cmds.append(
                            f"tar xzf {local_tarball} -C /opt/prometheus --strip-components=1"
                        )
                    else:
                        url = (
                            f"https://github.com/prometheus/prometheus/releases/"
                            f"download/v{prom_version}/{tarball_name}"
                        )
                        log(f"  Downloading Prometheus {prom_version} from GitHub...")
                        cmds.append(
                            f"cd /tmp && wget -q {url} && "
                            f"tar xzf {tarball_name} -C /opt/prometheus --strip-components=1 && "
                            f"rm -f {tarball_name}"
                        )

                    for cmd in cmds:
                        log(f"  $ {cmd}")
                        result = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=300)
                        if result.returncode != 0:
                            log(f"  Warning: {result.stderr[:200]}")

                    # Create default prometheus.yml if not present
                    prom_config_path = Path("/etc/prometheus/prometheus.yml")
                    if not prom_config_path.exists():
                        prom_config_path.write_text(
                            "global:\n"
                            "  scrape_interval: 15s\n"
                            "  evaluation_interval: 15s\n\n"
                            "scrape_configs:\n"
                            "  - job_name: 'prometheus'\n"
                            "    static_configs:\n"
                            "      - targets: ['localhost:9090']\n"
                        )

                    prom_bin = (
                        "/opt/prometheus/prometheus"
                        if Path("/opt/prometheus/prometheus").exists()
                        else shutil.which("prometheus")
                    )

                if prom_bin:
                    _start_service(
                        "prometheus", prom_bin,
                        args=["--config.file=/etc/prometheus/prometheus.yml",
                              "--storage.tsdb.path=/var/lib/prometheus/metrics2/"],
                        log_file="/var/log/prometheus.log",
                    )
                    config.prometheus_installed = True
                    db.commit()
                    log("Prometheus installed and started")
                else:
                    log("ERROR: Prometheus binary not found after install")
                    _monitoring_tasks[task_id]["status"] = "error"
                    return
            else:
                log("Prometheus already installed, skipping")

            # Install Grafana
            if not config.grafana_installed:
                log("Installing Grafana...")

                if os_family == "debian":
                    # ── Debian / Ubuntu — install from Grafana apt repo ──
                    cmds = [
                        "apt-get install -y apt-transport-https",
                        "mkdir -p /etc/apt/keyrings/",
                        "wget -q -O - https://apt.grafana.com/gpg.key | gpg --batch --dearmor -o /etc/apt/keyrings/grafana.gpg",
                        'echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" > /etc/apt/sources.list.d/grafana.list',
                        "apt-get update",
                        "apt-get install -y grafana",
                    ]
                elif os_family == "redhat":
                    # ── RHEL / CentOS / Rocky / Alma / Fedora — Grafana RPM repo ──
                    grafana_repo = (
                        "[grafana]\n"
                        "name=Grafana OSS\n"
                        "baseurl=https://rpm.grafana.com\n"
                        "repo_gpgcheck=1\n"
                        "enabled=1\n"
                        "gpgcheck=1\n"
                        "gpgkey=https://rpm.grafana.com/gpg.key\n"
                        "sslverify=1\n"
                        "sslcacert=/etc/pki/tls/certs/ca-bundle.crt\n"
                    )
                    repo_path = Path("/etc/yum.repos.d/grafana.repo")
                    repo_path.parent.mkdir(parents=True, exist_ok=True)
                    repo_path.write_text(grafana_repo)
                    log("  Added Grafana RPM repository")
                    cmds = [
                        "dnf install -y grafana || yum install -y grafana",
                    ]
                else:
                    # ── SUSE — Grafana via zypper ──
                    cmds = [
                        "rpm --import https://rpm.grafana.com/gpg.key",
                        "zypper addrepo -f https://rpm.grafana.com grafana 2>/dev/null || true",
                        "zypper --no-gpg-checks install -y grafana",
                    ]

                for cmd in cmds:
                    log(f"  $ {cmd}")
                    result = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=300)
                    if result.returncode != 0:
                        log(f"  Warning: {result.stderr[:200]}")

                # Verify grafana binary exists and start it
                grafana_bin = shutil.which("grafana-server") or (
                    "/usr/sbin/grafana-server" if Path("/usr/sbin/grafana-server").exists() else None
                )
                if grafana_bin:
                    # Configure Grafana for anonymous/embedded access
                    conf_path = Path("/etc/grafana/grafana.ini")
                    if conf_path.exists():
                        log("Configuring Grafana for anonymous access and embedding...")
                        with open(conf_path, "a") as f:
                            f.write("\n[auth.anonymous]\nenabled = true\norg_role = Viewer\n\n[security]\nallow_embedding = true\n")

                    _start_service(
                        "grafana-server", grafana_bin,
                        args=["--config=/etc/grafana/grafana.ini", "--homepath=/usr/share/grafana"],
                        log_file="/var/log/grafana.log",
                    )

                    config.grafana_installed = True
                    db.commit()
                    log("Grafana installed and started")

                    # Provision dashboards
                    log("Provisioning Grafana dashboards...")
                    MonitoringManager.provision_grafana_dashboards()
                    log("Dashboards provisioned")
                else:
                    log("ERROR: Grafana binary not found after install. Check network access to apt.grafana.com")
                    _monitoring_tasks[task_id]["status"] = "error"
                    return
            else:
                log("Grafana already installed, skipping")

            _monitoring_tasks[task_id]["status"] = "completed"
            log("Monitoring infrastructure installation completed!")

        except Exception as e:
            log(f"ERROR: {e}")
            _monitoring_tasks[task_id]["status"] = "error"

    @staticmethod
    def provision_grafana_dashboards():
        """Copy pre-built Grafana dashboards to provisioning directory."""
        templates_dir = Path(__file__).parent.parent / "templates" / "monitoring" / "grafana"
        provisioning_dir = Path("/etc/grafana/provisioning")

        if not templates_dir.exists():
            logger.warning(f"Dashboard templates not found at {templates_dir}")
            return

        # Create provisioning directories
        dashboards_dir = provisioning_dir / "dashboards"
        datasources_dir = provisioning_dir / "datasources"

        for d in [dashboards_dir, datasources_dir]:
            d.mkdir(parents=True, exist_ok=True)

        # Copy dashboard provisioning config
        prov_config = """apiVersion: 1
providers:
  - name: 'Tantor'
    orgId: 1
    folder: 'Tantor'
    type: file
    options:
      path: /var/lib/grafana/dashboards/tantor
"""
        (dashboards_dir / "tantor.yml").write_text(prov_config)

        # Copy Prometheus datasource
        ds_config = """apiVersion: 1
datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://localhost:9090
    isDefault: true
"""
        (datasources_dir / "prometheus.yml").write_text(ds_config)

        # Copy dashboard JSON files
        dashboards_dest = Path("/var/lib/grafana/dashboards/tantor")
        dashboards_dest.mkdir(parents=True, exist_ok=True)

        for json_file in templates_dir.glob("*.json"):
            shutil.copy2(str(json_file), str(dashboards_dest / json_file.name))

        # Restart Grafana to pick up changes
        grafana_bin = shutil.which("grafana-server") or "/usr/sbin/grafana-server"
        _stop_service("grafana-server", grafana_bin)
        _start_service(
            "grafana-server", grafana_bin,
            args=["--config=/etc/grafana/grafana.ini", "--homepath=/usr/share/grafana"],
            log_file="/var/log/grafana.log",
        )

    @staticmethod
    def deploy_exporters_to_cluster(cluster_id: str, task_id: str, db: Session):
        """Deploy node_exporter + JMX exporter to all hosts in a cluster."""
        log = lambda msg: MonitoringManager._log(task_id, msg)  # noqa: E731

        try:
            cluster = db.query(Cluster).filter(Cluster.id == cluster_id).first()
            if not cluster:
                log("ERROR: Cluster not found")
                _monitoring_tasks[task_id]["status"] = "error"
                return

            services = db.query(Service).filter(Service.cluster_id == cluster_id).all()
            hosts = {h.id: h for h in db.query(Host).all()}

            unique_hosts = {}
            for svc in services:
                host = hosts.get(svc.host_id)
                if host and host.id not in unique_hosts:
                    unique_hosts[host.id] = {"host": host, "roles": []}
                if host:
                    unique_hosts[host.id]["roles"].append(svc.role)

            log(f"Deploying exporters to {len(unique_hosts)} host(s)...")

            for host_id, info in unique_hosts.items():
                host = info["host"]
                roles = info["roles"]
                log(f"\n--- {host.hostname} ({host.ip_address}) ---")

                try:
                    with SSHManager.connect(
                        host.ip_address, host.ssh_port, host.username,
                        host.auth_type, host.encrypted_credential,
                    ) as client:
                        # Install node_exporter
                        log("  Installing node_exporter...")
                        ne_version = getattr(settings, "NODE_EXPORTER_VERSION", "1.7.0")

                        # Detect target architecture
                        exit_code, arch_out, _ = SSHManager.exec_command(client, "uname -m", timeout=10)
                        target_arch = arch_out.strip()
                        if target_arch == "x86_64":
                            target_arch = "amd64"
                        elif target_arch == "aarch64":
                            target_arch = "arm64"

                        ne_tarball = f"node_exporter-{ne_version}.linux-{target_arch}.tar.gz"
                        ne_dir = f"node_exporter-{ne_version}.linux-{target_arch}"
                        local_ne = Path(settings.MONITORING_REPO_DIR) / ne_tarball

                        if local_ne.exists():
                            # Airgapped: copy from local repo via SFTP
                            log(f"  Using local binary: {ne_tarball}")
                            sftp = client.open_sftp()
                            sftp.put(str(local_ne), f"/tmp/{ne_tarball}")
                            sftp.close()
                            cmds = [
                                f"which node_exporter > /dev/null 2>&1 || (cd /tmp && "
                                f"tar xzf {ne_tarball} && "
                                f"sudo cp {ne_dir}/node_exporter /usr/local/bin/ && "
                                f"rm -rf {ne_dir} {ne_tarball})",
                            ]
                        else:
                            # Download from GitHub
                            cmds = [
                                f"which node_exporter > /dev/null 2>&1 || (cd /tmp && "
                                f"wget -q https://github.com/prometheus/node_exporter/releases/download/v{ne_version}/{ne_tarball} && "
                                f"tar xzf {ne_tarball} && "
                                f"sudo cp {ne_dir}/node_exporter /usr/local/bin/ && "
                                f"rm -rf {ne_dir} {ne_tarball})",
                            ]

                        for cmd in cmds:
                            exit_code, stdout, stderr = SSHManager.exec_command(client, cmd, timeout=120)
                            if exit_code != 0:
                                log(f"  Warning: {stderr[:200]}")

                        # Create node_exporter systemd unit
                        unit = """[Unit]
Description=Node Exporter
After=network.target

[Service]
User=nobody
ExecStart=/usr/local/bin/node_exporter
Restart=on-failure

[Install]
WantedBy=multi-user.target"""

                        SSHManager.exec_command(
                            client,
                            f'echo "{unit}" | sudo tee /etc/systemd/system/node_exporter.service',
                            timeout=10,
                        )
                        SSHManager.exec_command(client, "sudo systemctl daemon-reload", timeout=10)
                        SSHManager.exec_command(client, "sudo systemctl enable --now node_exporter", timeout=10)
                        log("  node_exporter installed and running on port 9100")

                        # Install JMX exporter for broker roles
                        broker_roles = {"broker", "broker_controller"}
                        if broker_roles & set(roles):
                            log("  Configuring JMX exporter for Kafka...")
                            jmx_version = getattr(settings, "JMX_EXPORTER_VERSION", "0.20.0")
                            jmx_jar = f"jmx_prometheus_javaagent-{jmx_version}.jar"
                            local_jmx = Path(settings.MONITORING_REPO_DIR) / jmx_jar

                            jmx_cmds = ["sudo mkdir -p /opt/kafka/jmx"]
                            if local_jmx.exists():
                                # Airgapped: copy from local repo via SFTP
                                log(f"  Using local JMX agent: {jmx_jar}")
                                sftp = client.open_sftp()
                                sftp.put(str(local_jmx), "/opt/kafka/jmx/jmx_prometheus_javaagent.jar")
                                sftp.close()
                            else:
                                jmx_cmds.append(
                                    f"[ -f /opt/kafka/jmx/jmx_prometheus_javaagent.jar ] || "
                                    f"sudo wget -q -O /opt/kafka/jmx/jmx_prometheus_javaagent.jar "
                                    f"https://repo1.maven.org/maven2/io/prometheus/jmx/jmx_prometheus_javaagent/{jmx_version}/{jmx_jar}"
                                )

                            for cmd in jmx_cmds:
                                SSHManager.exec_command(client, cmd, timeout=60)

                            # Write JMX exporter config
                            jmx_config = """rules:
  - pattern: "kafka.server<type=(.+), name=(.+)><>(\\w+)"
    name: "kafka_server_$1_$2_$3"
  - pattern: "kafka.network<type=(.+), name=(.+)><>(\\w+)"
    name: "kafka_network_$1_$2_$3"
  - pattern: "kafka.controller<type=(.+), name=(.+)><>(\\w+)"
    name: "kafka_controller_$1_$2_$3"
  - pattern: "kafka.log<type=(.+), name=(.+)><>(\\w+)"
    name: "kafka_log_$1_$2_$3"
  - pattern: "java.lang<type=(.+)><>(\\w+)"
    name: "jvm_$1_$2"
"""
                            SSHManager.exec_command(
                                client,
                                f"sudo bash -c 'cat > /opt/kafka/jmx/jmx_config.yml << EOF\n{jmx_config}EOF'",
                                timeout=10,
                            )

                            # Add JMX agent to Kafka service env
                            jmx_opts = '-javaagent:/opt/kafka/jmx/jmx_prometheus_javaagent.jar=7071:/opt/kafka/jmx/jmx_config.yml'
                            # Check if already configured
                            exit_code, stdout, _ = SSHManager.exec_command(
                                client,
                                "grep -c 'jmx_prometheus' /etc/systemd/system/kafka.service 2>/dev/null || echo 0",
                                timeout=10,
                            )

                            if stdout.strip() == "0":
                                # Add KAFKA_OPTS to the service file
                                SSHManager.exec_command(
                                    client,
                                    f"sudo sed -i '/\\[Service\\]/a Environment=\"KAFKA_OPTS={jmx_opts}\"' /etc/systemd/system/kafka.service",
                                    timeout=10,
                                )
                                SSHManager.exec_command(client, "sudo systemctl daemon-reload", timeout=10)
                                SSHManager.exec_command(client, "sudo systemctl restart kafka", timeout=30)
                                log("  JMX exporter configured and Kafka restarted (port 7071)")
                            else:
                                log("  JMX exporter already configured")

                except Exception as e:
                    log(f"  ERROR: {e}")

            # Update Prometheus config with scrape targets
            log("\nUpdating Prometheus configuration...")
            MonitoringManager.update_prometheus_config(cluster_id, list(unique_hosts.values()), db)
            log("Prometheus config updated and reloaded")

            _monitoring_tasks[task_id]["status"] = "completed"
            log("\nExporter deployment completed!")

        except Exception as e:
            log(f"ERROR: {e}")
            _monitoring_tasks[task_id]["status"] = "error"

    @staticmethod
    def update_prometheus_config(cluster_id: str, host_infos: list[dict], db: Session):
        """Update Prometheus config with scrape targets for the cluster."""
        config_path = Path("/etc/prometheus/prometheus.yml")

        # Read existing config
        try:
            existing = config_path.read_text() if config_path.exists() else ""
        except Exception:
            existing = ""

        # Build target list
        node_targets = []
        jmx_targets = []
        for info in host_infos:
            host = info["host"]
            roles = info["roles"]
            node_targets.append(f"{host.ip_address}:9100")
            broker_roles = {"broker", "broker_controller"}
            if broker_roles & set(roles):
                jmx_targets.append(f"{host.ip_address}:7071")

        # Generate scrape config block
        scrape_block = f"""
  - job_name: 'tantor-nodes-{cluster_id[:8]}'
    static_configs:
      - targets: {json.dumps(node_targets)}
        labels:
          cluster_id: '{cluster_id[:8]}'
"""
        if jmx_targets:
            scrape_block += f"""
  - job_name: 'tantor-kafka-{cluster_id[:8]}'
    static_configs:
      - targets: {json.dumps(jmx_targets)}
        labels:
          cluster_id: '{cluster_id[:8]}'
"""

        # Append to prometheus config if not already present
        marker = f"tantor-nodes-{cluster_id[:8]}"
        if marker not in existing:
            with open(config_path, "a") as f:
                f.write(scrape_block)

        # Reload Prometheus (SIGHUP for config reload)
        if _is_systemd_available():
            subprocess.run("systemctl reload prometheus", shell=True, capture_output=True, timeout=10)
        else:
            subprocess.run("pkill -HUP prometheus", shell=True, capture_output=True, timeout=5)

    @staticmethod
    def get_exporters_status(cluster_id: str, db: Session) -> list[dict]:
        """Check exporter status on all hosts in a cluster."""
        services = db.query(Service).filter(Service.cluster_id == cluster_id).all()
        hosts = {h.id: h for h in db.query(Host).all()}
        seen = set()
        results = []

        for svc in services:
            if svc.host_id in seen:
                continue
            seen.add(svc.host_id)

            host = hosts.get(svc.host_id)
            if not host:
                continue

            status = {
                "host_ip": host.ip_address,
                "hostname": host.hostname,
                "node_exporter": "not_installed",
                "jmx_exporter": "not_installed",
            }

            try:
                with SSHManager.connect(
                    host.ip_address, host.ssh_port, host.username,
                    host.auth_type, host.encrypted_credential,
                ) as client:
                    # Check node_exporter
                    exit_code, stdout, _ = SSHManager.exec_command(
                        client, "systemctl is-active node_exporter", timeout=10,
                    )
                    if stdout.strip() == "active":
                        status["node_exporter"] = "running"
                    elif exit_code == 0:
                        status["node_exporter"] = "stopped"

                    # Check JMX exporter (port 7071)
                    exit_code, stdout, _ = SSHManager.exec_command(
                        client, "curl -s -o /dev/null -w '%{http_code}' http://localhost:7071/metrics 2>/dev/null || echo 0",
                        timeout=10,
                    )
                    if "200" in stdout:
                        status["jmx_exporter"] = "running"

            except Exception as e:
                logger.error(f"Failed to check exporters on {host.ip_address}: {e}")

            results.append(status)

        return results

    @staticmethod
    def get_dashboards() -> list[dict]:
        """List available Grafana dashboards."""
        return [
            {"name": "kafka-overview", "title": "Kafka Overview", "url": "/grafana/d/kafka-overview?orgId=1&kiosk"},
            {"name": "kafka-brokers", "title": "Kafka Brokers", "url": "/grafana/d/kafka-brokers?orgId=1&kiosk"},
            {"name": "system-metrics", "title": "System Metrics", "url": "/grafana/d/system-metrics?orgId=1&kiosk"},
        ]


monitoring_manager = MonitoringManager()

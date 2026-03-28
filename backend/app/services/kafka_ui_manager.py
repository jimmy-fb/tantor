import logging
import time
import yaml

from sqlalchemy.orm import Session

from app.models.cluster import Cluster
from app.models.host import Host
from app.models.service import Service
from app.models.kafka_ui_config import KafkaUIConfig
from app.services.ssh_manager import SSHManager

logger = logging.getLogger("tantor.kafka_ui")

# ---------------------------------------------------------------------------
# In-memory task tracking (mirrors deployer.py pattern)
# ---------------------------------------------------------------------------
_kafka_ui_tasks: dict[str, dict] = {}


def init_kafka_ui_task(task_id: str):
    _kafka_ui_tasks[task_id] = {"task_id": task_id, "status": "running", "logs": []}


def get_kafka_ui_task(task_id: str) -> dict | None:
    return _kafka_ui_tasks.get(task_id)


def _log(task_id: str, message: str):
    task = _kafka_ui_tasks.get(task_id)
    if task:
        task["logs"].append(message)
    if message.strip():
        logger.info("[%s] %s", task_id[:8], message)


# ---------------------------------------------------------------------------
# Default YAML config generation
# ---------------------------------------------------------------------------

_DEFAULT_CONFIG_TEMPLATE = """\
kafka:
  clusters:
    - name: {cluster_name}
      bootstrapServers: {bootstrap_servers}

dynamic:
  config:
    enabled: true

server:
  port: {port}

auth:
  type: DISABLED
"""

KAFKA_UI_INSTALL_DIR = "/opt/kafka-ui"
KAFKA_UI_JAR_NAME = "kafka-ui-api.jar"
KAFKA_UI_SERVICE_NAME = "kafka-ui"
KAFKA_UI_VERSION = "1.4.2"
KAFKA_UI_DOWNLOAD_URL = (
    f"https://github.com/kafbat/kafka-ui/releases/download/v{KAFKA_UI_VERSION}/api-v{KAFKA_UI_VERSION}.jar"
)

SYSTEMD_UNIT_TEMPLATE = """\
[Unit]
Description=Kafka UI (kafbat-ui)
After=network.target

[Service]
Type=simple
User=root
Environment="JAVA_HOME={java_home}"
ExecStart={java_home}/bin/java --add-opens java.rmi/javax.rmi.ssl=ALL-UNNAMED -jar {install_dir}/{jar_name} --spring.config.additional-location={install_dir}/config.yml
WorkingDirectory={install_dir}
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
"""


class KafkaUIManager:
    """Manages deployment and lifecycle of Kafbat UI (kafka-ui) instances."""

    # ------------------------------------------------------------------
    # Config generation
    # ------------------------------------------------------------------

    def generate_default_config(self, cluster_id: str, port: int, db: Session) -> str:
        """Generate a default kafbat-ui YAML config based on the cluster's brokers."""
        cluster = db.query(Cluster).filter(Cluster.id == cluster_id).first()
        if not cluster:
            raise ValueError(f"Cluster {cluster_id} not found")

        services = (
            db.query(Service)
            .filter(Service.cluster_id == cluster_id)
            .filter(Service.role.in_(["broker", "broker_controller"]))
            .all()
        )

        if not services:
            raise ValueError("No broker services found for this cluster")

        # Get listener port from cluster config
        import json
        cluster_cfg = json.loads(cluster.config_json) if cluster.config_json else {}
        listener_port = cluster_cfg.get("listener_port", 9092)

        hosts = {h.id: h for h in db.query(Host).all()}
        broker_addresses = []
        for svc in services:
            host = hosts.get(svc.host_id)
            if host:
                broker_addresses.append(f"{host.ip_address}:{listener_port}")

        bootstrap_servers = ",".join(broker_addresses)

        config_yaml = _DEFAULT_CONFIG_TEMPLATE.format(
            cluster_name=cluster.name,
            bootstrap_servers=bootstrap_servers,
            port=port,
        )
        return config_yaml

    # ------------------------------------------------------------------
    # Deployment
    # ------------------------------------------------------------------

    def deploy_kafka_ui(self, cluster_id: str, task_id: str, port: int, db: Session):
        """Deploy kafbat-ui on the first broker host. Background task."""
        try:
            self._do_deploy(cluster_id, task_id, port, db)
        except Exception as e:
            logger.exception("Kafka UI deployment failed for cluster %s", cluster_id)
            _log(task_id, f"FATAL ERROR: {e}")
            _kafka_ui_tasks[task_id]["status"] = "error"

    def _do_deploy(self, cluster_id: str, task_id: str, port: int, db: Session):
        cluster = db.query(Cluster).filter(Cluster.id == cluster_id).first()
        if not cluster:
            _log(task_id, "ERROR: Cluster not found")
            _kafka_ui_tasks[task_id]["status"] = "error"
            return

        _log(task_id, f"Starting Kafka Explorer deployment for cluster '{cluster.name}'")

        # Find broker services and pick the first broker host as the deploy target
        broker_services = (
            db.query(Service)
            .filter(Service.cluster_id == cluster_id)
            .filter(Service.role.in_(["broker", "broker_controller"]))
            .all()
        )
        if not broker_services:
            _log(task_id, "ERROR: No broker services found for this cluster")
            _kafka_ui_tasks[task_id]["status"] = "error"
            return

        target_host = db.query(Host).filter(Host.id == broker_services[0].host_id).first()
        if not target_host:
            _log(task_id, "ERROR: Target host not found")
            _kafka_ui_tasks[task_id]["status"] = "error"
            return

        _log(task_id, f"Deploy target: {target_host.ip_address} ({target_host.hostname})")

        # Generate config
        _log(task_id, "Generating configuration...")
        config_yaml = self.generate_default_config(cluster_id, port, db)

        # Validate YAML
        try:
            yaml.safe_load(config_yaml)
        except yaml.YAMLError as e:
            _log(task_id, f"ERROR: Generated config is invalid YAML: {e}")
            _kafka_ui_tasks[task_id]["status"] = "error"
            return

        _log(task_id, "Configuration generated and validated")

        # Connect to host and deploy
        with SSHManager.connect(
            target_host.ip_address,
            target_host.ssh_port,
            target_host.username,
            target_host.auth_type,
            target_host.encrypted_credential,
        ) as client:
            # Check for Java and discover JAVA_HOME
            _log(task_id, "Checking Java installation...")
            exit_code, stdout, stderr = SSHManager.exec_command(client, "java -version 2>&1")
            if exit_code != 0:
                _log(task_id, "ERROR: Java is not installed on the target host. Please install Java 17+ first.")
                _kafka_ui_tasks[task_id]["status"] = "error"
                return
            _log(task_id, f"Java found: {stdout.splitlines()[0] if stdout else 'unknown version'}")

            # Discover JAVA_HOME
            exit_code, java_home_out, _ = SSHManager.exec_command(
                client, "readlink -f $(which java) | sed 's|/bin/java||'"
            )
            java_home = java_home_out.strip() if exit_code == 0 and java_home_out.strip() else "/usr"
            _log(task_id, f"JAVA_HOME: {java_home}")

            # Check port availability
            _log(task_id, f"Checking port {port} availability...")
            exit_code, stdout, _ = SSHManager.exec_command(
                client, f"ss -tlnp | grep ':{port} ' || true"
            )
            if stdout.strip():
                _log(task_id, f"WARNING: Port {port} appears to be in use: {stdout.strip()}")
                _log(task_id, "Proceeding anyway — the existing service may be a previous kafka-ui instance")

            # Create install directory
            _log(task_id, f"Creating install directory {KAFKA_UI_INSTALL_DIR}...")
            exit_code, _, stderr = SSHManager.exec_command(
                client, f"sudo mkdir -p {KAFKA_UI_INSTALL_DIR}"
            )
            if exit_code != 0:
                _log(task_id, f"ERROR: Failed to create directory: {stderr}")
                _kafka_ui_tasks[task_id]["status"] = "error"
                return

            # Download kafbat-ui jar (if not already present)
            jar_path = f"{KAFKA_UI_INSTALL_DIR}/{KAFKA_UI_JAR_NAME}"
            _log(task_id, "Checking for existing kafka-ui jar...")
            exit_code, _, _ = SSHManager.exec_command(client, f"test -f {jar_path}")
            if exit_code == 0:
                _log(task_id, "kafka-ui jar already exists, skipping download")
            else:
                _log(task_id, f"Downloading kafka-ui jar from {KAFKA_UI_DOWNLOAD_URL}...")
                _log(task_id, "This may take a few minutes depending on network speed...")
                exit_code, stdout, stderr = SSHManager.exec_command(
                    client,
                    f"sudo curl -fSL -o {jar_path} '{KAFKA_UI_DOWNLOAD_URL}'",
                    timeout=300,
                )
                if exit_code != 0:
                    _log(task_id, f"ERROR: Failed to download kafka-ui jar: {stderr}")
                    _kafka_ui_tasks[task_id]["status"] = "error"
                    return
                _log(task_id, "Download complete")

            # Write config file
            _log(task_id, "Writing configuration file...")
            config_path = f"{KAFKA_UI_INSTALL_DIR}/config.yml"
            SSHManager.upload_content(client, config_yaml, config_path)
            _log(task_id, f"Configuration written to {config_path}")

            # Create systemd unit
            _log(task_id, "Creating systemd service unit...")
            unit_content = SYSTEMD_UNIT_TEMPLATE.format(
                install_dir=KAFKA_UI_INSTALL_DIR,
                jar_name=KAFKA_UI_JAR_NAME,
                java_home=java_home,
            )
            unit_path = f"/etc/systemd/system/{KAFKA_UI_SERVICE_NAME}.service"
            SSHManager.upload_content(client, unit_content, unit_path)
            _log(task_id, f"Systemd unit written to {unit_path}")

            # Reload systemd and start service
            _log(task_id, "Reloading systemd daemon...")
            SSHManager.exec_command(client, "sudo systemctl daemon-reload")

            _log(task_id, "Enabling and starting kafka-ui service...")
            exit_code, _, stderr = SSHManager.exec_command(
                client, f"sudo systemctl enable {KAFKA_UI_SERVICE_NAME}"
            )
            if exit_code != 0:
                _log(task_id, f"WARNING: Failed to enable service: {stderr}")

            exit_code, _, stderr = SSHManager.exec_command(
                client, f"sudo systemctl restart {KAFKA_UI_SERVICE_NAME}"
            )
            if exit_code != 0:
                _log(task_id, f"ERROR: Failed to start kafka-ui service: {stderr}")
                _kafka_ui_tasks[task_id]["status"] = "error"
                return

            _log(task_id, "Service started, waiting for health check...")

            # Health check — poll HTTP endpoint
            healthy = False
            for attempt in range(15):
                time.sleep(2)
                exit_code, stdout, _ = SSHManager.exec_command(
                    client,
                    f"curl -sf http://localhost:{port}/actuator/health 2>/dev/null || "
                    f"curl -sf http://localhost:{port}/api/clusters 2>/dev/null || echo NOTREADY",
                    timeout=10,
                )
                if exit_code == 0 and "NOTREADY" not in stdout:
                    healthy = True
                    _log(task_id, f"Health check passed (attempt {attempt + 1})")
                    break
                _log(task_id, f"Waiting for service to become ready (attempt {attempt + 1}/15)...")

            if not healthy:
                # Check if the process is at least running
                exit_code, stdout, _ = SSHManager.exec_command(
                    client, f"systemctl is-active {KAFKA_UI_SERVICE_NAME}"
                )
                if stdout.strip() == "active":
                    _log(task_id, "Service is active but health endpoint not yet responding. "
                         "It may still be starting up — marking as deployed.")
                    healthy = True
                else:
                    _log(task_id, "ERROR: Service failed to start. Check logs with: "
                         f"journalctl -u {KAFKA_UI_SERVICE_NAME} -n 50")
                    _kafka_ui_tasks[task_id]["status"] = "error"
                    return

        # Save config to DB
        ui_config = db.query(KafkaUIConfig).filter(KafkaUIConfig.cluster_id == cluster_id).first()
        if not ui_config:
            ui_config = KafkaUIConfig(cluster_id=cluster_id)
            db.add(ui_config)

        ui_config.port = port
        ui_config.config_yaml = config_yaml
        ui_config.is_deployed = True
        ui_config.is_running = True
        ui_config.deploy_host_id = target_host.id
        db.commit()

        _log(task_id, "")
        _log(task_id, "=" * 60)
        _log(task_id, f"Kafka Explorer deployed successfully!")
        _log(task_id, f"Access URL: http://{target_host.ip_address}:{port}")
        _log(task_id, "=" * 60)
        _kafka_ui_tasks[task_id]["status"] = "completed"

    # ------------------------------------------------------------------
    # Config management
    # ------------------------------------------------------------------

    def get_config(self, cluster_id: str, db: Session) -> dict:
        """Return the current YAML config for a cluster's Kafka UI."""
        ui_config = db.query(KafkaUIConfig).filter(KafkaUIConfig.cluster_id == cluster_id).first()
        if not ui_config:
            # Generate a default config preview
            try:
                default_yaml = self.generate_default_config(cluster_id, 8080, db)
            except ValueError:
                default_yaml = ""
            return {
                "cluster_id": cluster_id,
                "config_yaml": default_yaml,
                "is_deployed": False,
                "is_default": True,
            }
        return {
            "cluster_id": cluster_id,
            "config_yaml": ui_config.config_yaml,
            "port": ui_config.port,
            "is_deployed": ui_config.is_deployed,
            "is_default": False,
        }

    def update_config(self, cluster_id: str, config_yaml: str, db: Session) -> dict:
        """Update the YAML config and restart if running."""
        # Validate YAML
        try:
            parsed = yaml.safe_load(config_yaml)
            if not isinstance(parsed, dict):
                raise ValueError("Config must be a YAML mapping")
        except yaml.YAMLError as e:
            raise ValueError(f"Invalid YAML: {e}")

        ui_config = db.query(KafkaUIConfig).filter(KafkaUIConfig.cluster_id == cluster_id).first()
        if not ui_config:
            raise ValueError("Kafka Explorer is not deployed for this cluster. Deploy first.")

        ui_config.config_yaml = config_yaml
        db.commit()

        # If running, push the new config and restart
        if ui_config.is_deployed and ui_config.deploy_host_id:
            host = db.query(Host).filter(Host.id == ui_config.deploy_host_id).first()
            if host:
                try:
                    with SSHManager.connect(
                        host.ip_address, host.ssh_port, host.username,
                        host.auth_type, host.encrypted_credential,
                    ) as client:
                        config_path = f"{KAFKA_UI_INSTALL_DIR}/config.yml"
                        SSHManager.upload_content(client, config_yaml, config_path)
                        if ui_config.is_running:
                            SSHManager.exec_command(
                                client, f"sudo systemctl restart {KAFKA_UI_SERVICE_NAME}"
                            )
                except Exception as e:
                    logger.warning("Failed to push config update to host: %s", e)

        return {"status": "updated", "config_yaml": config_yaml}

    # ------------------------------------------------------------------
    # Service lifecycle
    # ------------------------------------------------------------------

    def restart_kafka_ui(self, cluster_id: str, db: Session) -> dict:
        """Restart the kafka-ui service on the deployed host."""
        ui_config = db.query(KafkaUIConfig).filter(KafkaUIConfig.cluster_id == cluster_id).first()
        if not ui_config or not ui_config.is_deployed:
            return {"status": "error", "message": "Kafka Explorer is not deployed"}

        host = db.query(Host).filter(Host.id == ui_config.deploy_host_id).first()
        if not host:
            return {"status": "error", "message": "Deploy host not found"}

        try:
            with SSHManager.connect(
                host.ip_address, host.ssh_port, host.username,
                host.auth_type, host.encrypted_credential,
            ) as client:
                exit_code, _, stderr = SSHManager.exec_command(
                    client, f"sudo systemctl restart {KAFKA_UI_SERVICE_NAME}"
                )
                if exit_code != 0:
                    return {"status": "error", "message": f"Restart failed: {stderr}"}

            ui_config.is_running = True
            db.commit()
            return {"status": "ok", "message": "Service restarted"}
        except Exception as e:
            return {"status": "error", "message": str(e)}

    def stop_kafka_ui(self, cluster_id: str, db: Session) -> dict:
        """Stop the kafka-ui service."""
        ui_config = db.query(KafkaUIConfig).filter(KafkaUIConfig.cluster_id == cluster_id).first()
        if not ui_config or not ui_config.is_deployed:
            return {"status": "error", "message": "Kafka Explorer is not deployed"}

        host = db.query(Host).filter(Host.id == ui_config.deploy_host_id).first()
        if not host:
            return {"status": "error", "message": "Deploy host not found"}

        try:
            with SSHManager.connect(
                host.ip_address, host.ssh_port, host.username,
                host.auth_type, host.encrypted_credential,
            ) as client:
                exit_code, _, stderr = SSHManager.exec_command(
                    client, f"sudo systemctl stop {KAFKA_UI_SERVICE_NAME}"
                )
                if exit_code != 0:
                    return {"status": "error", "message": f"Stop failed: {stderr}"}

            ui_config.is_running = False
            db.commit()
            return {"status": "ok", "message": "Service stopped"}
        except Exception as e:
            return {"status": "error", "message": str(e)}

    # ------------------------------------------------------------------
    # Status
    # ------------------------------------------------------------------

    def get_status(self, cluster_id: str, db: Session) -> dict:
        """Return deployment and running status for a cluster's Kafka UI."""
        ui_config = db.query(KafkaUIConfig).filter(KafkaUIConfig.cluster_id == cluster_id).first()
        if not ui_config:
            return {
                "cluster_id": cluster_id,
                "is_deployed": False,
                "is_running": False,
                "port": 8080,
                "deploy_host_id": None,
                "deploy_host_ip": None,
                "url": None,
            }

        host_ip = None
        if ui_config.deploy_host_id:
            host = db.query(Host).filter(Host.id == ui_config.deploy_host_id).first()
            if host:
                host_ip = host.ip_address

        url = None
        if ui_config.is_running and host_ip:
            url = f"http://{host_ip}:{ui_config.port}"

        # Live status check if deployed
        live_running = ui_config.is_running
        if ui_config.is_deployed and ui_config.deploy_host_id:
            host = db.query(Host).filter(Host.id == ui_config.deploy_host_id).first()
            if host:
                try:
                    with SSHManager.connect(
                        host.ip_address, host.ssh_port, host.username,
                        host.auth_type, host.encrypted_credential,
                    ) as client:
                        exit_code, stdout, _ = SSHManager.exec_command(
                            client, f"systemctl is-active {KAFKA_UI_SERVICE_NAME}"
                        )
                        live_running = stdout.strip() == "active"
                        if live_running != ui_config.is_running:
                            ui_config.is_running = live_running
                            db.commit()
                except Exception:
                    # Can't reach host — keep last known state
                    pass

        return {
            "cluster_id": cluster_id,
            "is_deployed": ui_config.is_deployed,
            "is_running": live_running,
            "port": ui_config.port,
            "deploy_host_id": ui_config.deploy_host_id,
            "deploy_host_ip": host_ip,
            "url": f"http://{host_ip}:{ui_config.port}" if live_running and host_ip else None,
        }

    # ------------------------------------------------------------------
    # Undeploy
    # ------------------------------------------------------------------

    def undeploy_kafka_ui(self, cluster_id: str, db: Session) -> dict:
        """Stop and remove kafka-ui from the deployed host."""
        ui_config = db.query(KafkaUIConfig).filter(KafkaUIConfig.cluster_id == cluster_id).first()
        if not ui_config:
            return {"status": "error", "message": "Kafka Explorer is not deployed"}

        host = db.query(Host).filter(Host.id == ui_config.deploy_host_id).first()
        if host:
            try:
                with SSHManager.connect(
                    host.ip_address, host.ssh_port, host.username,
                    host.auth_type, host.encrypted_credential,
                ) as client:
                    # Stop and disable service
                    SSHManager.exec_command(client, f"sudo systemctl stop {KAFKA_UI_SERVICE_NAME}")
                    SSHManager.exec_command(client, f"sudo systemctl disable {KAFKA_UI_SERVICE_NAME}")

                    # Remove systemd unit
                    SSHManager.exec_command(
                        client, f"sudo rm -f /etc/systemd/system/{KAFKA_UI_SERVICE_NAME}.service"
                    )
                    SSHManager.exec_command(client, "sudo systemctl daemon-reload")

                    # Remove install directory
                    SSHManager.exec_command(client, f"sudo rm -rf {KAFKA_UI_INSTALL_DIR}")
            except Exception as e:
                logger.warning("Failed to clean up remote host during undeploy: %s", e)

        # Remove DB record
        db.delete(ui_config)
        db.commit()

        return {"status": "ok", "message": "Kafka Explorer undeployed and removed"}


# Singleton
kafka_ui_manager = KafkaUIManager()

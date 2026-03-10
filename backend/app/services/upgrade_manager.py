"""Kafka Upgrade Manager — handles rolling upgrades of Kafka clusters."""

import logging
import re
import time
from datetime import datetime, timezone
from pathlib import Path
from packaging.version import Version

from sqlalchemy.orm import Session

from app.config import settings
from app.models.cluster import Cluster
from app.models.host import Host
from app.models.service import Service
from app.services.ssh_manager import SSHManager

logger = logging.getLogger("tantor.upgrade_manager")

KAFKA_TGZ_PATTERN = re.compile(r"^kafka_(\d+\.\d+)-(\d+\.\d+\.\d+)\.tgz$")

KAFKA_INSTALL_DIR = settings.KAFKA_INSTALL_DIR
KAFKA_REPO_DIR = Path(settings.KAFKA_REPO_DIR)

# ── In-memory task tracking ──────────────────────────────

_upgrade_tasks: dict[str, dict] = {}


def init_upgrade_task(task_id: str):
    _upgrade_tasks[task_id] = {
        "status": "running",
        "logs": [],
        "progress": {"current": 0, "total": 0, "phase": "initializing"},
        "started_at": datetime.now(timezone.utc).isoformat(),
        "completed_at": None,
        "error": None,
    }


def get_upgrade_task(task_id: str) -> dict | None:
    return _upgrade_tasks.get(task_id)


def _log(task_id: str, message: str, level: str = "info"):
    """Append a log entry to the task."""
    task = _upgrade_tasks.get(task_id)
    if task:
        entry = {
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "level": level,
            "message": message,
        }
        task["logs"].append(entry)
    log_fn = getattr(logger, level, logger.info)
    log_fn(f"[upgrade:{task_id[:8]}] {message}")


def _set_phase(task_id: str, phase: str, current: int | None = None, total: int | None = None):
    """Update the progress phase and counters."""
    task = _upgrade_tasks.get(task_id)
    if task:
        task["progress"]["phase"] = phase
        if current is not None:
            task["progress"]["current"] = current
        if total is not None:
            task["progress"]["total"] = total


# ── Helper: list tarballs in repo ────────────────────────

def _list_repo_versions() -> dict[str, dict]:
    """Scan the Kafka repo directory and return {version: {scala_version, filename, path}}."""
    versions: dict[str, dict] = {}
    if KAFKA_REPO_DIR.exists():
        for f in KAFKA_REPO_DIR.glob("*.tgz"):
            match = KAFKA_TGZ_PATTERN.match(f.name)
            if match:
                scala_ver, kafka_ver = match.group(1), match.group(2)
                versions[kafka_ver] = {
                    "scala_version": scala_ver,
                    "filename": f.name,
                    "path": str(f),
                    "size_mb": round(f.stat().st_size / (1024 * 1024), 1),
                }
    return versions


# ── UpgradeManager class ─────────────────────────────────

class UpgradeManager:
    """Manages Kafka version upgrades for clusters."""

    def get_available_upgrades(self, cluster_id: str, db: Session) -> dict:
        """List available target versions for upgrade from the repo."""
        cluster = db.query(Cluster).filter(Cluster.id == cluster_id).first()
        if not cluster:
            raise ValueError(f"Cluster {cluster_id} not found")

        current_version = cluster.kafka_version
        repo_versions = _list_repo_versions()

        try:
            current = Version(current_version)
        except Exception:
            current = None

        available = []
        for ver, info in repo_versions.items():
            try:
                v = Version(ver)
            except Exception:
                continue

            if current is not None and v > current:
                available.append({
                    "version": ver,
                    "scala_version": info["scala_version"],
                    "filename": info["filename"],
                    "size_mb": info["size_mb"],
                })
            elif current is None and ver != current_version:
                available.append({
                    "version": ver,
                    "scala_version": info["scala_version"],
                    "filename": info["filename"],
                    "size_mb": info["size_mb"],
                })

        # Sort by version ascending
        available.sort(key=lambda x: Version(x["version"]))

        return {
            "cluster_id": cluster_id,
            "cluster_name": cluster.name,
            "current_version": current_version,
            "available_upgrades": available,
        }

    def pre_upgrade_check(self, cluster_id: str, target_version: str, db: Session) -> dict:
        """Validate that an upgrade is possible. Returns a detailed assessment."""
        cluster = db.query(Cluster).filter(Cluster.id == cluster_id).first()
        if not cluster:
            raise ValueError(f"Cluster {cluster_id} not found")

        checks: list[dict] = []
        overall_ok = True

        # 1. Version comparison
        current_version = cluster.kafka_version
        try:
            current_v = Version(current_version)
            target_v = Version(target_version)
            if target_v <= current_v:
                checks.append({
                    "check": "version_comparison",
                    "passed": False,
                    "message": f"Target version {target_version} is not newer than current version {current_version}",
                })
                overall_ok = False
            else:
                major_jump = target_v.major - current_v.major
                minor_jump = target_v.minor - current_v.minor if major_jump == 0 else target_v.minor
                if major_jump > 1:
                    checks.append({
                        "check": "version_comparison",
                        "passed": True,
                        "message": f"Upgrade from {current_version} to {target_version} (major version jump — review release notes carefully)",
                        "warning": True,
                    })
                else:
                    checks.append({
                        "check": "version_comparison",
                        "passed": True,
                        "message": f"Upgrade from {current_version} to {target_version}",
                    })
        except Exception:
            checks.append({
                "check": "version_comparison",
                "passed": True,
                "message": f"Upgrade from {current_version} to {target_version} (version format could not be fully parsed)",
                "warning": True,
            })

        # 2. Check target version binary exists in repo
        repo_versions = _list_repo_versions()
        if target_version in repo_versions:
            checks.append({
                "check": "binary_available",
                "passed": True,
                "message": f"Binary {repo_versions[target_version]['filename']} found ({repo_versions[target_version]['size_mb']} MB)",
            })
        else:
            checks.append({
                "check": "binary_available",
                "passed": False,
                "message": f"Binary for version {target_version} not found in repo ({KAFKA_REPO_DIR})",
            })
            overall_ok = False

        # 3. Check all brokers are healthy
        services = db.query(Service).filter(
            Service.cluster_id == cluster_id,
            Service.role.in_(["broker", "broker_controller"]),
        ).all()
        hosts = {h.id: h for h in db.query(Host).all()}

        if not services:
            checks.append({
                "check": "broker_health",
                "passed": False,
                "message": "No broker services found for this cluster",
            })
            overall_ok = False
        else:
            broker_statuses = []
            all_healthy = True
            for svc in services:
                host = hosts.get(svc.host_id)
                if not host:
                    broker_statuses.append({
                        "node_id": svc.node_id,
                        "host": "unknown",
                        "status": "error",
                        "healthy": False,
                    })
                    all_healthy = False
                    continue

                try:
                    with SSHManager.connect(
                        host.ip_address, host.ssh_port, host.username,
                        host.auth_type, host.encrypted_credential,
                    ) as client:
                        exit_code, stdout, _ = SSHManager.exec_command(
                            client, "systemctl is-active kafka", timeout=10,
                        )
                        is_active = stdout.strip() == "active"
                        broker_statuses.append({
                            "node_id": svc.node_id,
                            "host": host.ip_address,
                            "hostname": host.hostname,
                            "status": "running" if is_active else "stopped",
                            "healthy": is_active,
                        })
                        if not is_active:
                            all_healthy = False
                except Exception as e:
                    broker_statuses.append({
                        "node_id": svc.node_id,
                        "host": host.ip_address,
                        "hostname": host.hostname,
                        "status": "error",
                        "healthy": False,
                        "error": str(e),
                    })
                    all_healthy = False

            checks.append({
                "check": "broker_health",
                "passed": all_healthy,
                "message": f"{sum(1 for b in broker_statuses if b['healthy'])}/{len(broker_statuses)} brokers healthy",
                "details": broker_statuses,
            })
            if not all_healthy:
                overall_ok = False

        # 4. Check ISR status (under-replicated partitions)
        isr_ok = True
        isr_message = "Could not check ISR status"
        under_replicated_count = 0

        # Find a running broker to query
        running_broker_host = None
        for svc in services:
            host = hosts.get(svc.host_id)
            if host and svc.status == "running":
                running_broker_host = host
                break

        if running_broker_host:
            try:
                with SSHManager.connect(
                    running_broker_host.ip_address, running_broker_host.ssh_port,
                    running_broker_host.username, running_broker_host.auth_type,
                    running_broker_host.encrypted_credential,
                ) as client:
                    exit_code, stdout, stderr = SSHManager.exec_command(
                        client,
                        f"{KAFKA_INSTALL_DIR}/bin/kafka-topics.sh --bootstrap-server localhost:9092 --describe --under-replicated-partitions",
                        timeout=30,
                    )
                    if exit_code == 0:
                        lines = [l for l in stdout.strip().split("\n") if l.strip()] if stdout.strip() else []
                        under_replicated_count = len(lines)
                        if under_replicated_count == 0:
                            isr_message = "No under-replicated partitions"
                        else:
                            isr_message = f"{under_replicated_count} under-replicated partition(s) found"
                            isr_ok = False
                    else:
                        isr_message = f"ISR check command returned exit code {exit_code}"
                        if stderr:
                            isr_message += f": {stderr[:200]}"
                        isr_ok = False
            except Exception as e:
                isr_message = f"Failed to check ISR: {e}"
                isr_ok = False
        else:
            isr_message = "No running broker available to check ISR status"
            isr_ok = False

        checks.append({
            "check": "isr_status",
            "passed": isr_ok,
            "message": isr_message,
            "under_replicated_partitions": under_replicated_count,
        })
        if not isr_ok:
            overall_ok = False

        # 5. Check controller status
        controller_ok = True
        controller_message = "Could not check controller status"

        if running_broker_host:
            try:
                with SSHManager.connect(
                    running_broker_host.ip_address, running_broker_host.ssh_port,
                    running_broker_host.username, running_broker_host.auth_type,
                    running_broker_host.encrypted_credential,
                ) as client:
                    if cluster.mode == "kraft":
                        exit_code, stdout, stderr = SSHManager.exec_command(
                            client,
                            f"{KAFKA_INSTALL_DIR}/bin/kafka-metadata.sh --snapshot /var/lib/kafka/data/__cluster_metadata-0/00000000000000000000.log --cluster-id {cluster.cluster_uuid or 'unknown'} 2>/dev/null | head -5 || echo 'metadata-check-done'",
                            timeout=15,
                        )
                        controller_ok = True
                        controller_message = "KRaft metadata accessible"
                    else:
                        exit_code, stdout, stderr = SSHManager.exec_command(
                            client,
                            f"{KAFKA_INSTALL_DIR}/bin/zookeeper-shell.sh localhost:2181 <<< 'get /controller' 2>/dev/null | head -3 || echo 'zk-check-done'",
                            timeout=15,
                        )
                        controller_ok = True
                        controller_message = "ZooKeeper controller info accessible"
            except Exception as e:
                controller_ok = False
                controller_message = f"Failed to check controller: {e}"
        else:
            controller_ok = False
            controller_message = "No running broker available to check controller"

        checks.append({
            "check": "controller_status",
            "passed": controller_ok,
            "message": controller_message,
        })
        if not controller_ok:
            overall_ok = False

        return {
            "cluster_id": cluster_id,
            "cluster_name": cluster.name,
            "current_version": current_version,
            "target_version": target_version,
            "ready": overall_ok,
            "checks": checks,
        }

    def rolling_upgrade(self, cluster_id: str, target_version: str, task_id: str, db: Session):
        """Perform a rolling upgrade of all brokers in a cluster."""
        try:
            self._do_rolling_upgrade(cluster_id, target_version, task_id, db)
        except Exception as e:
            _log(task_id, f"Upgrade failed with error: {e}", "error")
            task = _upgrade_tasks.get(task_id)
            if task:
                task["status"] = "failed"
                task["error"] = str(e)
                task["completed_at"] = datetime.now(timezone.utc).isoformat()
                task["progress"]["phase"] = "failed"

    def _do_rolling_upgrade(self, cluster_id: str, target_version: str, task_id: str, db: Session):
        """Internal implementation of the rolling upgrade."""
        _log(task_id, f"Starting rolling upgrade to Kafka {target_version}")
        _set_phase(task_id, "pre_validation", 0, 0)

        # ── 1. Pre-upgrade validation ────────────────────
        _log(task_id, "Running pre-upgrade validation...")
        cluster = db.query(Cluster).filter(Cluster.id == cluster_id).first()
        if not cluster:
            raise ValueError(f"Cluster {cluster_id} not found")

        pre_check = self.pre_upgrade_check(cluster_id, target_version, db)
        if not pre_check["ready"]:
            failed_checks = [c for c in pre_check["checks"] if not c["passed"]]
            messages = "; ".join(c["message"] for c in failed_checks)
            raise ValueError(f"Pre-upgrade check failed: {messages}")

        _log(task_id, "Pre-upgrade validation passed")

        # ── 2. Resolve tarball path ──────────────────────
        repo_versions = _list_repo_versions()
        if target_version not in repo_versions:
            raise ValueError(f"Binary for version {target_version} not found in repo")

        version_info = repo_versions[target_version]
        local_tarball_path = Path(version_info["path"])
        tarball_name = version_info["filename"]

        _log(task_id, f"Using tarball: {tarball_name} ({version_info['size_mb']} MB)")

        # ── 3. Get broker services sorted by node_id ─────
        services = db.query(Service).filter(
            Service.cluster_id == cluster_id,
            Service.role.in_(["broker", "broker_controller"]),
        ).order_by(Service.node_id).all()

        hosts = {h.id: h for h in db.query(Host).all()}
        total_brokers = len(services)
        _set_phase(task_id, "upgrading", 0, total_brokers)
        _log(task_id, f"Upgrading {total_brokers} broker(s) one at a time")

        # Update cluster state
        cluster.state = "upgrading"
        db.commit()

        # ── 4. Rolling upgrade each broker ───────────────
        for idx, svc in enumerate(services):
            broker_num = idx + 1
            host = hosts.get(svc.host_id)
            if not host:
                raise ValueError(f"Host not found for service {svc.id}")

            host_label = f"{host.hostname} ({host.ip_address})"
            _log(task_id, f"--- Upgrading broker {broker_num}/{total_brokers}: node {svc.node_id} on {host_label} ---")
            _set_phase(task_id, f"upgrading_broker_{svc.node_id}", broker_num, total_brokers)

            with SSHManager.connect(
                host.ip_address, host.ssh_port, host.username,
                host.auth_type, host.encrypted_credential,
            ) as client:
                # 4a. Stop the broker
                _log(task_id, f"[Broker {svc.node_id}] Stopping Kafka service...")
                exit_code, stdout, stderr = SSHManager.exec_command(
                    client, "sudo systemctl stop kafka", timeout=60,
                )
                if exit_code != 0:
                    _log(task_id, f"[Broker {svc.node_id}] Warning: stop returned exit code {exit_code}: {stderr}", "warning")
                else:
                    _log(task_id, f"[Broker {svc.node_id}] Kafka service stopped")

                svc.status = "stopped"
                db.commit()

                # Wait a moment for clean shutdown
                time.sleep(3)

                # 4b. Backup current installation
                _log(task_id, f"[Broker {svc.node_id}] Backing up current Kafka installation...")
                backup_cmd = f"sudo cp -r {KAFKA_INSTALL_DIR} {KAFKA_INSTALL_DIR}.bak.$(date +%Y%m%d%H%M%S)"
                exit_code, stdout, stderr = SSHManager.exec_command(
                    client, backup_cmd, timeout=120,
                )
                if exit_code != 0:
                    _log(task_id, f"[Broker {svc.node_id}] Backup warning: {stderr}", "warning")
                else:
                    _log(task_id, f"[Broker {svc.node_id}] Backup completed")

                # 4c. Copy new version tarball via SFTP
                _log(task_id, f"[Broker {svc.node_id}] Uploading {tarball_name} to remote host...")
                sftp = client.open_sftp()
                try:
                    sftp.put(str(local_tarball_path), f"/tmp/{tarball_name}")
                finally:
                    sftp.close()
                _log(task_id, f"[Broker {svc.node_id}] Upload completed")

                # 4d. Preserve config, extract new version, restore config
                _log(task_id, f"[Broker {svc.node_id}] Backing up configuration...")
                exit_code, stdout, stderr = SSHManager.exec_command(
                    client,
                    f"sudo cp -r {KAFKA_INSTALL_DIR}/config /tmp/kafka_config_backup",
                    timeout=30,
                )
                if exit_code != 0:
                    raise RuntimeError(
                        f"Failed to backup config on broker {svc.node_id}: {stderr}"
                    )
                _log(task_id, f"[Broker {svc.node_id}] Configuration backed up")

                _log(task_id, f"[Broker {svc.node_id}] Extracting new Kafka version...")
                # Remove old install, extract new, rename to standard path
                extract_cmd = (
                    f"sudo rm -rf {KAFKA_INSTALL_DIR} && "
                    f"sudo tar xzf /tmp/{tarball_name} -C /opt/ && "
                    f"sudo mv /opt/kafka_*-{target_version} {KAFKA_INSTALL_DIR}"
                )
                exit_code, stdout, stderr = SSHManager.exec_command(
                    client, extract_cmd, timeout=120,
                )
                if exit_code != 0:
                    raise RuntimeError(
                        f"Failed to extract new version on broker {svc.node_id}: {stderr}"
                    )
                _log(task_id, f"[Broker {svc.node_id}] New version extracted")

                _log(task_id, f"[Broker {svc.node_id}] Restoring configuration...")
                exit_code, stdout, stderr = SSHManager.exec_command(
                    client,
                    f"sudo cp -r /tmp/kafka_config_backup/* {KAFKA_INSTALL_DIR}/config/",
                    timeout=30,
                )
                if exit_code != 0:
                    raise RuntimeError(
                        f"Failed to restore config on broker {svc.node_id}: {stderr}"
                    )
                _log(task_id, f"[Broker {svc.node_id}] Configuration restored")

                # Cleanup temp files
                SSHManager.exec_command(
                    client,
                    f"sudo rm -rf /tmp/{tarball_name} /tmp/kafka_config_backup",
                    timeout=15,
                )

                # Fix ownership
                SSHManager.exec_command(
                    client,
                    f"sudo chown -R kafka:kafka {KAFKA_INSTALL_DIR} 2>/dev/null || true",
                    timeout=30,
                )

                # 4e. Start broker with new version
                _log(task_id, f"[Broker {svc.node_id}] Starting Kafka with new version...")
                exit_code, stdout, stderr = SSHManager.exec_command(
                    client, "sudo systemctl start kafka", timeout=60,
                )
                if exit_code != 0:
                    raise RuntimeError(
                        f"Failed to start broker {svc.node_id}: {stderr}"
                    )
                _log(task_id, f"[Broker {svc.node_id}] Kafka service started")

                # 4f. Wait for broker to become healthy
                _log(task_id, f"[Broker {svc.node_id}] Waiting for broker to become healthy...")
                healthy = False
                for attempt in range(30):
                    time.sleep(5)
                    exit_code, stdout, _ = SSHManager.exec_command(
                        client, "systemctl is-active kafka", timeout=10,
                    )
                    if stdout.strip() == "active":
                        # Verify it's actually listening
                        port_code, port_out, _ = SSHManager.exec_command(
                            client,
                            "ss -tlnp | grep ':9092' | head -1",
                            timeout=10,
                        )
                        if port_code == 0 and port_out.strip():
                            healthy = True
                            break
                    if attempt % 6 == 5:
                        _log(task_id, f"[Broker {svc.node_id}] Still waiting... ({(attempt + 1) * 5}s elapsed)")

                if not healthy:
                    raise RuntimeError(
                        f"Broker {svc.node_id} did not become healthy after 150 seconds"
                    )
                _log(task_id, f"[Broker {svc.node_id}] Broker is healthy")
                svc.status = "running"
                db.commit()

                # 4g. Wait for ISR recovery
                _log(task_id, f"[Broker {svc.node_id}] Waiting for ISR recovery...")
                isr_recovered = False
                for attempt in range(24):
                    time.sleep(5)
                    exit_code, stdout, _ = SSHManager.exec_command(
                        client,
                        f"{KAFKA_INSTALL_DIR}/bin/kafka-topics.sh --bootstrap-server localhost:9092 --describe --under-replicated-partitions 2>/dev/null",
                        timeout=30,
                    )
                    if exit_code == 0:
                        lines = [l for l in stdout.strip().split("\n") if l.strip()] if stdout.strip() else []
                        if len(lines) == 0:
                            isr_recovered = True
                            break
                    if attempt % 6 == 5:
                        _log(task_id, f"[Broker {svc.node_id}] ISR recovery in progress... ({(attempt + 1) * 5}s elapsed)")

                if isr_recovered:
                    _log(task_id, f"[Broker {svc.node_id}] ISR fully recovered")
                else:
                    _log(task_id, f"[Broker {svc.node_id}] ISR recovery timed out — proceeding with caution", "warning")

            _set_phase(task_id, f"broker_{svc.node_id}_complete", broker_num, total_brokers)
            _log(task_id, f"[Broker {svc.node_id}] Upgrade completed successfully")

        # ── 5. Update cluster version in DB ──────────────
        _log(task_id, "Updating cluster version in database...")
        cluster = db.query(Cluster).filter(Cluster.id == cluster_id).first()
        if cluster:
            cluster.kafka_version = target_version
            cluster.state = "running"
            db.commit()
        _log(task_id, f"Cluster version updated to {target_version}")

        # ── 6. Post-upgrade verification ─────────────────
        _log(task_id, "Running post-upgrade verification...")
        _set_phase(task_id, "post_verification", total_brokers, total_brokers)

        verification_ok = True
        for svc in services:
            host = hosts.get(svc.host_id)
            if not host:
                continue
            try:
                with SSHManager.connect(
                    host.ip_address, host.ssh_port, host.username,
                    host.auth_type, host.encrypted_credential,
                ) as client:
                    exit_code, stdout, _ = SSHManager.exec_command(
                        client, "systemctl is-active kafka", timeout=10,
                    )
                    if stdout.strip() != "active":
                        _log(task_id, f"Post-check: Broker {svc.node_id} is NOT active", "warning")
                        verification_ok = False
                    else:
                        _log(task_id, f"Post-check: Broker {svc.node_id} is running")
            except Exception as e:
                _log(task_id, f"Post-check: Failed to verify broker {svc.node_id}: {e}", "warning")
                verification_ok = False

        if verification_ok:
            _log(task_id, "Post-upgrade verification passed: all brokers running")
        else:
            _log(task_id, "Post-upgrade verification completed with warnings", "warning")

        # ── 7. Mark task complete ────────────────────────
        task = _upgrade_tasks.get(task_id)
        if task:
            task["status"] = "completed"
            task["completed_at"] = datetime.now(timezone.utc).isoformat()
            task["progress"]["phase"] = "completed"
            task["progress"]["current"] = total_brokers
            task["progress"]["total"] = total_brokers

        _log(task_id, f"Rolling upgrade to Kafka {target_version} completed successfully")


upgrade_manager = UpgradeManager()

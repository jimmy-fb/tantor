"""Rolling Restart Manager — restart Kafka brokers one by one without downtime."""
import logging
import time
import uuid
from sqlalchemy.orm import Session
from app.models.cluster import Cluster
from app.models.service import Service
from app.models.host import Host
from app.services.ssh_manager import SSHManager
from app.config import settings

logger = logging.getLogger("tantor.rolling_restart")

# In-memory task tracking (same pattern as deployer.py)
_restart_tasks: dict[str, dict] = {}

def init_restart_task(task_id: str):
    _restart_tasks[task_id] = {"status": "running", "logs": [], "progress": {"current": 0, "total": 0, "current_broker": None}}

def get_restart_task(task_id: str) -> dict | None:
    return _restart_tasks.get(task_id)

SERVICE_TYPE_MAP = {
    "broker": "kafka",
    "broker_controller": "kafka",
    "controller": "kafka-kraft-controller",
    "zookeeper": "kafka",
    "ksqldb": "ksqldb",
    "kafka_connect": "kafka-connect",
}

class RollingRestartManager:
    def rolling_restart(self, cluster_id: str, task_id: str, restart_scope: str, db: Session):
        """
        Perform rolling restart on cluster services.
        restart_scope: "brokers" | "all" | "controllers"
        """
        task = _restart_tasks.get(task_id)
        if not task:
            return

        def log(msg: str):
            task["logs"].append(msg)
            logger.info(f"[{task_id[:8]}] {msg}")

        try:
            cluster = db.query(Cluster).filter(Cluster.id == cluster_id).first()
            if not cluster:
                log("ERROR: Cluster not found")
                task["status"] = "error"
                return

            # Get services to restart based on scope
            role_filter = []
            if restart_scope == "brokers":
                role_filter = ["broker", "broker_controller"]
            elif restart_scope == "controllers":
                role_filter = ["controller"]
            else:  # all
                role_filter = ["controller", "broker_controller", "broker", "ksqldb", "kafka_connect", "zookeeper"]

            services = db.query(Service).filter(
                Service.cluster_id == cluster_id,
                Service.role.in_(role_filter),
            ).all()

            if not services:
                log("No services found matching the restart scope")
                task["status"] = "completed"
                return

            # Sort: restart controllers first, then brokers, then others
            order = {"controller": 0, "zookeeper": 0, "broker_controller": 1, "broker": 1, "ksqldb": 2, "kafka_connect": 2}
            services = sorted(services, key=lambda s: order.get(s.role, 3))

            hosts = {h.id: h for h in db.query(Host).all()}
            task["progress"]["total"] = len(services)

            log(f"Starting rolling restart of {len(services)} service(s) — scope: {restart_scope}")
            log(f"Cluster: {cluster.name}")
            log("")

            for idx, svc in enumerate(services):
                host = hosts.get(svc.host_id)
                if not host:
                    log(f"⚠ Skipping service {svc.id} — host not found")
                    continue

                unit_name = SERVICE_TYPE_MAP.get(svc.role, "kafka") + ".service"
                task["progress"]["current"] = idx + 1
                task["progress"]["current_broker"] = f"Node {svc.node_id} ({host.ip_address})"

                log(f"━━━ [{idx+1}/{len(services)}] Restarting {svc.role} node {svc.node_id} on {host.ip_address} ━━━")

                try:
                    with SSHManager.connect(host.ip_address, host.ssh_port, host.username, host.auth_type, host.encrypted_credential) as client:
                        # Step 1: Pre-restart health check
                        log(f"  Pre-restart health check...")
                        healthy = self._check_broker_health(client, svc.role)
                        if not healthy:
                            log(f"  ⚠ Broker not healthy before restart, proceeding anyway")

                        # Step 2: Stop the service
                        log(f"  Stopping {unit_name}...")
                        exit_code, stdout, stderr = SSHManager.exec_command(
                            client, f"sudo systemctl stop {unit_name}", timeout=60
                        )
                        if exit_code != 0:
                            log(f"  ⚠ Stop warning: {stderr[:200]}")

                        # Wait for graceful shutdown
                        log(f"  Waiting for graceful shutdown...")
                        for i in range(30):
                            exit_code, stdout, _ = SSHManager.exec_command(
                                client, f"systemctl is-active {unit_name}", timeout=10
                            )
                            if stdout.strip() != "active":
                                break
                            time.sleep(1)

                        log(f"  Service stopped")

                        # Step 3: Start the service
                        log(f"  Starting {unit_name}...")
                        exit_code, stdout, stderr = SSHManager.exec_command(
                            client, f"sudo systemctl start {unit_name}", timeout=60
                        )
                        if exit_code != 0:
                            log(f"  ✗ Start failed: {stderr[:200]}")
                            task["status"] = "error"
                            return

                        # Step 4: Wait for service to become healthy
                        log(f"  Waiting for service to become healthy...")
                        healthy = False
                        for attempt in range(60):  # Wait up to 60 seconds
                            time.sleep(1)
                            if self._check_service_running(client, unit_name):
                                if svc.role in ("broker", "broker_controller"):
                                    # For brokers, also check Kafka is accepting connections
                                    if self._check_kafka_port(client):
                                        healthy = True
                                        break
                                else:
                                    healthy = True
                                    break

                        if healthy:
                            log(f"  ✓ Node {svc.node_id} restarted successfully")
                            svc.status = "running"
                        else:
                            log(f"  ✗ Node {svc.node_id} failed health check after restart")
                            svc.status = "error"
                            task["status"] = "error"
                            db.commit()
                            return

                        # Step 5: Wait for ISR recovery (for brokers)
                        if svc.role in ("broker", "broker_controller"):
                            log(f"  Waiting for ISR recovery...")
                            isr_ok = self._wait_for_isr(client, max_wait=120)
                            if isr_ok:
                                log(f"  ✓ ISR recovery complete")
                            else:
                                log(f"  ⚠ ISR recovery timeout — proceeding cautiously")

                        log("")

                except Exception as e:
                    log(f"  ✗ Error: {str(e)}")
                    svc.status = "error"
                    task["status"] = "error"
                    db.commit()
                    return

            db.commit()
            log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
            log(f"✓ Rolling restart completed successfully — {len(services)} service(s) restarted")
            task["status"] = "completed"

        except Exception as e:
            log(f"ERROR: {str(e)}")
            task["status"] = "error"

    def _check_broker_health(self, client, role: str) -> bool:
        """Check if broker is healthy before restart."""
        if role not in ("broker", "broker_controller"):
            return True
        exit_code, stdout, _ = SSHManager.exec_command(
            client,
            f"{settings.KAFKA_INSTALL_DIR}/bin/kafka-broker-api-versions.sh --bootstrap-server localhost:9092 2>/dev/null | head -1",
            timeout=15,
        )
        return exit_code == 0

    def _check_service_running(self, client, unit_name: str) -> bool:
        """Check if systemd service is active."""
        exit_code, stdout, _ = SSHManager.exec_command(
            client, f"systemctl is-active {unit_name}", timeout=10
        )
        return stdout.strip() == "active"

    def _check_kafka_port(self, client, port: int = 9092) -> bool:
        """Check if Kafka is listening on its port."""
        exit_code, _, _ = SSHManager.exec_command(
            client, f"bash -c 'echo > /dev/tcp/localhost/{port}' 2>/dev/null", timeout=5
        )
        return exit_code == 0

    def _wait_for_isr(self, client, max_wait: int = 120) -> bool:
        """Wait for all partitions to be in-sync after broker restart."""
        for _ in range(max_wait // 5):
            exit_code, stdout, _ = SSHManager.exec_command(
                client,
                f"{settings.KAFKA_INSTALL_DIR}/bin/kafka-topics.sh --bootstrap-server localhost:9092 --describe --under-replicated-partitions 2>/dev/null",
                timeout=15,
            )
            if exit_code == 0 and not stdout.strip():
                return True  # No under-replicated partitions
            time.sleep(5)
        return False

    def get_pre_restart_check(self, cluster_id: str, db: Session) -> dict:
        """Run pre-restart validation checks."""
        cluster = db.query(Cluster).filter(Cluster.id == cluster_id).first()
        if not cluster:
            raise ValueError("Cluster not found")

        services = db.query(Service).filter(
            Service.cluster_id == cluster_id,
            Service.role.in_(["broker", "broker_controller"])
        ).all()
        hosts = {h.id: h for h in db.query(Host).all()}

        checks = []
        for svc in services:
            host = hosts.get(svc.host_id)
            if not host:
                checks.append({"broker_id": svc.node_id, "host": "unknown", "healthy": False, "message": "Host not found"})
                continue
            try:
                with SSHManager.connect(host.ip_address, host.ssh_port, host.username, host.auth_type, host.encrypted_credential) as client:
                    healthy = self._check_broker_health(client, svc.role)
                    port_ok = self._check_kafka_port(client)
                    checks.append({
                        "broker_id": svc.node_id,
                        "host": host.ip_address,
                        "healthy": healthy and port_ok,
                        "message": "Healthy" if (healthy and port_ok) else "Unhealthy",
                    })
            except Exception as e:
                checks.append({"broker_id": svc.node_id, "host": host.ip_address, "healthy": False, "message": str(e)})

        all_healthy = all(c["healthy"] for c in checks)
        return {
            "cluster_name": cluster.name,
            "broker_count": len(services),
            "all_healthy": all_healthy,
            "checks": checks,
        }


rolling_restart_manager = RollingRestartManager()

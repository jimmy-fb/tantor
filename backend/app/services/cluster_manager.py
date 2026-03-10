from sqlalchemy.orm import Session

from app.models.cluster import Cluster
from app.models.host import Host
from app.models.service import Service
from app.services.ssh_manager import SSHManager


class ClusterManager:
    """Manages running Kafka clusters — start, stop, status."""

    SERVICE_TYPE_MAP = {
        "broker": "kafka",
        "broker_controller": "kafka",
        "controller": "kafka-kraft-controller",
        "zookeeper": "kafka",
        "ksqldb": "ksqldb",
        "kafka_connect": "kafka-connect",
    }

    @staticmethod
    def _get_systemd_name(role: str) -> str:
        return ClusterManager.SERVICE_TYPE_MAP.get(role, "kafka") + ".service"

    @staticmethod
    def start_cluster(cluster_id: str, db: Session) -> list[dict]:
        """Start all services in a cluster. Returns status per service."""
        results = []
        services = db.query(Service).filter(Service.cluster_id == cluster_id).all()
        hosts = {h.id: h for h in db.query(Host).all()}

        # Start controllers/zookeepers first, then brokers, then ksqldb/connect
        order = {"controller": 0, "zookeeper": 0, "broker_controller": 1, "broker": 1, "ksqldb": 2, "kafka_connect": 2}
        sorted_services = sorted(services, key=lambda s: order.get(s.role, 3))

        for svc in sorted_services:
            host = hosts.get(svc.host_id)
            if not host:
                results.append({"service_id": svc.id, "action": "start", "success": False, "message": "Host not found"})
                continue

            unit_name = ClusterManager._get_systemd_name(svc.role)
            try:
                with SSHManager.connect(host.ip_address, host.ssh_port, host.username, host.auth_type, host.encrypted_credential) as client:
                    exit_code, stdout, stderr = SSHManager.exec_command(client, f"sudo systemctl start {unit_name}")
                    if exit_code == 0:
                        svc.status = "running"
                        results.append({"service_id": svc.id, "action": "start", "success": True, "message": f"Started on {host.ip_address}"})
                    else:
                        svc.status = "error"
                        results.append({"service_id": svc.id, "action": "start", "success": False, "message": stderr})
            except Exception as e:
                svc.status = "error"
                results.append({"service_id": svc.id, "action": "start", "success": False, "message": str(e)})

        cluster = db.query(Cluster).filter(Cluster.id == cluster_id).first()
        if cluster:
            if all(r["success"] for r in results):
                cluster.state = "running"
            else:
                cluster.state = "error"
        db.commit()
        return results

    @staticmethod
    def stop_cluster(cluster_id: str, db: Session) -> list[dict]:
        """Stop all services in a cluster. Returns status per service."""
        results = []
        services = db.query(Service).filter(Service.cluster_id == cluster_id).all()
        hosts = {h.id: h for h in db.query(Host).all()}

        # Stop in reverse order: ksqldb/connect first, then brokers, then controllers
        order = {"kafka_connect": 0, "ksqldb": 0, "broker": 1, "broker_controller": 1, "controller": 2, "zookeeper": 2}
        sorted_services = sorted(services, key=lambda s: order.get(s.role, 3))

        for svc in sorted_services:
            host = hosts.get(svc.host_id)
            if not host:
                results.append({"service_id": svc.id, "action": "stop", "success": False, "message": "Host not found"})
                continue

            unit_name = ClusterManager._get_systemd_name(svc.role)
            try:
                with SSHManager.connect(host.ip_address, host.ssh_port, host.username, host.auth_type, host.encrypted_credential) as client:
                    exit_code, stdout, stderr = SSHManager.exec_command(client, f"sudo systemctl stop {unit_name}")
                    if exit_code == 0:
                        svc.status = "stopped"
                        results.append({"service_id": svc.id, "action": "stop", "success": True, "message": f"Stopped on {host.ip_address}"})
                    else:
                        results.append({"service_id": svc.id, "action": "stop", "success": False, "message": stderr})
            except Exception as e:
                results.append({"service_id": svc.id, "action": "stop", "success": False, "message": str(e)})

        cluster = db.query(Cluster).filter(Cluster.id == cluster_id).first()
        if cluster:
            cluster.state = "stopped"
        db.commit()
        return results

    @staticmethod
    def get_cluster_status(cluster_id: str, db: Session) -> list[dict]:
        """Get live status of all services in a cluster."""
        results = []
        services = db.query(Service).filter(Service.cluster_id == cluster_id).all()
        hosts = {h.id: h for h in db.query(Host).all()}

        for svc in services:
            host = hosts.get(svc.host_id)
            if not host:
                results.append({"service_id": svc.id, "host": "unknown", "role": svc.role, "status": "unknown"})
                continue

            unit_name = ClusterManager._get_systemd_name(svc.role)
            try:
                with SSHManager.connect(host.ip_address, host.ssh_port, host.username, host.auth_type, host.encrypted_credential) as client:
                    exit_code, stdout, _ = SSHManager.exec_command(client, f"systemctl is-active {unit_name}")
                    status = stdout.strip()
                    svc.status = "running" if status == "active" else "stopped"
                    results.append({
                        "service_id": svc.id,
                        "host": host.ip_address,
                        "hostname": host.hostname,
                        "role": svc.role,
                        "node_id": svc.node_id,
                        "status": svc.status,
                    })
            except Exception as e:
                svc.status = "error"
                results.append({
                    "service_id": svc.id,
                    "host": host.ip_address,
                    "hostname": host.hostname,
                    "role": svc.role,
                    "node_id": svc.node_id,
                    "status": "error",
                    "error": str(e),
                })

        db.commit()
        return results


cluster_manager = ClusterManager()

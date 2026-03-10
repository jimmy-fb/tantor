import json

import httpx
from sqlalchemy.orm import Session

from app.models.cluster import Cluster
from app.models.host import Host
from app.models.service import Service


class ConnectManager:
    """Proxies requests to the Kafka Connect REST API."""

    @staticmethod
    def _get_connect_url(cluster_id: str, db: Session) -> str:
        svc = db.query(Service).filter(
            Service.cluster_id == cluster_id,
            Service.role == "kafka_connect",
        ).first()
        if not svc:
            raise ValueError("No Kafka Connect service found in cluster")

        host = db.query(Host).filter(Host.id == svc.host_id).first()
        if not host:
            raise ValueError("Connect host not found")

        cluster = db.query(Cluster).filter(Cluster.id == cluster_id).first()
        config = json.loads(cluster.config_json) if cluster and cluster.config_json else {}
        port = config.get("connect_rest_port", 8083)
        return f"http://{host.ip_address}:{port}"

    @staticmethod
    def list_connectors(cluster_id: str, db: Session) -> list[str]:
        url = ConnectManager._get_connect_url(cluster_id, db)
        resp = httpx.get(f"{url}/connectors", timeout=10)
        resp.raise_for_status()
        return resp.json()

    @staticmethod
    def get_connector_status(cluster_id: str, name: str, db: Session) -> dict:
        url = ConnectManager._get_connect_url(cluster_id, db)
        resp = httpx.get(f"{url}/connectors/{name}/status", timeout=10)
        resp.raise_for_status()
        return resp.json()

    @staticmethod
    def get_connector_config(cluster_id: str, name: str, db: Session) -> dict:
        url = ConnectManager._get_connect_url(cluster_id, db)
        resp = httpx.get(f"{url}/connectors/{name}/config", timeout=10)
        resp.raise_for_status()
        return resp.json()

    @staticmethod
    def create_connector(cluster_id: str, name: str, config: dict, db: Session) -> dict:
        url = ConnectManager._get_connect_url(cluster_id, db)
        resp = httpx.post(f"{url}/connectors", json={"name": name, "config": config}, timeout=15)
        resp.raise_for_status()
        return resp.json()

    @staticmethod
    def delete_connector(cluster_id: str, name: str, db: Session) -> None:
        url = ConnectManager._get_connect_url(cluster_id, db)
        resp = httpx.delete(f"{url}/connectors/{name}", timeout=10)
        resp.raise_for_status()

    @staticmethod
    def pause_connector(cluster_id: str, name: str, db: Session) -> None:
        url = ConnectManager._get_connect_url(cluster_id, db)
        resp = httpx.put(f"{url}/connectors/{name}/pause", timeout=10)
        resp.raise_for_status()

    @staticmethod
    def resume_connector(cluster_id: str, name: str, db: Session) -> None:
        url = ConnectManager._get_connect_url(cluster_id, db)
        resp = httpx.put(f"{url}/connectors/{name}/resume", timeout=10)
        resp.raise_for_status()

    @staticmethod
    def restart_connector(cluster_id: str, name: str, db: Session) -> None:
        url = ConnectManager._get_connect_url(cluster_id, db)
        resp = httpx.post(f"{url}/connectors/{name}/restart", timeout=10)
        resp.raise_for_status()

    @staticmethod
    def get_plugins(cluster_id: str, db: Session) -> list[dict]:
        url = ConnectManager._get_connect_url(cluster_id, db)
        resp = httpx.get(f"{url}/connector-plugins", timeout=10)
        resp.raise_for_status()
        return resp.json()


connect_manager = ConnectManager()

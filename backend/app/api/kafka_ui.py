"""Kafka UI Management API -- Deploy and manage Kafka Explorer (kafbat-ui)."""

import json
import logging
import uuid
from pathlib import Path

import yaml
from fastapi import APIRouter, Depends, HTTPException, BackgroundTasks
from pydantic import BaseModel
from sqlalchemy.orm import Session

from app.database import get_db
from app.models.cluster import Cluster
from app.models.host import Host
from app.models.service import Service
from app.models.user import User
from app.api.deps import require_admin, require_monitor_or_above
from app.services.kafka_ui_manager import kafka_ui_manager, init_kafka_ui_task, get_kafka_ui_task

logger = logging.getLogger("tantor.kafka_ui")
router = APIRouter(prefix="/api/kafka-ui", tags=["kafka-ui"])

# Path to the local kafka-ui config (installed on Tantor server)
LOCAL_KAFKA_UI_CONFIG = Path("/opt/tantor/kafka-ui/config.yml")


class ConfigUpdateRequest(BaseModel):
    config_yaml: str


class DeployRequest(BaseModel):
    port: int = 8080


@router.get("/clusters/{cluster_id}/status")
def get_status(
    cluster_id: str,
    db: Session = Depends(get_db),
    _: User = Depends(require_monitor_or_above),
):
    return kafka_ui_manager.get_status(cluster_id, db)


@router.post("/clusters/{cluster_id}/deploy")
def deploy(
    cluster_id: str,
    req: DeployRequest,
    background_tasks: BackgroundTasks,
    db: Session = Depends(get_db),
    _: User = Depends(require_admin),
):
    task_id = str(uuid.uuid4())
    init_kafka_ui_task(task_id)
    background_tasks.add_task(kafka_ui_manager.deploy_kafka_ui, cluster_id, task_id, req.port, db)
    return {"task_id": task_id, "status": "running"}


@router.get("/tasks/{task_id}")
def get_task(
    task_id: str,
    _: User = Depends(require_monitor_or_above),
):
    task = get_kafka_ui_task(task_id)
    if not task:
        raise HTTPException(status_code=404, detail="Task not found")
    return task


@router.get("/clusters/{cluster_id}/config")
def get_config(
    cluster_id: str,
    db: Session = Depends(get_db),
    _: User = Depends(require_monitor_or_above),
):
    return kafka_ui_manager.get_config(cluster_id, db)


@router.put("/clusters/{cluster_id}/config")
def update_config(
    cluster_id: str,
    req: ConfigUpdateRequest,
    db: Session = Depends(get_db),
    _: User = Depends(require_admin),
):
    try:
        return kafka_ui_manager.update_config(cluster_id, req.config_yaml, db)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))


@router.post("/clusters/{cluster_id}/restart")
def restart(
    cluster_id: str,
    db: Session = Depends(get_db),
    _: User = Depends(require_admin),
):
    return kafka_ui_manager.restart_kafka_ui(cluster_id, db)


@router.post("/clusters/{cluster_id}/stop")
def stop(
    cluster_id: str,
    db: Session = Depends(get_db),
    _: User = Depends(require_admin),
):
    return kafka_ui_manager.stop_kafka_ui(cluster_id, db)


@router.delete("/clusters/{cluster_id}")
def undeploy(
    cluster_id: str,
    db: Session = Depends(get_db),
    _: User = Depends(require_admin),
):
    return kafka_ui_manager.undeploy_kafka_ui(cluster_id, db)


# ── Local Kafka UI Management (runs on Tantor server) ────────


@router.post("/local/sync")
def sync_local_kafka_ui(
    db: Session = Depends(get_db),
    _: User = Depends(require_admin),
):
    """Sync all running clusters to the local kafka-ui config and restart the service."""
    clusters = db.query(Cluster).filter(Cluster.state == "running").all()
    hosts_map = {h.id: h for h in db.query(Host).all()}

    kafka_clusters = []
    for cluster in clusters:
        cluster_cfg = json.loads(cluster.config_json) if cluster.config_json else {}
        listener_port = cluster_cfg.get("listener_port", 9092)

        broker_services = (
            db.query(Service)
            .filter(Service.cluster_id == cluster.id)
            .filter(Service.role.in_(["broker", "broker_controller"]))
            .all()
        )

        bootstrap = []
        for svc in broker_services:
            host = hosts_map.get(svc.host_id)
            if host:
                bootstrap.append(f"{host.ip_address}:{listener_port}")

        if bootstrap:
            kafka_clusters.append({
                "name": cluster.name,
                "bootstrapServers": ",".join(bootstrap),
            })

    config = {
        "kafka": {"clusters": kafka_clusters},
        "dynamic": {"config": {"enabled": True}},
        "server": {"port": 8989, "servlet": {"context-path": "/kafka-ui"}},
        "auth": {"type": "DISABLED"},
        "logging": {"level": {"root": "WARN", "io.kafbat.ui": "INFO"}},
    }

    try:
        LOCAL_KAFKA_UI_CONFIG.parent.mkdir(parents=True, exist_ok=True)
        LOCAL_KAFKA_UI_CONFIG.write_text(yaml.dump(config, default_flow_style=False))
        logger.info("Updated local kafka-ui config with %d clusters", len(kafka_clusters))

        # Restart the local kafka-ui service
        import subprocess
        subprocess.run(["systemctl", "restart", "tantor-kafka-ui"], capture_output=True, timeout=10)
    except Exception as e:
        logger.warning("Failed to sync local kafka-ui: %s", e)
        raise HTTPException(status_code=500, detail=str(e))

    return {
        "status": "ok",
        "clusters_synced": len(kafka_clusters),
        "cluster_names": [c["name"] for c in kafka_clusters],
    }


@router.get("/local/status")
def get_local_kafka_ui_status(
    _: User = Depends(require_monitor_or_above),
):
    """Check if the local kafka-ui service is running."""
    import subprocess
    try:
        result = subprocess.run(
            ["systemctl", "is-active", "tantor-kafka-ui"],
            capture_output=True, text=True, timeout=5,
        )
        is_active = result.stdout.strip() == "active"
    except Exception:
        is_active = False

    config_exists = LOCAL_KAFKA_UI_CONFIG.exists()
    cluster_count = 0
    if config_exists:
        try:
            cfg = yaml.safe_load(LOCAL_KAFKA_UI_CONFIG.read_text())
            cluster_count = len(cfg.get("kafka", {}).get("clusters", []))
        except Exception:
            pass

    return {
        "is_running": is_active,
        "config_exists": config_exists,
        "cluster_count": cluster_count,
        "url": "/kafka-ui/" if is_active else None,
    }

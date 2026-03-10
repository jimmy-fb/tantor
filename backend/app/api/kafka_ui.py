"""Kafka UI Management API -- Deploy and manage Kafka Explorer (kafbat-ui)."""

import uuid

from fastapi import APIRouter, Depends, HTTPException, BackgroundTasks
from pydantic import BaseModel
from sqlalchemy.orm import Session

from app.database import get_db
from app.models.user import User
from app.api.deps import require_admin, require_monitor_or_above
from app.services.kafka_ui_manager import kafka_ui_manager, init_kafka_ui_task, get_kafka_ui_task

router = APIRouter(prefix="/api/kafka-ui", tags=["kafka-ui"])


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

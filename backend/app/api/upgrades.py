"""Kafka Upgrade Management API."""
import uuid
from fastapi import APIRouter, Depends, HTTPException, BackgroundTasks
from pydantic import BaseModel
from sqlalchemy.orm import Session
from app.database import get_db
from app.models.user import User
from app.api.deps import require_admin, require_monitor_or_above
from app.services.upgrade_manager import upgrade_manager, init_upgrade_task, get_upgrade_task

router = APIRouter(prefix="/api/upgrades", tags=["upgrades"])


class UpgradeRequest(BaseModel):
    target_version: str


@router.get("/clusters/{cluster_id}/available")
def get_available_upgrades(cluster_id: str, db: Session = Depends(get_db), _: User = Depends(require_monitor_or_above)):
    try:
        return upgrade_manager.get_available_upgrades(cluster_id, db)
    except ValueError as e:
        raise HTTPException(status_code=404, detail=str(e))


@router.post("/clusters/{cluster_id}/pre-check")
def pre_upgrade_check(cluster_id: str, req: UpgradeRequest, db: Session = Depends(get_db), _: User = Depends(require_admin)):
    try:
        return upgrade_manager.pre_upgrade_check(cluster_id, req.target_version, db)
    except ValueError as e:
        raise HTTPException(status_code=404, detail=str(e))


@router.post("/clusters/{cluster_id}/upgrade")
def start_upgrade(cluster_id: str, req: UpgradeRequest, background_tasks: BackgroundTasks, db: Session = Depends(get_db), _: User = Depends(require_admin)):
    task_id = str(uuid.uuid4())
    init_upgrade_task(task_id)
    background_tasks.add_task(upgrade_manager.rolling_upgrade, cluster_id, req.target_version, task_id, db)
    return {"task_id": task_id, "status": "running"}


@router.get("/tasks/{task_id}")
def get_task(task_id: str, _: User = Depends(require_monitor_or_above)):
    task = get_upgrade_task(task_id)
    if not task:
        raise HTTPException(status_code=404, detail="Task not found")
    return task

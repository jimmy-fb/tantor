"""Cluster Linking API — MirrorMaker 2 management."""

import uuid

from fastapi import APIRouter, Depends, HTTPException, BackgroundTasks
from pydantic import BaseModel
from sqlalchemy.orm import Session

from app.database import get_db
from app.models.user import User
from app.api.deps import require_admin, require_monitor_or_above
from app.services.cluster_linking_manager import (
    cluster_linking_manager, init_link_task, get_link_task,
)

router = APIRouter(prefix="/api/cluster-linking", tags=["cluster-linking"])


class CreateLinkRequest(BaseModel):
    name: str
    source_cluster_id: str
    destination_cluster_id: str
    topics_pattern: str = ".*"
    sync_consumer_offsets: bool = True
    sync_topic_configs: bool = True


class UpdateLinkRequest(BaseModel):
    topics_pattern: str | None = None
    sync_consumer_offsets: bool | None = None
    sync_topic_configs: bool | None = None
    mm2_config_override: str | None = None


@router.get("/links")
def list_links(db: Session = Depends(get_db), _: User = Depends(require_monitor_or_above)):
    """List all cluster links."""
    return cluster_linking_manager.get_links(db)


@router.post("/links")
def create_link(
    req: CreateLinkRequest,
    db: Session = Depends(get_db),
    _: User = Depends(require_admin),
):
    """Create a new cluster link."""
    try:
        link = cluster_linking_manager.create_link(
            name=req.name,
            source_cluster_id=req.source_cluster_id,
            dest_cluster_id=req.destination_cluster_id,
            topics_pattern=req.topics_pattern,
            sync_offsets=req.sync_consumer_offsets,
            sync_configs=req.sync_topic_configs,
            db=db,
        )
        return {"id": link.id, "name": link.name, "state": link.state}
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))


@router.get("/links/{link_id}")
def get_link(link_id: str, db: Session = Depends(get_db), _: User = Depends(require_monitor_or_above)):
    """Get cluster link details with live status."""
    try:
        return cluster_linking_manager.get_link_status(link_id, db)
    except ValueError as e:
        raise HTTPException(status_code=404, detail=str(e))


@router.put("/links/{link_id}")
def update_link(
    link_id: str,
    req: UpdateLinkRequest,
    db: Session = Depends(get_db),
    _: User = Depends(require_admin),
):
    """Update a cluster link's settings."""
    try:
        link = cluster_linking_manager.update_link(
            link_id=link_id,
            topics_pattern=req.topics_pattern,
            sync_offsets=req.sync_consumer_offsets,
            sync_configs=req.sync_topic_configs,
            mm2_config_override=req.mm2_config_override,
            db=db,
        )
        return {"id": link.id, "name": link.name, "state": link.state}
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))


@router.delete("/links/{link_id}")
def delete_link(link_id: str, db: Session = Depends(get_db), _: User = Depends(require_admin)):
    """Delete a cluster link (stops MM2 and cleans up)."""
    try:
        return cluster_linking_manager.delete_link(link_id, db)
    except ValueError as e:
        raise HTTPException(status_code=404, detail=str(e))


@router.post("/links/{link_id}/deploy")
def deploy_link(
    link_id: str,
    background_tasks: BackgroundTasks,
    db: Session = Depends(get_db),
    _: User = Depends(require_admin),
):
    """Deploy MirrorMaker 2 for a cluster link. Runs in background."""
    task_id = str(uuid.uuid4())
    init_link_task(task_id)
    background_tasks.add_task(cluster_linking_manager.deploy_link, link_id, task_id, db)
    return {"task_id": task_id, "status": "running"}


@router.get("/tasks/{task_id}")
def get_task(task_id: str, _: User = Depends(require_monitor_or_above)):
    """Get deploy task status."""
    task = get_link_task(task_id)
    if not task:
        raise HTTPException(status_code=404, detail="Task not found")
    return task


@router.post("/links/{link_id}/start")
def start_link(link_id: str, db: Session = Depends(get_db), _: User = Depends(require_admin)):
    """Start MirrorMaker 2 for a link."""
    try:
        return cluster_linking_manager.start_link(link_id, db)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))


@router.post("/links/{link_id}/stop")
def stop_link(link_id: str, db: Session = Depends(get_db), _: User = Depends(require_admin)):
    """Stop MirrorMaker 2 for a link."""
    try:
        return cluster_linking_manager.stop_link(link_id, db)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))


@router.get("/links/{link_id}/metrics")
def get_link_metrics(link_id: str, db: Session = Depends(get_db), _: User = Depends(require_monitor_or_above)):
    """Get replication metrics for a link."""
    try:
        return cluster_linking_manager.get_link_metrics(link_id, db)
    except ValueError as e:
        raise HTTPException(status_code=404, detail=str(e))

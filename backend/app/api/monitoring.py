"""Monitoring API — Prometheus + Grafana installation and exporter deployment."""

import uuid

from fastapi import APIRouter, Depends, HTTPException, BackgroundTasks
from sqlalchemy.orm import Session

from app.database import get_db
from app.models.user import User
from app.services.monitoring_manager import (
    monitoring_manager, get_monitoring_task, init_monitoring_task,
)
from app.api.deps import require_admin, require_monitor_or_above

router = APIRouter(prefix="/api/monitoring", tags=["monitoring"])


@router.get("/status")
def get_status(db: Session = Depends(get_db), _: User = Depends(require_monitor_or_above)):
    """Get Prometheus/Grafana installation and running status."""
    return monitoring_manager.get_monitoring_status(db)


@router.post("/install")
def install_monitoring(
    background_tasks: BackgroundTasks,
    db: Session = Depends(get_db),
    _: User = Depends(require_admin),
):
    """Install Prometheus + Grafana on the Tantor server. Runs in background."""
    task_id = str(uuid.uuid4())
    init_monitoring_task(task_id)
    background_tasks.add_task(monitoring_manager.install_prometheus_grafana, task_id, db)
    return {"task_id": task_id, "status": "running"}


@router.get("/install/{task_id}")
def get_install_status(task_id: str, _: User = Depends(require_monitor_or_above)):
    """Get monitoring installation task status."""
    task = get_monitoring_task(task_id)
    if not task:
        raise HTTPException(status_code=404, detail="Task not found")
    return task


@router.post("/clusters/{cluster_id}/deploy-exporters")
def deploy_exporters(
    cluster_id: str,
    background_tasks: BackgroundTasks,
    db: Session = Depends(get_db),
    _: User = Depends(require_admin),
):
    """Deploy node_exporter + JMX exporter to cluster hosts. Runs in background."""
    task_id = str(uuid.uuid4())
    init_monitoring_task(task_id)
    background_tasks.add_task(
        monitoring_manager.deploy_exporters_to_cluster, cluster_id, task_id, db,
    )
    return {"task_id": task_id, "status": "running"}


@router.get("/clusters/{cluster_id}/exporters-status")
def get_exporters_status(
    cluster_id: str,
    db: Session = Depends(get_db),
    _: User = Depends(require_monitor_or_above),
):
    """Check exporter status on all hosts in a cluster."""
    return monitoring_manager.get_exporters_status(cluster_id, db)


@router.get("/dashboards")
def list_dashboards(_: User = Depends(require_monitor_or_above)):
    """List available Grafana dashboards."""
    return monitoring_manager.get_dashboards()


@router.get("/dashboards/{name}/url")
def get_dashboard_url(name: str, _: User = Depends(require_monitor_or_above)):
    """Get iframe URL for a specific dashboard."""
    dashboards = monitoring_manager.get_dashboards()
    for d in dashboards:
        if d["name"] == name:
            return {"url": d["url"]}
    raise HTTPException(status_code=404, detail="Dashboard not found")

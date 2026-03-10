from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session

from app.database import get_db
from app.schemas.connect import ConnectorCreate
from app.services.connect_manager import connect_manager
from app.api.deps import require_admin, require_monitor_or_above
from app.models.user import User

router = APIRouter(prefix="/api/clusters/{cluster_id}/connect", tags=["kafka-connect"])


@router.get("/connectors")
def list_connectors(cluster_id: str, db: Session = Depends(get_db), _: User = Depends(require_monitor_or_above)):
    try:
        return connect_manager.list_connectors(cluster_id, db)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))
    except Exception as e:
        raise HTTPException(status_code=502, detail=f"Connect API error: {e}")


@router.post("/connectors")
def create_connector(cluster_id: str, data: ConnectorCreate, db: Session = Depends(get_db), _: User = Depends(require_admin)):
    try:
        return connect_manager.create_connector(cluster_id, data.name, data.config, db)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))
    except Exception as e:
        raise HTTPException(status_code=502, detail=f"Connect API error: {e}")


@router.get("/connectors/{name}/status")
def get_connector_status(cluster_id: str, name: str, db: Session = Depends(get_db), _: User = Depends(require_monitor_or_above)):
    try:
        return connect_manager.get_connector_status(cluster_id, name, db)
    except Exception as e:
        raise HTTPException(status_code=502, detail=f"Connect API error: {e}")


@router.get("/connectors/{name}/config")
def get_connector_config(cluster_id: str, name: str, db: Session = Depends(get_db), _: User = Depends(require_monitor_or_above)):
    try:
        return connect_manager.get_connector_config(cluster_id, name, db)
    except Exception as e:
        raise HTTPException(status_code=502, detail=f"Connect API error: {e}")


@router.delete("/connectors/{name}")
def delete_connector(cluster_id: str, name: str, db: Session = Depends(get_db), _: User = Depends(require_admin)):
    try:
        connect_manager.delete_connector(cluster_id, name, db)
        return {"detail": "Connector deleted"}
    except Exception as e:
        raise HTTPException(status_code=502, detail=f"Connect API error: {e}")


@router.put("/connectors/{name}/pause")
def pause_connector(cluster_id: str, name: str, db: Session = Depends(get_db), _: User = Depends(require_admin)):
    try:
        connect_manager.pause_connector(cluster_id, name, db)
        return {"detail": "Connector paused"}
    except Exception as e:
        raise HTTPException(status_code=502, detail=f"Connect API error: {e}")


@router.put("/connectors/{name}/resume")
def resume_connector(cluster_id: str, name: str, db: Session = Depends(get_db), _: User = Depends(require_admin)):
    try:
        connect_manager.resume_connector(cluster_id, name, db)
        return {"detail": "Connector resumed"}
    except Exception as e:
        raise HTTPException(status_code=502, detail=f"Connect API error: {e}")


@router.post("/connectors/{name}/restart")
def restart_connector(cluster_id: str, name: str, db: Session = Depends(get_db), _: User = Depends(require_admin)):
    try:
        connect_manager.restart_connector(cluster_id, name, db)
        return {"detail": "Connector restarted"}
    except Exception as e:
        raise HTTPException(status_code=502, detail=f"Connect API error: {e}")


@router.get("/plugins")
def list_plugins(cluster_id: str, db: Session = Depends(get_db), _: User = Depends(require_monitor_or_above)):
    try:
        return connect_manager.get_plugins(cluster_id, db)
    except Exception as e:
        raise HTTPException(status_code=502, detail=f"Connect API error: {e}")

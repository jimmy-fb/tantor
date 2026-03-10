"""Security Scanner API — VAPT for Kafka clusters."""
from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session
from app.database import get_db
from app.models.user import User
from app.api.deps import require_admin
from app.services.security_scanner import security_scanner

router = APIRouter(prefix="/api/security-scan", tags=["security-scan"])


@router.post("/clusters/{cluster_id}/scan")
def run_scan(cluster_id: str, db: Session = Depends(get_db), _: User = Depends(require_admin)):
    """Run security scan on a cluster."""
    try:
        return security_scanner.scan_cluster(cluster_id, db)
    except ValueError as e:
        raise HTTPException(status_code=404, detail=str(e))

from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy.orm import Session

from app.database import get_db
from app.models.audit_log import AuditLog
from app.schemas.security import (
    KafkaUserCreate,
    KafkaUserResponse,
    KafkaUserCreatedResponse,
    KafkaUserRotateRequest,
    KafkaUserRotateResponse,
    KafkaUserDeleteResponse,
    AclCreateRequest,
    AclCreateResponse,
    AclDeleteRequest,
    AclDeleteResponse,
    AclListResponse,
    AuditLogEntry,
)
from app.services.kafka_admin import kafka_admin
from app.api.deps import require_admin, require_monitor_or_above
from app.models.user import User

router = APIRouter(prefix="/api/clusters/{cluster_id}/security", tags=["kafka-security"])


# ── SCRAM Users ──────────────────────────────────────

@router.get("/users", response_model=list[KafkaUserResponse])
def list_users(cluster_id: str, db: Session = Depends(get_db), _: User = Depends(require_monitor_or_above)):
    try:
        return kafka_admin.list_scram_users(cluster_id, db)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))


@router.post("/users", response_model=KafkaUserCreatedResponse)
def create_user(cluster_id: str, data: KafkaUserCreate, db: Session = Depends(get_db), _: User = Depends(require_admin)):
    try:
        return kafka_admin.create_scram_user(
            cluster_id, data.username, data.password, data.mechanism, db,
        )
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))


@router.delete("/users/{username}", response_model=KafkaUserDeleteResponse)
def delete_user(cluster_id: str, username: str, db: Session = Depends(get_db), _: User = Depends(require_admin)):
    try:
        return kafka_admin.delete_scram_user(cluster_id, username, db)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))


@router.post("/users/{username}/rotate", response_model=KafkaUserRotateResponse)
def rotate_user_password(
    cluster_id: str, username: str, data: KafkaUserRotateRequest, db: Session = Depends(get_db),
    _: User = Depends(require_admin),
):
    try:
        return kafka_admin.rotate_scram_password(cluster_id, username, data.password, db)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))


# ── ACLs ──────────────────────────────────────────────

@router.get("/acls", response_model=AclListResponse)
def list_acls(
    cluster_id: str,
    principal: str | None = None,
    resource_type: str | None = None,
    resource_name: str | None = None,
    db: Session = Depends(get_db),
    _: User = Depends(require_monitor_or_above),
):
    try:
        acls = kafka_admin.list_acls(
            cluster_id, db, principal=principal,
            resource_type=resource_type, resource_name=resource_name,
        )
        return AclListResponse(acls=acls, count=len(acls))
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))


@router.post("/acls", response_model=AclCreateResponse)
def create_acl(cluster_id: str, data: AclCreateRequest, db: Session = Depends(get_db), _: User = Depends(require_admin)):
    try:
        return kafka_admin.create_acl(cluster_id, data.model_dump(), db)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))


@router.delete("/acls", response_model=AclDeleteResponse)
def delete_acl(cluster_id: str, data: AclDeleteRequest, db: Session = Depends(get_db), _: User = Depends(require_admin)):
    try:
        return kafka_admin.delete_acl(cluster_id, data.model_dump(), db)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))


@router.get("/acls/topic/{topic_name}", response_model=AclListResponse)
def get_topic_acls(cluster_id: str, topic_name: str, db: Session = Depends(get_db), _: User = Depends(require_monitor_or_above)):
    try:
        acls = kafka_admin.list_acls(cluster_id, db, resource_type="topic", resource_name=topic_name)
        return AclListResponse(acls=acls, count=len(acls))
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))


@router.get("/acls/principal/{principal}", response_model=AclListResponse)
def get_principal_acls(cluster_id: str, principal: str, db: Session = Depends(get_db), _: User = Depends(require_monitor_or_above)):
    try:
        acls = kafka_admin.list_acls(cluster_id, db, principal=principal)
        return AclListResponse(acls=acls, count=len(acls))
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))


# ── Audit Log ──────────────────────────────────────────

@router.get("/audit-log", response_model=list[AuditLogEntry])
def get_audit_log(
    cluster_id: str,
    limit: int = Query(50, ge=1, le=500),
    offset: int = Query(0, ge=0),
    action: str | None = None,
    db: Session = Depends(get_db),
    _: User = Depends(require_monitor_or_above),
):
    query = db.query(AuditLog).filter(AuditLog.cluster_id == cluster_id)
    if action:
        query = query.filter(AuditLog.action == action)
    logs = query.order_by(AuditLog.created_at.desc()).offset(offset).limit(limit).all()
    return logs

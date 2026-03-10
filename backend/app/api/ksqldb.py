"""ksqlDB SQL Console API — proxy for ksqlDB REST API."""

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
from sqlalchemy.orm import Session

from app.database import get_db
from app.models.cluster import Cluster
from app.services.ksql_admin import KsqlAdmin
from app.api.deps import require_admin, require_monitor_or_above
from app.models.user import User

router = APIRouter(prefix="/api/clusters/{cluster_id}/ksqldb", tags=["ksqldb"])


# ── Request/Response Models ──────────────────────────

class KsqlExecuteRequest(BaseModel):
    sql: str
    timeout: int = 15


class KsqlStreamStartRequest(BaseModel):
    sql: str


class KsqlSaveQueryRequest(BaseModel):
    sql: str
    name: str


class KsqlTerminateRequest(BaseModel):
    query_id: str


# ── Helpers ──────────────────────────────────────────

def _get_cluster(cluster_id: str, db: Session) -> Cluster:
    cluster = db.query(Cluster).filter(Cluster.id == cluster_id).first()
    if not cluster:
        raise HTTPException(status_code=404, detail="Cluster not found")
    return cluster


# ── Endpoints ────────────────────────────────────────

@router.get("/status")
def ksqldb_status(cluster_id: str, db: Session = Depends(get_db), _: User = Depends(require_monitor_or_above)):
    """Get ksqlDB server info."""
    _get_cluster(cluster_id, db)
    try:
        return KsqlAdmin.get_server_info(cluster_id, db)
    except ValueError as e:
        raise HTTPException(status_code=502, detail=str(e))


@router.post("/execute")
def execute_sql(cluster_id: str, req: KsqlExecuteRequest, db: Session = Depends(get_db), _: User = Depends(require_admin)):
    """Execute a ksqlDB SQL statement or query.

    Auto-detects statement type:
    - SELECT queries → uses /query endpoint
    - Everything else (CREATE, DROP, INSERT, SHOW, DESCRIBE) → uses /ksql endpoint
    """
    _get_cluster(cluster_id, db)
    sql = req.sql.strip()
    if not sql:
        raise HTTPException(status_code=400, detail="SQL statement is required")

    try:
        # Determine if this is a SELECT query or a statement
        sql_upper = sql.upper().lstrip()
        if sql_upper.startswith("SELECT"):
            return KsqlAdmin.execute_query(cluster_id, sql, db, timeout=req.timeout)
        else:
            return KsqlAdmin.execute_statement(cluster_id, sql, db)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))


@router.post("/stream/start")
def start_stream(cluster_id: str, req: KsqlStreamStartRequest, db: Session = Depends(get_db), _: User = Depends(require_admin)):
    """Start a streaming push query in the background."""
    _get_cluster(cluster_id, db)
    sql = req.sql.strip()
    if not sql:
        raise HTTPException(status_code=400, detail="SQL statement is required")
    if "EMIT" not in sql.upper():
        raise HTTPException(status_code=400, detail="Only push queries (EMIT CHANGES/FINAL) can be streamed")

    try:
        return KsqlAdmin.start_streaming_query(cluster_id, sql, db)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))


@router.get("/stream/{stream_id}/poll")
def poll_stream(cluster_id: str, stream_id: str, db: Session = Depends(get_db), _: User = Depends(require_monitor_or_above)):
    """Poll for new rows from a streaming query."""
    try:
        return KsqlAdmin.poll_stream(stream_id)
    except ValueError as e:
        raise HTTPException(status_code=404, detail=str(e))


@router.post("/stream/{stream_id}/stop")
def stop_stream(cluster_id: str, stream_id: str, db: Session = Depends(get_db), _: User = Depends(require_admin)):
    """Stop a streaming query."""
    try:
        return KsqlAdmin.stop_stream(stream_id)
    except ValueError as e:
        raise HTTPException(status_code=404, detail=str(e))


@router.get("/entities")
def list_entities(cluster_id: str, db: Session = Depends(get_db), _: User = Depends(require_monitor_or_above)):
    """List all ksqlDB streams and tables."""
    _get_cluster(cluster_id, db)
    try:
        return KsqlAdmin.list_entities(cluster_id, db)
    except ValueError as e:
        raise HTTPException(status_code=502, detail=str(e))


@router.post("/terminate/{query_id}")
def terminate_query(cluster_id: str, query_id: str, db: Session = Depends(get_db), _: User = Depends(require_admin)):
    """Terminate a persistent ksqlDB query."""
    _get_cluster(cluster_id, db)
    try:
        return KsqlAdmin.terminate_query(cluster_id, query_id, db)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))


@router.get("/history")
def get_history(
    cluster_id: str,
    limit: int = 50,
    offset: int = 0,
    db: Session = Depends(get_db),
    _: User = Depends(require_monitor_or_above),
):
    """Get query history for a cluster."""
    _get_cluster(cluster_id, db)
    return KsqlAdmin.get_history(cluster_id, db, limit, offset)


@router.post("/history")
def save_query(cluster_id: str, req: KsqlSaveQueryRequest, db: Session = Depends(get_db), _: User = Depends(require_admin)):
    """Save a named query."""
    _get_cluster(cluster_id, db)
    return KsqlAdmin.save_named_query(cluster_id, req.sql, req.name, db)


@router.delete("/history/{history_id}")
def delete_history(cluster_id: str, history_id: str, db: Session = Depends(get_db), _: User = Depends(require_admin)):
    """Delete a query history entry."""
    try:
        return KsqlAdmin.delete_history(history_id, db)
    except ValueError as e:
        raise HTTPException(status_code=404, detail=str(e))

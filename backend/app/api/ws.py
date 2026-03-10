import asyncio

from fastapi import APIRouter, WebSocket, WebSocketDisconnect, Query
from sqlalchemy.orm import Session

from app.database import get_db
from app.api.deps import get_ws_user
from app.services.deployer import get_task

router = APIRouter(tags=["websocket"])


@router.websocket("/api/ws/deploy/{task_id}")
async def deployment_logs(websocket: WebSocket, task_id: str, token: str = Query("")):
    """Stream deployment logs via WebSocket.

    Requires a valid JWT passed as ?token=<jwt> query parameter.
    """
    # --- auth check ---
    from app.database import SessionLocal
    db: Session = SessionLocal()
    try:
        user = get_ws_user(token, db)
        if not user:
            await websocket.close(code=4001, reason="Unauthorized")
            return
    finally:
        db.close()

    await websocket.accept()
    last_index = 0

    try:
        while True:
            task = get_task(task_id)
            if not task:
                await websocket.send_json({"type": "error", "message": "Task not found"})
                break

            # Send any new log lines
            logs = task["logs"]
            if last_index < len(logs):
                for line in logs[last_index:]:
                    await websocket.send_json({"type": "log", "message": line})
                last_index = len(logs)

            # Check if deployment is done
            if task["status"] in ("completed", "completed_with_errors", "error"):
                await websocket.send_json({"type": "status", "status": task["status"]})
                break

            await asyncio.sleep(0.5)
    except WebSocketDisconnect:
        pass
    finally:
        await websocket.close()

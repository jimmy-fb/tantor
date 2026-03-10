"""ksqlDB REST API proxy — executes ksqlDB commands via SSH → curl on the ksqlDB host."""

import json
import threading
import time
import uuid

from sqlalchemy.orm import Session

from app.config import settings
from app.models.host import Host
from app.models.service import Service
from app.models.query_history import QueryHistory
from app.services.ssh_manager import SSHManager
from app.services.crypto import decrypt


# In-memory streaming query state (similar to deployer._deployment_tasks)
_active_streams: dict[str, dict] = {}


class KsqlAdmin:
    """Proxy for ksqlDB REST API via SSH."""

    @staticmethod
    def _get_ksqldb_service(cluster_id: str, db: Session) -> tuple[Host, int]:
        """Find a running ksqlDB host + port for a cluster."""
        svc = (
            db.query(Service)
            .filter(Service.cluster_id == cluster_id, Service.role == "ksqldb")
            .first()
        )
        if not svc:
            raise ValueError("No ksqlDB service found in this cluster")

        host = db.query(Host).filter(Host.id == svc.host_id).first()
        if not host:
            raise ValueError(f"Host {svc.host_id} for ksqlDB service not found")

        # Get ksqlDB port from cluster config
        from app.models.cluster import Cluster

        cluster = db.query(Cluster).filter(Cluster.id == cluster_id).first()
        cluster_config = json.loads(cluster.config_json) if cluster and cluster.config_json else {}
        ksqldb_port = cluster_config.get("ksqldb_port", 8088)

        return host, ksqldb_port

    @staticmethod
    def _ksql_http(
        host: Host,
        ksqldb_port: int,
        method: str,
        path: str,
        body: str | None = None,
        timeout: int = 15,
    ) -> tuple[int, str, str]:
        """Execute an HTTP request against ksqlDB via SSH → curl."""
        cmd_parts = [
            "curl", "-s", "-S",
            f"--max-time {timeout}",
            "-X", method,
            f"http://localhost:{ksqldb_port}{path}",
            "-H", "'Content-Type: application/json'",
        ]
        if body:
            # Escape single quotes in body for shell
            safe_body = body.replace("'", "'\\''")
            cmd_parts.extend(["-d", f"'{safe_body}'"])

        cmd = " ".join(cmd_parts)

        with SSHManager.connect(
            host.ip_address, host.ssh_port, host.username,
            host.auth_type, host.encrypted_credential,
        ) as client:
            return SSHManager.exec_command(client, cmd, timeout=timeout + 5)

    # ── Server Info ──────────────────────────────────────

    @staticmethod
    def get_server_info(cluster_id: str, db: Session) -> dict:
        """Get ksqlDB server info (version, cluster ID, service ID)."""
        host, port = KsqlAdmin._get_ksqldb_service(cluster_id, db)
        exit_code, stdout, stderr = KsqlAdmin._ksql_http(host, port, "GET", "/info", timeout=10)

        if exit_code != 0:
            raise ValueError(f"Failed to connect to ksqlDB: {stderr}")

        try:
            info = json.loads(stdout)
            ksql_info = info.get("KsqlServerInfo", info)
            return {
                "version": ksql_info.get("version", "unknown"),
                "kafkaClusterId": ksql_info.get("kafkaClusterId", ""),
                "ksqlServiceId": ksql_info.get("ksqlServiceId", ""),
                "status": "running",
            }
        except json.JSONDecodeError:
            raise ValueError(f"Invalid ksqlDB response: {stdout[:200]}")

    # ── Statement Execution (DDL/DML) ────────────────────

    @staticmethod
    def execute_statement(cluster_id: str, sql: str, db: Session) -> dict:
        """Execute a ksqlDB statement (CREATE, DROP, INSERT, DESCRIBE, SHOW, LIST, TERMINATE).

        Uses POST /ksql endpoint.
        """
        host, port = KsqlAdmin._get_ksqldb_service(cluster_id, db)
        body = json.dumps({"ksql": sql, "streamsProperties": {}})

        exit_code, stdout, stderr = KsqlAdmin._ksql_http(
            host, port, "POST", "/ksql", body, timeout=30,
        )

        # Save to history
        status = "success" if exit_code == 0 else "error"
        try:
            parsed = json.loads(stdout) if stdout.strip() else []
            if isinstance(parsed, dict) and parsed.get("@type") == "currentStatus":
                status = "success"
            elif isinstance(parsed, list) and len(parsed) > 0:
                first = parsed[0]
                if first.get("@type") == "currentStatus":
                    status = "success"
                elif first.get("@type", "").endswith("Error"):
                    status = "error"
        except json.JSONDecodeError:
            status = "error"
            parsed = None

        KsqlAdmin._save_history(db, cluster_id, sql, status)

        if exit_code != 0 and not stdout.strip():
            raise ValueError(f"ksqlDB error: {stderr}")

        # Parse response
        if parsed is None:
            raise ValueError(f"Invalid ksqlDB response: {stdout[:500]}")

        return KsqlAdmin._format_statement_response(parsed, sql)

    @staticmethod
    def _format_statement_response(parsed: list | dict, sql: str) -> dict:
        """Format ksqlDB /ksql response into a clean structure."""
        if isinstance(parsed, dict):
            # Error or single response
            if "@type" in parsed and "Error" in parsed.get("@type", ""):
                return {
                    "type": "error",
                    "message": parsed.get("message", str(parsed)),
                    "status": "ERROR",
                }
            return {
                "type": "statement",
                "status": parsed.get("commandStatus", {}).get("status", "SUCCESS"),
                "message": parsed.get("commandStatus", {}).get("message", str(parsed)),
                "statementText": parsed.get("statementText", sql),
            }

        if isinstance(parsed, list) and len(parsed) > 0:
            first = parsed[0]
            resp_type = first.get("@type", "")

            # Error
            if "Error" in resp_type:
                return {
                    "type": "error",
                    "message": first.get("message", str(first)),
                    "status": "ERROR",
                    "errorCode": first.get("error_code"),
                }

            # Statement result
            if resp_type == "currentStatus":
                return {
                    "type": "statement",
                    "status": first.get("commandStatus", {}).get("status", "SUCCESS"),
                    "message": first.get("commandStatus", {}).get("message", "Statement executed"),
                    "statementText": first.get("statementText", sql),
                }

            # DESCRIBE / SHOW results — return as entities/rows
            if resp_type in ("sourceDescription", "streams", "tables", "queries", "properties"):
                return {
                    "type": "statement",
                    "status": "SUCCESS",
                    "message": f"Query returned {len(parsed)} result(s)",
                    "entities": parsed,
                }

            # Generic list response
            return {
                "type": "statement",
                "status": "SUCCESS",
                "message": "Statement executed",
                "entities": parsed,
            }

        return {
            "type": "statement",
            "status": "SUCCESS",
            "message": "Statement executed (empty response)",
        }

    # ── Query Execution (SELECT) ─────────────────────────

    @staticmethod
    def execute_query(cluster_id: str, sql: str, db: Session, timeout: int = 15) -> dict:
        """Execute a ksqlDB query (SELECT).

        Uses POST /query endpoint.
        For push queries, curl runs with --max-time to collect partial results.
        """
        host, port = KsqlAdmin._get_ksqldb_service(cluster_id, db)
        body = json.dumps({"ksql": sql, "streamsProperties": {}})

        exit_code, stdout, stderr = KsqlAdmin._ksql_http(
            host, port, "POST", "/query", body, timeout=timeout,
        )

        # timeout exit code (28 for curl) is OK for push queries
        is_push = "EMIT CHANGES" in sql.upper() or "EMIT FINAL" in sql.upper()

        status = "success"
        if exit_code != 0 and exit_code != 28 and not stdout.strip():
            status = "error"
            KsqlAdmin._save_history(db, cluster_id, sql, status)
            raise ValueError(f"ksqlDB query error: {stderr}")

        KsqlAdmin._save_history(db, cluster_id, sql, "success")

        # Parse streaming JSON response (one JSON array per line)
        return KsqlAdmin._parse_query_response(stdout, is_push)

    @staticmethod
    def _parse_query_response(raw: str, is_push: bool) -> dict:
        """Parse ksqlDB /query response.

        Response format: Each line is a JSON array.
        First line: header with column names.
        Subsequent lines: data rows.
        Or it could be a JSON object (error).
        """
        lines = [l.strip().rstrip(",") for l in raw.strip().splitlines() if l.strip()]
        if not lines:
            return {"type": "query", "columns": [], "rows": [], "is_push_query": is_push}

        # Check if it's an error response
        try:
            maybe_error = json.loads(raw.strip())
            if isinstance(maybe_error, dict) and ("@type" in maybe_error or "message" in maybe_error):
                return {
                    "type": "error",
                    "message": maybe_error.get("message", str(maybe_error)),
                    "status": "ERROR",
                }
        except json.JSONDecodeError:
            pass

        # Parse line-by-line JSON arrays
        columns: list[str] = []
        rows: list[list] = []
        query_id: str | None = None

        for i, line in enumerate(lines):
            # Skip closing bracket fragments
            if line in ("]", "[", ""):
                continue
            try:
                parsed = json.loads(line)
            except json.JSONDecodeError:
                continue

            if isinstance(parsed, dict):
                # Header row or metadata
                if "header" in parsed:
                    header = parsed["header"]
                    columns = [col.strip() for col in header.get("schema", "").split(",")]
                    query_id = header.get("queryId")
                elif "queryId" in parsed:
                    query_id = parsed["queryId"]
                elif "columnNames" in parsed:
                    columns = parsed["columnNames"]
                elif "row" in parsed:
                    rows.append(parsed["row"].get("columns", []))
                elif "finalMessage" in parsed:
                    pass  # End of response
                continue

            if isinstance(parsed, list):
                if i == 0 and all(isinstance(c, str) for c in parsed):
                    # First array is column names
                    columns = parsed
                else:
                    rows.append(parsed)

        return {
            "type": "query",
            "columns": columns,
            "rows": rows,
            "is_push_query": is_push,
            "query_id": query_id,
            "row_count": len(rows),
        }

    # ── Streaming Push Query (Background) ────────────────

    @staticmethod
    def start_streaming_query(cluster_id: str, sql: str, db: Session) -> dict:
        """Start a push query in the background, returning a stream_id for polling."""
        host, port = KsqlAdmin._get_ksqldb_service(cluster_id, db)

        stream_id = str(uuid.uuid4())
        stream_state = {
            "stream_id": stream_id,
            "cluster_id": cluster_id,
            "sql": sql,
            "columns": [],
            "rows": [],
            "poll_offset": 0,
            "status": "running",  # "running", "stopped", "error", "done"
            "error": None,
            "query_id": None,
            "host_ip": host.ip_address,
            "host_port": host.ssh_port,
            "host_username": host.username,
            "host_auth_type": host.auth_type,
            "host_encrypted_credential": host.encrypted_credential,
            "ksqldb_port": port,
        }
        _active_streams[stream_id] = stream_state

        # Start background thread
        thread = threading.Thread(
            target=KsqlAdmin._stream_worker,
            args=(stream_id, sql),
            daemon=True,
        )
        thread.start()

        KsqlAdmin._save_history(db, cluster_id, sql, "success")

        return {"stream_id": stream_id, "status": "running"}

    @staticmethod
    def _stream_worker(stream_id: str, sql: str):
        """Background thread that runs a push query and buffers results."""
        state = _active_streams.get(stream_id)
        if not state:
            return

        try:
            body = json.dumps({"ksql": sql, "streamsProperties": {}})
            safe_body = body.replace("'", "'\\''")
            cmd = (
                f"curl -s -S --max-time 120 -N "
                f"-X POST http://localhost:{state['ksqldb_port']}/query "
                f"-H 'Content-Type: application/json' "
                f"-d '{safe_body}'"
            )

            with SSHManager.connect(
                state["host_ip"], state["host_port"], state["host_username"],
                state["host_auth_type"], state["host_encrypted_credential"],
            ) as client:
                # Run with streaming output
                stdin_ch, stdout_ch, stderr_ch = client.exec_command(cmd, timeout=125)
                header_parsed = False

                for raw_line in stdout_ch:
                    if state["status"] != "running":
                        break

                    line = raw_line.strip().rstrip(",")
                    if not line or line in ("[]", "[", "]"):
                        continue

                    try:
                        parsed = json.loads(line)
                    except json.JSONDecodeError:
                        continue

                    if isinstance(parsed, dict):
                        if "header" in parsed:
                            hdr = parsed["header"]
                            state["columns"] = [c.strip() for c in hdr.get("schema", "").split(",")]
                            state["query_id"] = hdr.get("queryId")
                            header_parsed = True
                        elif "columnNames" in parsed:
                            state["columns"] = parsed["columnNames"]
                            header_parsed = True
                        elif "row" in parsed:
                            state["rows"].append(parsed["row"].get("columns", []))
                        elif "finalMessage" in parsed:
                            state["status"] = "done"
                            return
                    elif isinstance(parsed, list):
                        if not header_parsed and all(isinstance(c, str) for c in parsed):
                            state["columns"] = parsed
                            header_parsed = True
                        else:
                            state["rows"].append(parsed)

        except Exception as e:
            state["error"] = str(e)
            state["status"] = "error"
            return

        if state["status"] == "running":
            state["status"] = "done"

    @staticmethod
    def poll_stream(stream_id: str) -> dict:
        """Poll for new rows from a streaming query."""
        state = _active_streams.get(stream_id)
        if not state:
            raise ValueError(f"Stream {stream_id} not found")

        offset = state["poll_offset"]
        new_rows = state["rows"][offset:]
        state["poll_offset"] = len(state["rows"])

        return {
            "columns": state["columns"],
            "rows": new_rows,
            "total_rows": len(state["rows"]),
            "status": state["status"],
            "error": state["error"],
            "query_id": state["query_id"],
            "done": state["status"] in ("done", "stopped", "error"),
        }

    @staticmethod
    def stop_stream(stream_id: str) -> dict:
        """Stop a streaming query and clean up."""
        state = _active_streams.get(stream_id)
        if not state:
            raise ValueError(f"Stream {stream_id} not found")

        state["status"] = "stopped"
        # Give thread a moment to exit, then clean up
        time.sleep(0.5)

        total = len(state["rows"])
        # Don't immediately delete — let frontend do one final poll
        return {"stream_id": stream_id, "status": "stopped", "total_rows": total}

    # ── Entity Listing ───────────────────────────────────

    @staticmethod
    def list_entities(cluster_id: str, db: Session) -> dict:
        """List all ksqlDB streams and tables."""
        host, port = KsqlAdmin._get_ksqldb_service(cluster_id, db)

        streams = []
        tables = []

        # Get streams
        body_streams = json.dumps({"ksql": "SHOW STREAMS;", "streamsProperties": {}})
        ec1, out1, _ = KsqlAdmin._ksql_http(host, port, "POST", "/ksql", body_streams, timeout=10)
        if ec1 == 0 and out1.strip():
            try:
                parsed = json.loads(out1)
                if isinstance(parsed, list):
                    for item in parsed:
                        for s in item.get("streams", []):
                            streams.append({
                                "name": s.get("name", ""),
                                "type": "STREAM",
                                "topic": s.get("topic", ""),
                                "keyFormat": s.get("keyFormat", ""),
                                "valueFormat": s.get("valueFormat", s.get("format", "")),
                            })
            except json.JSONDecodeError:
                pass

        # Get tables
        body_tables = json.dumps({"ksql": "SHOW TABLES;", "streamsProperties": {}})
        ec2, out2, _ = KsqlAdmin._ksql_http(host, port, "POST", "/ksql", body_tables, timeout=10)
        if ec2 == 0 and out2.strip():
            try:
                parsed = json.loads(out2)
                if isinstance(parsed, list):
                    for item in parsed:
                        for t in item.get("tables", []):
                            tables.append({
                                "name": t.get("name", ""),
                                "type": "TABLE",
                                "topic": t.get("topic", ""),
                                "keyFormat": t.get("keyFormat", ""),
                                "valueFormat": t.get("valueFormat", t.get("format", "")),
                            })
            except json.JSONDecodeError:
                pass

        return {"streams": streams, "tables": tables}

    # ── Terminate Query ──────────────────────────────────

    @staticmethod
    def terminate_query(cluster_id: str, query_id: str, db: Session) -> dict:
        """Terminate a persistent ksqlDB query by its query ID."""
        host, port = KsqlAdmin._get_ksqldb_service(cluster_id, db)
        body = json.dumps({"ksql": f"TERMINATE {query_id};", "streamsProperties": {}})

        exit_code, stdout, stderr = KsqlAdmin._ksql_http(
            host, port, "POST", "/ksql", body, timeout=15,
        )

        if exit_code != 0 and not stdout.strip():
            raise ValueError(f"Failed to terminate query: {stderr}")

        return {"query_id": query_id, "terminated": True}

    # ── Query History ────────────────────────────────────

    @staticmethod
    def _save_history(db: Session, cluster_id: str, sql: str, status: str):
        """Save a query to history."""
        entry = QueryHistory(
            cluster_id=cluster_id,
            sql=sql,
            status=status,
        )
        db.add(entry)
        try:
            db.commit()
        except Exception:
            db.rollback()

    @staticmethod
    def get_history(cluster_id: str, db: Session, limit: int = 50, offset: int = 0) -> list[dict]:
        """Get query history for a cluster."""
        entries = (
            db.query(QueryHistory)
            .filter(QueryHistory.cluster_id == cluster_id)
            .order_by(QueryHistory.created_at.desc())
            .offset(offset)
            .limit(limit)
            .all()
        )
        return [
            {
                "id": e.id,
                "cluster_id": e.cluster_id,
                "sql": e.sql,
                "name": e.name,
                "status": e.status,
                "created_at": e.created_at.isoformat() if e.created_at else None,
            }
            for e in entries
        ]

    @staticmethod
    def save_named_query(cluster_id: str, sql: str, name: str, db: Session) -> dict:
        """Save a named query."""
        entry = QueryHistory(
            cluster_id=cluster_id,
            sql=sql,
            name=name,
            status="saved",
        )
        db.add(entry)
        db.commit()
        return {
            "id": entry.id,
            "sql": entry.sql,
            "name": entry.name,
            "status": entry.status,
            "created_at": entry.created_at.isoformat() if entry.created_at else None,
        }

    @staticmethod
    def delete_history(history_id: str, db: Session) -> dict:
        """Delete a query history entry."""
        entry = db.query(QueryHistory).filter(QueryHistory.id == history_id).first()
        if not entry:
            raise ValueError("History entry not found")
        db.delete(entry)
        db.commit()
        return {"id": history_id, "deleted": True}

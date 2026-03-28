"""Monitoring API — Built-in Kafka & system metrics via SSH + optional Prometheus/Grafana."""

import logging
from pydantic import BaseModel
from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session

from app.database import get_db
from app.models.cluster import Cluster
from app.models.host import Host
from app.models.service import Service
from app.models.user import User
from app.services.ssh_manager import SSHManager
from app.services.monitoring_deployer import MonitoringDeployer
from app.api.deps import require_monitor_or_above, require_admin

logger = logging.getLogger("tantor.monitoring")
router = APIRouter(prefix="/api/monitoring", tags=["monitoring"])


class MonitoringDeployRequest(BaseModel):
    monitoring_host_id: str
    grafana_port: int = 3000
    prometheus_port: int = 9090


def _ssh_exec(host: Host, command: str, timeout: int = 15) -> str:
    """Execute command on host and return stdout."""
    try:
        with SSHManager.connect(
            host.ip_address, host.ssh_port, host.username,
            host.auth_type, host.encrypted_credential,
        ) as client:
            exit_code, stdout, stderr = SSHManager.exec_command(client, command, timeout=timeout)
            return stdout.strip() if exit_code == 0 else ""
    except Exception as e:
        logger.warning(f"SSH to {host.ip_address} failed: {e}")
        return ""


@router.get("/status")
def get_monitoring_status(_: User = Depends(require_monitor_or_above)):
    """Return monitoring status — built-in, always available."""
    return {
        "enabled": True,
        "type": "built-in",
        "description": "Built-in Kafka & system metrics via SSH. No external tools required.",
    }


@router.get("/clusters/{cluster_id}/metrics")
def get_cluster_metrics(
    cluster_id: str,
    db: Session = Depends(get_db),
    _: User = Depends(require_monitor_or_above),
):
    """Get live metrics for all nodes in a cluster."""
    cluster = db.query(Cluster).filter(Cluster.id == cluster_id).first()
    if not cluster:
        raise HTTPException(status_code=404, detail="Cluster not found")

    services = db.query(Service).filter(Service.cluster_id == cluster_id).all()
    nodes = []

    # Deduplicate by host_id — multiple services can run on the same host (#10, #15)
    seen_hosts: dict[str, dict] = {}
    for svc in services:
        host = db.query(Host).filter(Host.id == svc.host_id).first()
        if not host:
            continue

        if host.id in seen_hosts:
            # Append role to existing node entry
            existing = seen_hosts[host.id]
            existing["role"] = existing["role"] + ", " + svc.role
            existing["node_id"] = min(existing["node_id"], svc.node_id)
            continue

        node_metrics = {
            "host_id": host.id,
            "hostname": host.hostname,
            "ip_address": host.ip_address,
            "role": svc.role,
            "node_id": svc.node_id,
            "status": svc.status,
            "system": _get_system_metrics(host),
            "kafka": _get_kafka_metrics(host),
            "disk": _get_disk_metrics(host),
        }
        seen_hosts[host.id] = node_metrics
        nodes.append(node_metrics)

    return {
        "cluster_id": cluster_id,
        "cluster_name": cluster.name,
        "nodes": nodes,
    }


def _get_system_metrics(host: Host) -> dict:
    """Get CPU, memory, uptime from a host."""
    # All in one SSH call for performance
    cmd = """bash -c '
echo "UPTIME:$(uptime -s 2>/dev/null || uptime | head -1)"
echo "LOAD:$(cat /proc/loadavg 2>/dev/null || echo "0 0 0")"
echo "CPU_CORES:$(nproc 2>/dev/null || echo 1)"

# Memory
MEM=$(free -m 2>/dev/null | grep Mem:)
TOTAL=$(echo $MEM | awk "{print \\$2}")
USED=$(echo $MEM | awk "{print \\$3}")
AVAIL=$(echo $MEM | awk "{print \\$7}")
echo "MEM_TOTAL_MB:$TOTAL"
echo "MEM_USED_MB:$USED"
echo "MEM_AVAIL_MB:$AVAIL"

# CPU usage — use /proc/stat for reliable cross-distro measurement
read -r _ u1 n1 s1 i1 w1 _ < /proc/stat
sleep 1
read -r _ u2 n2 s2 i2 w2 _ < /proc/stat
IDLE=$((i2 - i1))
TOTAL=$(( (u2+n2+s2+i2+w2) - (u1+n1+s1+i1+w1) ))
if [ "$TOTAL" -gt 0 ]; then
    CPU_IDLE=$((IDLE * 100 / TOTAL))
else
    CPU_IDLE=100
fi
echo "CPU_IDLE:$CPU_IDLE"
'"""
    output = _ssh_exec(host, cmd, timeout=15)
    if not output:
        return {"error": "unreachable"}

    metrics = {}
    for line in output.splitlines():
        if ":" in line:
            key, val = line.split(":", 1)
            metrics[key.strip()] = val.strip()

    def safe_int(val: str, default: int = 0) -> int:
        try:
            return int(val.strip()) if val.strip() else default
        except (ValueError, AttributeError):
            return default

    def safe_float(val: str, default: float = 0.0) -> float:
        try:
            return float(val.strip()) if val.strip() else default
        except (ValueError, AttributeError):
            return default

    try:
        load_parts = metrics.get("LOAD", "0 0 0").split()
        cpu_cores = safe_int(metrics.get("CPU_CORES", "1"), 1)
        mem_total = safe_int(metrics.get("MEM_TOTAL_MB", "0"))
        mem_used = safe_int(metrics.get("MEM_USED_MB", "0"))
        mem_avail = safe_int(metrics.get("MEM_AVAIL_MB", "0"))
        cpu_idle = safe_float(metrics.get("CPU_IDLE", "0"))

        return {
            "uptime": metrics.get("UPTIME", "unknown"),
            "cpu_cores": cpu_cores,
            "load_1m": safe_float(load_parts[0]) if load_parts else 0,
            "load_5m": safe_float(load_parts[1]) if len(load_parts) > 1 else 0,
            "load_15m": safe_float(load_parts[2]) if len(load_parts) > 2 else 0,
            "cpu_usage_pct": round(100.0 - cpu_idle, 1),
            "memory_total_mb": mem_total,
            "memory_used_mb": mem_used,
            "memory_available_mb": mem_avail,
            "memory_usage_pct": round((mem_used / mem_total * 100), 1) if mem_total > 0 else 0,
        }
    except Exception as e:
        return {"error": str(e)}


def _get_kafka_metrics(host: Host) -> dict:
    """Get Kafka broker metrics — service status, log size, topic count."""
    cmd = """bash -c '
# Service status
ACTIVE=$(systemctl is-active kafka 2>/dev/null || echo "unknown")
echo "KAFKA_STATUS:$ACTIVE"

# PID and uptime
PID=$(systemctl show kafka -p MainPID --value 2>/dev/null || echo 0)
echo "KAFKA_PID:$PID"
if [ "$PID" != "0" ] && [ -d "/proc/$PID" ]; then
    START=$(stat -c %Y /proc/$PID 2>/dev/null || echo 0)
    NOW=$(date +%s)
    UPTIME_SECS=$((NOW - START))
    echo "KAFKA_UPTIME_SECS:$UPTIME_SECS"

    # JVM memory from /proc
    RSS=$(awk "/^VmRSS/{print \\$2}" /proc/$PID/status 2>/dev/null || echo 0)
    echo "KAFKA_RSS_KB:$RSS"
else
    echo "KAFKA_UPTIME_SECS:0"
    echo "KAFKA_RSS_KB:0"
fi

# Data directory size
DATA_SIZE=$(du -sm /var/lib/kafka/data 2>/dev/null | awk "{print \\$1}" || echo 0)
echo "KAFKA_DATA_MB:$DATA_SIZE"

# Log directory size
LOG_SIZE=$(du -sm /opt/kafka/logs 2>/dev/null | awk "{print \\$1}" || echo 0)
echo "KAFKA_LOG_MB:$LOG_SIZE"

# Topic & partition count (prefer kafka CLI for accuracy, fall back to filesystem)
JAVA_HOME_DIR=$(readlink -f $(which java 2>/dev/null) 2>/dev/null | sed "s|/bin/java||" || echo "/usr")
export JAVA_HOME=$JAVA_HOME_DIR
TOPIC_INFO=$(/opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 --list 2>/dev/null | grep -v "^$" | wc -l || echo -1)
if [ "$TOPIC_INFO" -ge 0 ] 2>/dev/null; then
    echo "KAFKA_TOPICS:$TOPIC_INFO"
    PART_INFO=$(/opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 --describe 2>/dev/null | grep "PartitionCount" | awk -F'PartitionCount:' "{sum+=\\$2} END {print sum+0}" || echo 0)
    echo "KAFKA_PARTITIONS:$PART_INFO"
else
    # Fallback to filesystem
    TOPICS=$(ls -d /var/lib/kafka/data/*-* 2>/dev/null | sed "s/-[0-9]*$//" | sort -u | wc -l || echo 0)
    echo "KAFKA_TOPICS:$TOPICS"
    PARTITIONS=$(ls -d /var/lib/kafka/data/*-* 2>/dev/null | wc -l || echo 0)
    echo "KAFKA_PARTITIONS:$PARTITIONS"
fi

# Open file descriptors
if [ "$PID" != "0" ] && [ -d "/proc/$PID/fd" ]; then
    FDS=$(ls /proc/$PID/fd 2>/dev/null | wc -l || echo 0)
    echo "KAFKA_FDS:$FDS"
else
    echo "KAFKA_FDS:0"
fi

# Network connections on 9092
CONNECTIONS=$(ss -tn 2>/dev/null | grep -c ":9092" || echo 0)
echo "KAFKA_CONNECTIONS:$CONNECTIONS"
'"""
    output = _ssh_exec(host, cmd, timeout=15)
    if not output:
        return {"error": "unreachable"}

    metrics = {}
    for line in output.splitlines():
        if ":" in line:
            key, val = line.split(":", 1)
            metrics[key.strip()] = val.strip()

    def safe_int(val: str, default: int = 0) -> int:
        try:
            return int(val.strip()) if val.strip() else default
        except (ValueError, AttributeError):
            return default

    try:
        uptime_secs = safe_int(metrics.get("KAFKA_UPTIME_SECS", "0"))
        hours = uptime_secs // 3600
        minutes = (uptime_secs % 3600) // 60

        return {
            "status": metrics.get("KAFKA_STATUS", "unknown"),
            "pid": safe_int(metrics.get("KAFKA_PID", "0")),
            "uptime": f"{hours}h {minutes}m" if uptime_secs > 0 else "not running",
            "uptime_seconds": uptime_secs,
            "memory_rss_mb": round(safe_int(metrics.get("KAFKA_RSS_KB", "0")) / 1024, 1),
            "data_size_mb": safe_int(metrics.get("KAFKA_DATA_MB", "0")),
            "log_size_mb": safe_int(metrics.get("KAFKA_LOG_MB", "0")),
            "topics": safe_int(metrics.get("KAFKA_TOPICS", "0")),
            "partitions": safe_int(metrics.get("KAFKA_PARTITIONS", "0")),
            "open_fds": safe_int(metrics.get("KAFKA_FDS", "0")),
            "connections": safe_int(metrics.get("KAFKA_CONNECTIONS", "0")),
        }
    except Exception as e:
        return {"error": str(e)}


def _get_disk_metrics(host: Host) -> dict:
    """Get disk usage for Kafka data and root partitions."""
    cmd = """bash -c '
df -m / 2>/dev/null | tail -1 | awk "{print \\"ROOT_TOTAL_MB:\\"\\$2\\"\\nROOT_USED_MB:\\"\\$3\\"\\nROOT_AVAIL_MB:\\"\\$4\\"\\nROOT_USE_PCT:\\"\\$5}"
df -m /var/lib/kafka/data 2>/dev/null | tail -1 | awk "{print \\"DATA_TOTAL_MB:\\"\\$2\\"\\nDATA_USED_MB:\\"\\$3\\"\\nDATA_AVAIL_MB:\\"\\$4\\"\\nDATA_USE_PCT:\\"\\$5}"
'"""
    output = _ssh_exec(host, cmd, timeout=10)
    if not output:
        return {"error": "unreachable"}

    metrics = {}
    for line in output.splitlines():
        if ":" in line:
            key, val = line.split(":", 1)
            metrics[key.strip()] = val.strip().rstrip("%")

    try:
        return {
            "root": {
                "total_mb": int(metrics.get("ROOT_TOTAL_MB", "0")),
                "used_mb": int(metrics.get("ROOT_USED_MB", "0")),
                "available_mb": int(metrics.get("ROOT_AVAIL_MB", "0")),
                "usage_pct": int(metrics.get("ROOT_USE_PCT", "0")),
            },
            "data": {
                "total_mb": int(metrics.get("DATA_TOTAL_MB", "0")),
                "used_mb": int(metrics.get("DATA_USED_MB", "0")),
                "available_mb": int(metrics.get("DATA_AVAIL_MB", "0")),
                "usage_pct": int(metrics.get("DATA_USE_PCT", "0")),
            },
        }
    except Exception as e:
        return {"error": str(e)}


# ── Prometheus/Grafana deployment ─────────────────────

@router.post("/clusters/{cluster_id}/deploy")
def deploy_monitoring(
    cluster_id: str,
    req: MonitoringDeployRequest,
    db: Session = Depends(get_db),
    _: User = Depends(require_admin),
):
    """Deploy Prometheus + Grafana + JMX exporter for a cluster."""
    try:
        result = MonitoringDeployer.deploy_monitoring_stack(
            cluster_id, req.monitoring_host_id,
            req.grafana_port, req.prometheus_port, db,
        )
        return result
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.get("/clusters/{cluster_id}/grafana")
def get_grafana_info(
    cluster_id: str,
    db: Session = Depends(get_db),
    _: User = Depends(require_monitor_or_above),
):
    """Get Grafana connection info for embedding."""
    return MonitoringDeployer.get_grafana_info(cluster_id, db)

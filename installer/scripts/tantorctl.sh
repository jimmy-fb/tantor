#!/usr/bin/env bash
###############################################################################
# tantorctl — Tantor Kafka Manager Control CLI
#
# Usage:
#   tantorctl status          Show service status
#   tantorctl start           Start all services
#   tantorctl stop            Stop all services
#   tantorctl restart         Restart all services
#   tantorctl logs [service]  Show logs (backend|nginx|all)
#   tantorctl version         Show Tantor version
#   tantorctl health          Check API health
#   tantorctl reset-password  Reset admin password to default
#   tantorctl backup          Backup database
#   tantorctl restore <file>  Restore database from backup
###############################################################################

set -e

TANTOR_HOME="${TANTOR_HOME:-/opt/tantor}"
TANTOR_DATA="${TANTOR_DATA:-/var/lib/tantor}"
TANTOR_LOG="${TANTOR_LOG:-/var/log/tantor}"
VERSION="1.0.0"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

banner() {
    echo -e "${CYAN}"
    echo "  ╔════════════════════════════════════════╗"
    echo "  ║    Tantor Kafka Manager v${VERSION}       ║"
    echo "  ╚════════════════════════════════════════╝"
    echo -e "${NC}"
}

# Detect if running in Docker (supervisor) or bare metal (systemd)
is_docker() {
    [ -f /.dockerenv ] || grep -qE '(docker|containerd)' /proc/1/cgroup 2>/dev/null
}

cmd_status() {
    banner
    if is_docker; then
        supervisorctl status
    else
        echo -e "${BLUE}Backend:${NC}"
        systemctl status tantor-backend --no-pager -l 2>/dev/null || echo "  Not installed as systemd service"
        echo ""
        echo -e "${BLUE}Nginx:${NC}"
        systemctl status nginx --no-pager -l 2>/dev/null || echo "  Not running"
    fi

    echo ""
    echo -e "${BLUE}Health Check:${NC}"
    HTTP=$(curl -sf -o /dev/null -w "%{http_code}" http://localhost/api/health 2>/dev/null || echo "000")
    if [ "$HTTP" = "200" ]; then
        echo -e "  ${GREEN}✓ API is healthy (HTTP 200)${NC}"
    else
        echo -e "  ${RED}✗ API is not responding (HTTP $HTTP)${NC}"
    fi
}

cmd_start() {
    echo -e "${BLUE}▶ Starting Tantor...${NC}"
    if is_docker; then
        supervisorctl start all
    else
        systemctl start tantor-backend nginx
    fi
    sleep 2
    cmd_health
}

cmd_stop() {
    echo -e "${YELLOW}▶ Stopping Tantor...${NC}"
    if is_docker; then
        supervisorctl stop all
    else
        systemctl stop tantor-backend nginx
    fi
    echo -e "${GREEN}✓ Stopped${NC}"
}

cmd_restart() {
    echo -e "${BLUE}▶ Restarting Tantor...${NC}"
    if is_docker; then
        supervisorctl restart all
    else
        systemctl restart tantor-backend nginx
    fi
    sleep 2
    cmd_health
}

cmd_logs() {
    local SERVICE="${1:-all}"
    case "$SERVICE" in
        backend)
            tail -f ${TANTOR_LOG}/backend/stdout.log
            ;;
        nginx)
            tail -f ${TANTOR_LOG}/nginx/access.log
            ;;
        error)
            tail -f ${TANTOR_LOG}/backend/stderr.log ${TANTOR_LOG}/nginx/error.log
            ;;
        all|*)
            tail -f ${TANTOR_LOG}/backend/stdout.log ${TANTOR_LOG}/nginx/access.log
            ;;
    esac
}

cmd_version() {
    banner
    echo "  Tantor Version:  ${VERSION}"
    echo "  Install Path:    ${TANTOR_HOME}"
    echo "  Data Path:       ${TANTOR_DATA}"
    echo "  Log Path:        ${TANTOR_LOG}"
    echo "  Database:        ${TANTOR_DATA}/db/tantor.db"
    echo ""

    # Show backend version from API
    RESP=$(curl -sf http://localhost/api/health 2>/dev/null || echo '{}')
    API_VER=$(echo "$RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('version','unknown'))" 2>/dev/null || echo "unknown")
    echo "  API Version:     ${API_VER}"
}

cmd_health() {
    HTTP=$(curl -sf -o /dev/null -w "%{http_code}" http://localhost/api/health 2>/dev/null || echo "000")
    if [ "$HTTP" = "200" ]; then
        echo -e "${GREEN}✓ Tantor is running — http://localhost${NC}"
    else
        echo -e "${RED}✗ Tantor is not healthy (HTTP $HTTP)${NC}"
        echo "  Check logs: tantorctl logs error"
        exit 1
    fi
}

cmd_backup() {
    local BACKUP_DIR="${TANTOR_DATA}/backups"
    mkdir -p "$BACKUP_DIR"
    local TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    local BACKUP_FILE="${BACKUP_DIR}/tantor_backup_${TIMESTAMP}.db"

    cp "${TANTOR_DATA}/db/tantor.db" "$BACKUP_FILE" 2>/dev/null || \
    cp "${TANTOR_HOME}/backend/tantor.db" "$BACKUP_FILE"

    echo -e "${GREEN}✓ Backup saved: ${BACKUP_FILE}${NC}"

    # Keep last 10 backups
    ls -t "${BACKUP_DIR}"/tantor_backup_*.db 2>/dev/null | tail -n +11 | xargs rm -f 2>/dev/null || true
}

cmd_restore() {
    local BACKUP_FILE="$1"
    if [ -z "$BACKUP_FILE" ] || [ ! -f "$BACKUP_FILE" ]; then
        echo -e "${RED}Error: Backup file not found: $BACKUP_FILE${NC}"
        echo "Available backups:"
        ls -lt "${TANTOR_DATA}/backups"/tantor_backup_*.db 2>/dev/null || echo "  No backups found"
        exit 1
    fi

    echo -e "${YELLOW}▶ Stopping Tantor for restore...${NC}"
    cmd_stop

    cp "$BACKUP_FILE" "${TANTOR_DATA}/db/tantor.db"

    echo -e "${GREEN}✓ Database restored from: ${BACKUP_FILE}${NC}"
    echo -e "${BLUE}▶ Starting Tantor...${NC}"
    cmd_start
}

cmd_reset_password() {
    echo -e "${YELLOW}▶ Resetting admin password to 'admin'...${NC}"
    cd "${TANTOR_HOME}/backend"
    python3 -c "
from app.database import SessionLocal
from app.models.user import User
from app.services.auth_service import AuthService

db = SessionLocal()
user = db.query(User).filter(User.username == 'admin').first()
if user:
    user.hashed_password = AuthService.hash_password('admin')
    db.commit()
    print('Admin password reset to: admin')
else:
    print('Admin user not found — it will be created on next startup')
db.close()
"
    echo -e "${GREEN}✓ Password reset complete${NC}"
}

# ─── Main ───
case "${1:-}" in
    status)         cmd_status ;;
    start)          cmd_start ;;
    stop)           cmd_stop ;;
    restart)        cmd_restart ;;
    logs)           cmd_logs "$2" ;;
    version|--version|-v)  cmd_version ;;
    health)         cmd_health ;;
    backup)         cmd_backup ;;
    restore)        cmd_restore "$2" ;;
    reset-password) cmd_reset_password ;;
    *)
        banner
        echo "Usage: tantorctl <command>"
        echo ""
        echo "Commands:"
        echo "  status           Show service status and health"
        echo "  start            Start all Tantor services"
        echo "  stop             Stop all Tantor services"
        echo "  restart          Restart all Tantor services"
        echo "  logs [service]   Tail logs (backend|nginx|error|all)"
        echo "  health           Quick API health check"
        echo "  version          Show version and paths"
        echo "  backup           Backup the database"
        echo "  restore <file>   Restore database from backup"
        echo "  reset-password   Reset admin password to 'admin'"
        echo ""
        ;;
esac

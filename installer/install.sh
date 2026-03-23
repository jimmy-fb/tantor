#!/usr/bin/env bash
###############################################################################
#
#   ████████╗ █████╗ ███╗   ██╗████████╗ ██████╗ ██████╗
#   ╚══██╔══╝██╔══██╗████╗  ██║╚══██╔══╝██╔═══██╗██╔══██╗
#      ██║   ███████║██╔██╗ ██║   ██║   ██║   ██║██████╔╝
#      ██║   ██╔══██║██║╚██╗██║   ██║   ██║   ██║██╔══██╗
#      ██║   ██║  ██║██║ ╚████║   ██║   ╚██████╔╝██║  ██║
#      ╚═╝   ╚═╝  ╚═╝╚═╝  ╚═══╝   ╚═╝    ╚═════╝ ╚═╝  ╚═╝
#
#   Tantor Kafka Manager — Installer
#
#   Usage:
#     sudo ./install.sh                    # Auto-detect OS, install natively
#     sudo ./install.sh --docker           # Install via Docker (any OS)
#     sudo ./install.sh --docker --rhel    # Docker RHEL image
#     sudo ./install.sh --uninstall        # Remove Tantor
#
#   After install:
#     Open http://<your-ip> in a browser
#     Login: admin / admin
#
###############################################################################

set -e

VERSION="1.0.0"
TANTOR_HOME="/opt/tantor"
TANTOR_DATA="/var/lib/tantor"
TANTOR_LOG="/var/log/tantor"
TANTOR_USER="tantor"

# ─── Colors ───
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ─── Defaults ───
INSTALL_MODE="native"   # native or docker
OS_FAMILY=""             # debian or rhel
DOCKER_BASE="ubuntu"    # ubuntu or rhel
FORCE=false
UNINSTALL=false

# ─── Parse Arguments ───
while [[ $# -gt 0 ]]; do
    case $1 in
        --docker)   INSTALL_MODE="docker"; shift ;;
        --rhel)     DOCKER_BASE="rhel"; shift ;;
        --ubuntu)   DOCKER_BASE="ubuntu"; shift ;;
        --force)    FORCE=true; shift ;;
        --uninstall) UNINSTALL=true; shift ;;
        --help|-h)
            echo "Usage: sudo $0 [options]"
            echo ""
            echo "Options:"
            echo "  --docker         Install using Docker (recommended)"
            echo "  --rhel           Use RHEL/Rocky Linux base (Docker mode)"
            echo "  --ubuntu         Use Ubuntu base (Docker mode, default)"
            echo "  --force          Skip confirmation prompts"
            echo "  --uninstall      Remove Tantor installation"
            echo "  --help           Show this help"
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            exit 1
            ;;
    esac
done

# ─── Banner ───
banner() {
    echo ""
    echo -e "${CYAN}  ████████╗ █████╗ ███╗   ██╗████████╗ ██████╗ ██████╗ ${NC}"
    echo -e "${CYAN}  ╚══██╔══╝██╔══██╗████╗  ██║╚══██╔══╝██╔═══██╗██╔══██╗${NC}"
    echo -e "${CYAN}     ██║   ███████║██╔██╗ ██║   ██║   ██║   ██║██████╔╝${NC}"
    echo -e "${CYAN}     ██║   ██╔══██║██║╚██╗██║   ██║   ██║   ██║██╔══██╗${NC}"
    echo -e "${CYAN}     ██║   ██║  ██║██║ ╚████║   ██║   ╚██████╔╝██║  ██║${NC}"
    echo -e "${CYAN}     ╚═╝   ╚═╝  ╚═╝╚═╝  ╚═══╝   ╚═╝    ╚═════╝ ╚═╝  ╚═╝${NC}"
    echo ""
    echo -e "  ${BOLD}Kafka Cluster Manager${NC}  v${VERSION}"
    echo -e "  Like Cloudera Manager, but for Apache Kafka"
    echo ""
}

# ─── Detect OS ───
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        case "$ID" in
            ubuntu|debian|linuxmint|pop)
                OS_FAMILY="debian"
                ;;
            rhel|centos|rocky|almalinux|fedora|ol|amzn)
                OS_FAMILY="rhel"
                ;;
            *)
                OS_FAMILY="unknown"
                ;;
        esac
        OS_NAME="${PRETTY_NAME:-$ID}"
    elif [ "$(uname)" = "Darwin" ]; then
        OS_FAMILY="macos"
        OS_NAME="macOS $(sw_vers -productVersion 2>/dev/null || echo '')"
    else
        OS_FAMILY="unknown"
        OS_NAME="Unknown"
    fi
}

log_info()  { echo -e "  ${GREEN}✓${NC} $1"; }
log_warn()  { echo -e "  ${YELLOW}⚠${NC} $1"; }
log_error() { echo -e "  ${RED}✗${NC} $1"; }
log_step()  { echo -e "\n${BLUE}▶ $1${NC}"; }

# ─── Root check ───
check_root() {
    if [ "$EUID" -ne 0 ] && [ "$INSTALL_MODE" = "native" ]; then
        log_error "Native installation requires root. Run with: sudo $0"
        echo "  Or use Docker mode: sudo $0 --docker"
        exit 1
    fi
}

# ═══════════════════════════════════════════════════════
# DOCKER INSTALLATION
# ═══════════════════════════════════════════════════════

install_docker_mode() {
    log_step "Installing Tantor via Docker"

    # Check Docker
    if ! command -v docker &>/dev/null; then
        log_error "Docker is not installed"
        echo ""
        echo "  Install Docker first:"
        echo "    curl -fsSL https://get.docker.com | sh"
        echo ""
        exit 1
    fi

    if ! docker info &>/dev/null 2>&1; then
        log_error "Docker daemon is not running"
        exit 1
    fi
    log_info "Docker is available"

    # Check for existing container
    if docker ps -a --format '{{.Names}}' | grep -q '^tantor$'; then
        if [ "$FORCE" = true ]; then
            log_warn "Removing existing Tantor container"
            docker stop tantor 2>/dev/null || true
            docker rm tantor 2>/dev/null || true
        else
            log_warn "Tantor container already exists"
            echo ""
            echo "  Use --force to replace it, or manage with:"
            echo "    docker start tantor"
            echo "    docker stop tantor"
            echo "    docker logs tantor"
            exit 1
        fi
    fi

    # Determine Dockerfile
    local DOCKERFILE="installer/docker/Dockerfile.ubuntu"
    local IMAGE_TAG="tantor:${VERSION}-ubuntu"
    if [ "$DOCKER_BASE" = "rhel" ]; then
        DOCKERFILE="installer/docker/Dockerfile.rhel"
        IMAGE_TAG="tantor:${VERSION}-rhel"
    fi

    # Check if we're in the repo root
    if [ ! -f "$DOCKERFILE" ]; then
        log_error "Cannot find $DOCKERFILE"
        echo "  Run this script from the tantor repository root directory"
        exit 1
    fi

    log_step "Building Tantor Docker image ($DOCKER_BASE)"
    echo "  This may take a few minutes on first build..."
    echo ""

    docker build -t "$IMAGE_TAG" -f "$DOCKERFILE" . 2>&1 | while IFS= read -r line; do
        echo "  $line"
    done

    if [ $? -ne 0 ]; then
        log_error "Docker build failed"
        exit 1
    fi
    log_info "Image built: $IMAGE_TAG"

    # Create data volume
    log_step "Creating persistent data volume"
    docker volume create tantor-data 2>/dev/null || true
    log_info "Volume: tantor-data"

    # Run container
    log_step "Starting Tantor container"
    docker run -d \
        --name tantor \
        --hostname tantor \
        -p 80:80 \
        -v tantor-data:/var/lib/tantor \
        --restart unless-stopped \
        "$IMAGE_TAG"

    log_info "Container started: tantor"

    # Wait for health
    log_step "Waiting for Tantor to become healthy"
    for i in $(seq 1 30); do
        if curl -sf http://localhost/api/health &>/dev/null; then
            break
        fi
        sleep 1
        printf "."
    done
    echo ""

    if curl -sf http://localhost/api/health &>/dev/null; then
        print_success
    else
        log_warn "Tantor is starting up (may take a few more seconds)"
        echo ""
        echo "  Check status:  docker logs tantor"
        echo "  Access:        http://localhost"
    fi

    # Install tantorctl on host
    install_host_cli
}

# ═══════════════════════════════════════════════════════
# NATIVE INSTALLATION (Debian / RHEL)
# ═══════════════════════════════════════════════════════

install_native_mode() {
    detect_os

    if [ "$OS_FAMILY" = "macos" ]; then
        log_error "Native installation is not supported on macOS"
        echo "  Use Docker mode instead: sudo $0 --docker"
        exit 1
    fi

    if [ "$OS_FAMILY" = "unknown" ]; then
        log_error "Unsupported OS: $OS_NAME"
        echo "  Use Docker mode instead: sudo $0 --docker"
        exit 1
    fi

    log_step "Installing Tantor natively on $OS_NAME"
    echo "  OS Family: $OS_FAMILY"

    # Check if we're in the repo root
    if [ ! -f "backend/requirements.txt" ] || [ ! -f "frontend/package.json" ]; then
        log_error "Run this script from the tantor repository root directory"
        exit 1
    fi

    # ─── Install system packages ───
    log_step "Installing system dependencies"
    if [ "$OS_FAMILY" = "debian" ]; then
        install_deps_debian
    else
        install_deps_rhel
    fi

    # ─── Create user and directories ───
    log_step "Creating tantor user and directories"
    id -u $TANTOR_USER &>/dev/null || useradd -r -m -s /bin/bash $TANTOR_USER
    log_info "User: $TANTOR_USER"

    mkdir -p \
        ${TANTOR_HOME}/backend \
        ${TANTOR_HOME}/frontend/dist \
        ${TANTOR_HOME}/bin \
        ${TANTOR_DATA}/db \
        ${TANTOR_DATA}/repo \
        ${TANTOR_DATA}/ansible_work \
        ${TANTOR_DATA}/ssh \
        ${TANTOR_DATA}/backups \
        ${TANTOR_LOG}/backend \
        ${TANTOR_LOG}/nginx
    log_info "Directories created"

    # ─── Install Python dependencies ───
    log_step "Installing Python packages"
    if [ -n "${TANTOR_PIP_CMD:-}" ]; then
        $TANTOR_PIP_CMD install --quiet -r backend/requirements.txt
    else
        pip3 install --quiet -r backend/requirements.txt
    fi
    log_info "Python packages installed"

    # ─── Copy backend ───
    log_step "Installing backend"
    cp -r backend/app ${TANTOR_HOME}/backend/
    cp backend/requirements.txt ${TANTOR_HOME}/backend/
    mkdir -p ${TANTOR_HOME}/backend/repo ${TANTOR_HOME}/backend/ansible_work

    # Symlink data dirs
    ln -sf ${TANTOR_DATA}/db/tantor.db ${TANTOR_HOME}/backend/tantor.db
    ln -sf ${TANTOR_DATA}/repo ${TANTOR_HOME}/backend/repo
    ln -sf ${TANTOR_DATA}/ansible_work ${TANTOR_HOME}/backend/ansible_work
    log_info "Backend installed to ${TANTOR_HOME}/backend"

    # ─── Build and install frontend ───
    log_step "Building frontend"
    if command -v node &>/dev/null && command -v npm &>/dev/null; then
        cd frontend
        npm ci --prefer-offline 2>/dev/null || npm install
        npm run build
        cp -r dist/* ${TANTOR_HOME}/frontend/dist/
        cd ..
        log_info "Frontend built and installed"
    else
        log_error "Node.js is required to build the frontend"
        echo "  Install Node.js 18+ and re-run the installer"
        exit 1
    fi

    # ─── Nginx config ───
    log_step "Configuring Nginx"
    cp installer/config/nginx-tantor.conf /etc/nginx/sites-enabled/tantor.conf 2>/dev/null || \
    cp installer/config/nginx-tantor.conf /etc/nginx/conf.d/tantor.conf
    rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true
    rm -f /etc/nginx/conf.d/default.conf 2>/dev/null || true
    # RHEL nginx.conf has a default server block that conflicts — remove it
    if grep -q 'default_server' /etc/nginx/nginx.conf 2>/dev/null; then
        sed -i '/^    server {/,/^    }/d' /etc/nginx/nginx.conf
    fi
    # SELinux: allow nginx to proxy to backend
    if command -v setsebool &>/dev/null; then
        setsebool -P httpd_can_network_connect 1 2>/dev/null || true
    fi
    log_info "Nginx configured"

    # ─── Systemd service ───
    log_step "Installing systemd service"
    cp installer/systemd/tantor-backend.service /etc/systemd/system/
    systemctl daemon-reload
    systemctl enable tantor-backend nginx
    log_info "Systemd services enabled"

    # ─── Set ownership ───
    chown -R ${TANTOR_USER}:${TANTOR_USER} ${TANTOR_HOME} ${TANTOR_DATA} ${TANTOR_LOG}

    # ─── Install tantorctl ───
    cp installer/scripts/tantorctl.sh ${TANTOR_HOME}/bin/tantorctl
    chmod +x ${TANTOR_HOME}/bin/tantorctl
    ln -sf ${TANTOR_HOME}/bin/tantorctl /usr/local/bin/tantorctl
    log_info "tantorctl installed"

    # ─── Start services ───
    log_step "Starting Tantor"
    systemctl start nginx
    systemctl start tantor-backend

    # Wait for health
    for i in $(seq 1 15); do
        if curl -sf http://localhost/api/health &>/dev/null; then
            break
        fi
        sleep 1
    done

    if curl -sf http://localhost/api/health &>/dev/null; then
        print_success
    else
        log_warn "Services started but API not yet ready"
        echo "  Check: tantorctl status"
    fi
}

install_deps_debian() {
    apt-get update -qq
    apt-get install -y --no-install-recommends \
        python3 \
        python3-pip \
        python3-venv \
        nginx \
        openssh-client \
        sshpass \
        wget \
        curl \
        jq \
        gnupg \
        ca-certificates \
        net-tools \
        >/dev/null 2>&1

    # Node.js (for building frontend)
    if ! command -v node &>/dev/null; then
        curl -fsSL https://deb.nodesource.com/setup_22.x | bash - >/dev/null 2>&1
        apt-get install -y nodejs >/dev/null 2>&1
    fi
    log_info "System packages installed (Debian/Ubuntu)"
}

install_deps_rhel() {
    dnf install -y epel-release >/dev/null 2>&1 || true

    # Determine Python version — need 3.9+ for FastAPI
    # RHEL 8.x ships Python 3.6 by default; use AppStream module for 3.11
    local PYTHON_CMD="python3"
    local PIP_CMD="pip3"
    local py_ver
    py_ver=$(python3 -c 'import sys; print(sys.version_info.minor)' 2>/dev/null || echo "0")

    if [ "$py_ver" -lt 9 ]; then
        log_info "Default Python 3.${py_ver} too old, installing Python 3.11..."
        dnf module enable -y python311 2>/dev/null || true
        dnf install -y python3.11 python3.11-pip python3.11-devel >/dev/null 2>&1
        if command -v python3.11 &>/dev/null; then
            PYTHON_CMD="python3.11"
            PIP_CMD="python3.11 -m pip"
            # Set alternatives so python3/pip3 point to 3.11
            alternatives --set python3 /usr/bin/python3.11 2>/dev/null || \
                alternatives --install /usr/bin/python3 python3 /usr/bin/python3.11 1 2>/dev/null || true
            log_info "Python 3.11 installed and set as default python3"
        else
            log_error "Failed to install Python 3.11 — cannot continue"
            exit 1
        fi
    fi

    dnf install -y \
        nginx \
        openssh-clients \
        sshpass \
        wget \
        curl \
        jq \
        gnupg2 \
        ca-certificates \
        net-tools \
        >/dev/null 2>&1

    # Node.js
    if ! command -v node &>/dev/null; then
        curl -fsSL https://rpm.nodesource.com/setup_22.x | bash - >/dev/null 2>&1
        dnf install -y nodejs >/dev/null 2>&1
    fi
    log_info "System packages installed (RHEL/Rocky)"

    # Export for use by pip install step
    export TANTOR_PYTHON_CMD="$PYTHON_CMD"
    export TANTOR_PIP_CMD="$PIP_CMD"
}

# ─── Install tantorctl wrapper on Docker host ───
install_host_cli() {
    log_step "Installing tantorctl CLI on host"

    cat > /usr/local/bin/tantorctl << 'HOSTCTL'
#!/usr/bin/env bash
# tantorctl — host wrapper that delegates to Docker container
CONTAINER="tantor"

if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER}$"; then
    echo "Tantor container is not running."
    echo "  Start:  docker start tantor"
    exit 1
fi

case "${1:-}" in
    status)
        echo ""
        echo "  Container:  $(docker inspect --format='{{.State.Status}}' $CONTAINER)"
        echo "  Uptime:     $(docker inspect --format='{{.State.StartedAt}}' $CONTAINER)"
        echo "  Image:      $(docker inspect --format='{{.Config.Image}}' $CONTAINER)"
        echo "  Port:       $(docker port $CONTAINER 80 2>/dev/null || echo 'not mapped')"
        echo ""
        docker exec $CONTAINER tantorctl health
        ;;
    logs)
        docker exec $CONTAINER tantorctl logs "${2:-all}"
        ;;
    start)
        docker start $CONTAINER
        echo "Tantor started"
        ;;
    stop)
        docker stop $CONTAINER
        echo "Tantor stopped"
        ;;
    restart)
        docker restart $CONTAINER
        sleep 3
        docker exec $CONTAINER tantorctl health
        ;;
    health)
        docker exec $CONTAINER tantorctl health
        ;;
    version)
        docker exec $CONTAINER tantorctl version
        ;;
    backup)
        docker exec $CONTAINER tantorctl backup
        ;;
    restore)
        docker exec $CONTAINER tantorctl restore "$2"
        ;;
    reset-password)
        docker exec $CONTAINER tantorctl reset-password
        ;;
    shell)
        docker exec -it $CONTAINER bash
        ;;
    *)
        echo ""
        echo "  Tantor Kafka Manager — CLI"
        echo ""
        echo "  Usage: tantorctl <command>"
        echo ""
        echo "  Commands:"
        echo "    status           Show container and service status"
        echo "    start            Start Tantor container"
        echo "    stop             Stop Tantor container"
        echo "    restart          Restart Tantor container"
        echo "    logs [service]   Tail logs (backend|nginx|error|all)"
        echo "    health           Quick API health check"
        echo "    version          Show version and paths"
        echo "    backup           Backup the database"
        echo "    restore <file>   Restore database from backup"
        echo "    reset-password   Reset admin password to 'admin'"
        echo "    shell            Open a bash shell in the container"
        echo ""
        ;;
esac
HOSTCTL

    chmod +x /usr/local/bin/tantorctl
    log_info "tantorctl installed to /usr/local/bin/tantorctl"
}

# ═══════════════════════════════════════════════════════
# UNINSTALL
# ═══════════════════════════════════════════════════════

do_uninstall() {
    banner
    echo -e "${RED}  This will remove Tantor from this system.${NC}"
    echo ""

    if [ "$FORCE" != true ]; then
        read -p "  Are you sure? [y/N] " CONFIRM
        if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
            echo "  Cancelled."
            exit 0
        fi
    fi

    log_step "Removing Tantor"

    # Docker cleanup
    if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q '^tantor$'; then
        docker stop tantor 2>/dev/null || true
        docker rm tantor 2>/dev/null || true
        log_info "Docker container removed"
    fi

    # Remove Docker images
    docker rmi tantor:${VERSION}-ubuntu tantor:${VERSION}-rhel 2>/dev/null || true

    # Systemd cleanup
    if [ -f /etc/systemd/system/tantor-backend.service ]; then
        systemctl stop tantor-backend 2>/dev/null || true
        systemctl disable tantor-backend 2>/dev/null || true
        rm -f /etc/systemd/system/tantor-backend.service
        systemctl daemon-reload
        log_info "Systemd service removed"
    fi

    # Nginx config
    rm -f /etc/nginx/sites-enabled/tantor.conf 2>/dev/null
    rm -f /etc/nginx/conf.d/tantor.conf 2>/dev/null
    systemctl reload nginx 2>/dev/null || true
    log_info "Nginx config removed"

    # Files
    rm -rf ${TANTOR_HOME}
    rm -rf ${TANTOR_LOG}
    rm -f /usr/local/bin/tantorctl
    log_info "Application files removed"

    echo ""
    echo -e "  ${YELLOW}Note: Data directory preserved at ${TANTOR_DATA}${NC}"
    echo "  To remove data:  sudo rm -rf ${TANTOR_DATA}"
    echo "  To remove user:  sudo userdel -r ${TANTOR_USER}"
    echo ""
    echo -e "${GREEN}✓ Tantor has been uninstalled${NC}"
}

# ═══════════════════════════════════════════════════════
# SUCCESS MESSAGE
# ═══════════════════════════════════════════════════════

print_success() {
    local IP
    IP=$(hostname -I 2>/dev/null | awk '{print $1}')
    [ -z "$IP" ] && IP="localhost"

    echo ""
    echo -e "${GREEN}  ╔════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}  ║          Tantor installed successfully!            ║${NC}"
    echo -e "${GREEN}  ╚════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${BOLD}Access:${NC}     http://${IP}"
    echo -e "  ${BOLD}Login:${NC}      admin / admin"
    echo ""
    echo -e "  ${BLUE}Management CLI:${NC}"
    echo "    tantorctl status          # Check services"
    echo "    tantorctl logs            # View logs"
    echo "    tantorctl restart         # Restart services"
    echo "    tantorctl backup          # Backup database"
    echo "    tantorctl reset-password  # Reset admin password"
    echo ""
    echo -e "  ${BLUE}Quick Start:${NC}"
    echo "    1. Open http://${IP} in your browser"
    echo "    2. Login with admin / admin"
    echo "    3. Add your Kafka hosts (SSH credentials)"
    echo "    4. Create a cluster and deploy"
    echo ""
}

# ═══════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════

banner

if [ "$UNINSTALL" = true ]; then
    do_uninstall
    exit 0
fi

echo -e "  ${BLUE}Install Mode:${NC}  $INSTALL_MODE"
detect_os
echo -e "  ${BLUE}OS Detected:${NC}   ${OS_NAME:-Unknown}"
if [ "$INSTALL_MODE" = "docker" ]; then
    echo -e "  ${BLUE}Docker Base:${NC}   $DOCKER_BASE"
fi
echo ""

if [ "$FORCE" != true ]; then
    read -p "  Continue with installation? [Y/n] " CONFIRM
    if [[ "$CONFIRM" =~ ^[Nn]$ ]]; then
        echo "  Installation cancelled."
        exit 0
    fi
fi

case "$INSTALL_MODE" in
    docker) install_docker_mode ;;
    native) check_root; install_native_mode ;;
esac

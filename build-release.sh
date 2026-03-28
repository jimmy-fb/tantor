#!/usr/bin/env bash
###############################################################################
#  build-release.sh — Package Tantor into a single distributable tarball
#
#  Output: tantor-<version>-linux.tar.gz
#
#  The tarball contains everything pre-built:
#    - Backend (Python source + requirements.txt)
#    - Frontend (pre-built dist/)
#    - Installer (install.sh + configs + systemd + CLI)
#
#  End user just does:
#    tar xzf tantor-1.0.0-linux.tar.gz
#    cd tantor-1.0.0
#    sudo ./install.sh
#
###############################################################################

set -euo pipefail

VERSION="1.0.0"
RELEASE_NAME="tantor-${VERSION}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="/tmp/${RELEASE_NAME}"
OUTPUT="${SCRIPT_DIR}/${RELEASE_NAME}-linux.tar.gz"

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}"
echo "  ╔════════════════════════════════════════╗"
echo "  ║   Tantor Release Builder v${VERSION}      ║"
echo "  ╚════════════════════════════════════════╝"
echo -e "${NC}"

# ─── Clean ───
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# ─── Step 1: Build Frontend ───
echo -e "${BLUE}▶ Step 1/5: Building frontend...${NC}"
cd "$SCRIPT_DIR/frontend"
npm ci --prefer-offline 2>/dev/null || npm install
npm run build
echo -e "${GREEN}✓ Frontend built${NC}"

# ─── Step 2: Copy Backend ───
echo -e "${BLUE}▶ Step 2/5: Packaging backend...${NC}"
mkdir -p "$BUILD_DIR/backend"
cp -r "$SCRIPT_DIR/backend/app" "$BUILD_DIR/backend/"
cp "$SCRIPT_DIR/backend/requirements.txt" "$BUILD_DIR/backend/"
echo -e "${GREEN}✓ Backend packaged${NC}"

# ─── Step 3: Copy Frontend Dist ───
echo -e "${BLUE}▶ Step 3/5: Packaging frontend...${NC}"
mkdir -p "$BUILD_DIR/frontend/dist"
cp -r "$SCRIPT_DIR/frontend/dist/"* "$BUILD_DIR/frontend/dist/"
echo -e "${GREEN}✓ Frontend packaged (pre-built)${NC}"

# ─── Step 4: Copy Installer Configs ───
echo -e "${BLUE}▶ Step 4/5: Packaging installer...${NC}"
mkdir -p "$BUILD_DIR/config"
mkdir -p "$BUILD_DIR/systemd"
mkdir -p "$BUILD_DIR/bin"

cp "$SCRIPT_DIR/installer/config/nginx-tantor.conf" "$BUILD_DIR/config/"
cp "$SCRIPT_DIR/installer/systemd/tantor-backend.service" "$BUILD_DIR/systemd/"
cp "$SCRIPT_DIR/installer/scripts/tantorctl.sh" "$BUILD_DIR/bin/tantorctl"
chmod +x "$BUILD_DIR/bin/tantorctl"

# Copy supervisor config if exists (for Docker mode)
[ -f "$SCRIPT_DIR/installer/config/supervisord.conf" ] && \
  cp "$SCRIPT_DIR/installer/config/supervisord.conf" "$BUILD_DIR/config/"
  cp "$SCRIPT_DIR/installer/config/kafka-ui-config.yml" "$BUILD_DIR/config/" 2>/dev/null || true
  cp "$SCRIPT_DIR/installer/systemd/tantor-kafka-ui.service" "$BUILD_DIR/systemd/" 2>/dev/null || true

echo -e "${GREEN}✓ Installer configs packaged${NC}"

# ─── Step 4b: Bundle Kafka Binary ───
echo -e "${BLUE}▶ Step 4b/6: Bundling Kafka binary...${NC}"
KAFKA_BINARY="$SCRIPT_DIR/backend/repo/kafka/kafka_2.13-3.7.0.tgz"
mkdir -p "$BUILD_DIR/repo/kafka"
if [ -f "$KAFKA_BINARY" ]; then
    cp "$KAFKA_BINARY" "$BUILD_DIR/repo/kafka/"
    KAFKA_SIZE=$(du -sh "$KAFKA_BINARY" | awk '{print $1}')
    echo -e "${GREEN}✓ Kafka 3.7.0 binary bundled (${KAFKA_SIZE})${NC}"
else
    echo -e "${YELLOW}⚠ Kafka binary not found at $KAFKA_BINARY${NC}"
    echo -e "${YELLOW}  The installer will auto-download it during install.${NC}"
fi

# ─── Step 4c: Bundle Kafka UI JAR ───
echo -e "${BLUE}▶ Step 4c/6: Bundling Kafka UI jar...${NC}"
KAFKA_UI_VERSION="1.4.2"
KAFKA_UI_JAR="$SCRIPT_DIR/backend/repo/kafka-ui/api-v${KAFKA_UI_VERSION}.jar"
mkdir -p "$BUILD_DIR/repo/kafka-ui"
if [ -f "$KAFKA_UI_JAR" ]; then
    cp "$KAFKA_UI_JAR" "$BUILD_DIR/repo/kafka-ui/"
    KUI_SIZE=$(du -sh "$KAFKA_UI_JAR" | awk '{print $1}')
    echo -e "${GREEN}✓ Kafka UI v${KAFKA_UI_VERSION} bundled (${KUI_SIZE})${NC}"
else
    echo -e "${YELLOW}⚠ Kafka UI jar not found at $KAFKA_UI_JAR${NC}"
    echo -e "${YELLOW}  The installer will auto-download it during install.${NC}"
fi

# ─── Step 5: Create Standalone install.sh ───
echo -e "${BLUE}▶ Step 5/6: Creating installer...${NC}"
cat > "$BUILD_DIR/install.sh" << 'INSTALLER_EOF'
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
#   Tantor Kafka Manager — Installer v1.0.0
#
#   Usage:
#     sudo ./install.sh              # Install (auto-detects OS)
#     sudo ./install.sh --uninstall  # Remove Tantor
#
#   Supported OS:
#     Ubuntu 20.04+, Debian 11+, RHEL 8+, CentOS Stream 8+,
#     Rocky Linux 8+, AlmaLinux 8+, Oracle Linux 8+, Amazon Linux 2023
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

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

FORCE=false
UNINSTALL=false
INSTALL_DIR="$(cd "$(dirname "$0")" && pwd)"

# ─── Parse Arguments ───
while [[ $# -gt 0 ]]; do
    case $1 in
        --force|-f)   FORCE=true; shift ;;
        --uninstall)  UNINSTALL=true; shift ;;
        --help|-h)
            echo "Usage: sudo ./install.sh [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --force       Skip confirmation prompts"
            echo "  --uninstall   Remove Tantor installation"
            echo "  --help        Show this message"
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# ─── Root Check ───
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Error: Please run as root (sudo ./install.sh)${NC}"
    exit 1
fi

# ─── Detect OS ───
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        case "$ID" in
            ubuntu|debian|linuxmint|pop)
                OS_FAMILY="debian"
                OS_NAME="$PRETTY_NAME"
                ;;
            rhel|centos|rocky|almalinux|ol|fedora|amzn)
                OS_FAMILY="rhel"
                OS_NAME="$PRETTY_NAME"
                ;;
            *)
                # Try ID_LIKE
                case "$ID_LIKE" in
                    *debian*|*ubuntu*) OS_FAMILY="debian"; OS_NAME="$PRETTY_NAME" ;;
                    *rhel*|*fedora*|*centos*) OS_FAMILY="rhel"; OS_NAME="$PRETTY_NAME" ;;
                    *) echo -e "${RED}Unsupported OS: $PRETTY_NAME${NC}"; exit 1 ;;
                esac
                ;;
        esac
    else
        echo -e "${RED}Cannot detect OS (missing /etc/os-release)${NC}"
        exit 1
    fi
}

# ─── Uninstall ───
if [ "$UNINSTALL" = true ]; then
    echo -e "${YELLOW}▶ Uninstalling Tantor...${NC}"
    systemctl stop tantor-backend 2>/dev/null || true
    systemctl disable tantor-backend 2>/dev/null || true
    rm -f /etc/systemd/system/tantor-backend.service
    rm -f /etc/nginx/sites-enabled/tantor.conf
    rm -f /etc/nginx/conf.d/tantor.conf
    systemctl daemon-reload 2>/dev/null || true
    systemctl restart nginx 2>/dev/null || true
    rm -rf "$TANTOR_HOME"
    rm -rf "$TANTOR_LOG"
    rm -f /usr/local/bin/tantorctl
    echo -e "${GREEN}✓ Tantor removed${NC}"
    echo -e "${YELLOW}  Data preserved at: $TANTOR_DATA${NC}"
    echo "  To remove data: rm -rf $TANTOR_DATA"
    exit 0
fi

# ─── Banner ───
echo -e "${CYAN}"
echo "  ████████╗ █████╗ ███╗   ██╗████████╗ ██████╗ ██████╗ "
echo "  ╚══██╔══╝██╔══██╗████╗  ██║╚══██╔══╝██╔═══██╗██╔══██╗"
echo "     ██║   ███████║██╔██╗ ██║   ██║   ██║   ██║██████╔╝"
echo "     ██║   ██╔══██║██║╚██╗██║   ██║   ██║   ██║██╔══██╗"
echo "     ██║   ██║  ██║██║ ╚████║   ██║   ╚██████╔╝██║  ██║"
echo "     ╚═╝   ╚═╝  ╚═╝╚═╝  ╚═══╝   ╚═╝    ╚═════╝ ╚═╝  ╚═╝"
echo -e "${NC}"
echo -e "  ${BOLD}Kafka Cluster Manager — Installer v${VERSION}${NC}"
echo ""

detect_os
echo -e "  ${BLUE}OS Detected:${NC}  $OS_NAME"
echo -e "  ${BLUE}OS Family:${NC}    $OS_FAMILY"
echo -e "  ${BLUE}Install To:${NC}   $TANTOR_HOME"
echo ""

# ─── Verify Package Contents ───
if [ ! -d "$INSTALL_DIR/backend/app" ]; then
    echo -e "${RED}Error: backend/app not found. Are you running from the tantor directory?${NC}"
    exit 1
fi
if [ ! -d "$INSTALL_DIR/frontend/dist" ]; then
    echo -e "${RED}Error: frontend/dist not found. The frontend is not built.${NC}"
    exit 1
fi

# ─── Confirm ───
if [ "$FORCE" != true ]; then
    echo -e "${YELLOW}This will install Tantor on this machine.${NC}"
    read -p "  Continue? [y/N] " CONFIRM
    case "$CONFIRM" in [yY]|[yY][eE][sS]) ;; *) echo "Cancelled."; exit 0 ;; esac
fi

# ─── Install System Dependencies ───
echo -e "\n${BLUE}▶ Step 1/8: Installing system dependencies...${NC}"

install_deps_debian() {
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq \
        python3 python3-pip python3-venv python3-full \
        nginx \
        openssh-client sshpass \
        wget curl jq gnupg ca-certificates net-tools \
        > /dev/null 2>&1
    echo -e "${GREEN}✓ System packages installed${NC}"
}

install_deps_rhel() {
    dnf install -y -q epel-release 2>/dev/null || true

    # RHEL 8.x ships Python 3.6 — too old for FastAPI. Install 3.11 via AppStream.
    local py_ver
    py_ver=$(python3 -c 'import sys; print(sys.version_info.minor)' 2>/dev/null || echo "0")
    if [ "$py_ver" -lt 9 ]; then
        echo "  Default Python 3.${py_ver} too old, installing Python 3.11..."
        dnf module enable -y python311 2>/dev/null || true
        dnf install -y -q python3.11 python3.11-pip python3.11-devel 2>/dev/null
        if command -v python3.11 &>/dev/null; then
            alternatives --set python3 /usr/bin/python3.11 2>/dev/null || \
                alternatives --install /usr/bin/python3 python3 /usr/bin/python3.11 1 2>/dev/null || true
        else
            echo -e "${RED}ERROR: Failed to install Python 3.11${NC}"
            exit 1
        fi
    fi

    dnf install -y -q \
        nginx \
        openssh-clients sshpass \
        wget curl jq ca-certificates net-tools \
        > /dev/null 2>&1
    echo -e "${GREEN}✓ System packages installed${NC}"
}

if [ "$OS_FAMILY" = "debian" ]; then
    install_deps_debian
else
    install_deps_rhel
fi

# ─── Create User & Directories ───
echo -e "${BLUE}▶ Step 2/8: Creating user and directories...${NC}"

id "$TANTOR_USER" &>/dev/null || useradd -r -s /usr/sbin/nologin "$TANTOR_USER"

mkdir -p \
    "$TANTOR_HOME/backend" \
    "$TANTOR_HOME/frontend/dist" \
    "$TANTOR_HOME/bin" \
    "$TANTOR_DATA/db" \
    "$TANTOR_DATA/repo/kafka" \
    "$TANTOR_DATA/repo/ksqldb" \
    "$TANTOR_DATA/repo/connect-plugins" \
    "$TANTOR_DATA/repo/monitoring" \
    "$TANTOR_DATA/ansible_work" \
    "$TANTOR_DATA/ssh" \
    "$TANTOR_DATA/backups" \
    "$TANTOR_LOG/backend" \
    "$TANTOR_LOG/nginx"

# Grant tantor user passwordless sudo (needed for monitoring install via Prometheus/Grafana)
echo "${TANTOR_USER} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/tantor
chmod 440 /etc/sudoers.d/tantor

echo -e "${GREEN}✓ User '${TANTOR_USER}' and directories created${NC}"

# ─── Install Python Dependencies (in venv — PEP 668 safe) ───
echo -e "${BLUE}▶ Step 3/8: Installing Python dependencies...${NC}"

python3 -m venv "$TANTOR_HOME/venv"
"$TANTOR_HOME/venv/bin/pip" install --upgrade pip -q 2>/dev/null
"$TANTOR_HOME/venv/bin/pip" install -q -r "$INSTALL_DIR/backend/requirements.txt"

echo -e "${GREEN}✓ Python venv created and dependencies installed${NC}"

# ─── Copy Backend ───
echo -e "${BLUE}▶ Step 4/8: Installing backend...${NC}"

cp -r "$INSTALL_DIR/backend/app" "$TANTOR_HOME/backend/"
cp "$INSTALL_DIR/backend/requirements.txt" "$TANTOR_HOME/backend/"

# Create symlinks for persistent data
ln -sf "$TANTOR_DATA/db/tantor.db" "$TANTOR_HOME/backend/tantor.db"
ln -sf "$TANTOR_DATA/repo" "$TANTOR_HOME/backend/repo"
ln -sf "$TANTOR_DATA/ansible_work" "$TANTOR_HOME/backend/ansible_work"

# Create .env with CORS for all local addresses
SERVER_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "localhost")
cat > "$TANTOR_HOME/backend/.env" << ENVEOF
CORS_ORIGINS=["http://localhost","http://127.0.0.1","http://${SERVER_IP}"]
ENVEOF

echo -e "${GREEN}✓ Backend installed${NC}"

# ─── Copy Kafka Binary to Repo ───
echo -e "${BLUE}▶ Step 4b/8: Installing Kafka binary...${NC}"

KAFKA_BUNDLED="$INSTALL_DIR/repo/kafka/kafka_2.13-3.7.0.tgz"
KAFKA_DEST="$TANTOR_DATA/repo/kafka/kafka_2.13-3.7.0.tgz"

if [ -f "$KAFKA_BUNDLED" ]; then
    cp "$KAFKA_BUNDLED" "$KAFKA_DEST"
    echo -e "${GREEN}✓ Kafka 3.7.0 binary installed from bundle${NC}"
elif [ -f "$KAFKA_DEST" ]; then
    echo -e "${GREEN}✓ Kafka 3.7.0 binary already present${NC}"
else
    echo -e "${YELLOW}  Downloading Kafka 3.7.0 from Apache archive...${NC}"
    KAFKA_URL="https://archive.apache.org/dist/kafka/3.7.0/kafka_2.13-3.7.0.tgz"
    if curl -fSL --connect-timeout 15 --max-time 300 -o "$KAFKA_DEST" "$KAFKA_URL" 2>/dev/null; then
        echo -e "${GREEN}✓ Kafka 3.7.0 downloaded ($(du -sh "$KAFKA_DEST" | awk '{print $1}'))${NC}"
    else
        echo -e "${YELLOW}⚠ Could not download Kafka binary. Upload it via the UI after install.${NC}"
        rm -f "$KAFKA_DEST"
    fi
fi

# ─── Copy Frontend (Pre-Built) ───
echo -e "${BLUE}▶ Step 5/8: Installing frontend...${NC}"

cp -r "$INSTALL_DIR/frontend/dist/"* "$TANTOR_HOME/frontend/dist/"

echo -e "${GREEN}✓ Frontend installed (pre-built)${NC}"

# ─── Configure Nginx & Systemd ───
echo -e "${BLUE}▶ Step 6/8: Configuring services...${NC}"

# Nginx config
if [ "$OS_FAMILY" = "debian" ]; then
    cp "$INSTALL_DIR/config/nginx-tantor.conf" /etc/nginx/sites-enabled/tantor.conf
    rm -f /etc/nginx/sites-enabled/default
else
    cp "$INSTALL_DIR/config/nginx-tantor.conf" /etc/nginx/conf.d/tantor.conf
    rm -f /etc/nginx/conf.d/default.conf
    # RHEL nginx.conf has a default server block that conflicts — remove it
    if grep -q 'default_server' /etc/nginx/nginx.conf 2>/dev/null; then
        sed -i '/^    server {/,/^    }/d' /etc/nginx/nginx.conf
    fi
    # SELinux: allow nginx to proxy to backend
    if command -v setsebool &>/dev/null; then
        setsebool -P httpd_can_network_connect 1 2>/dev/null || true
    fi
fi

# Systemd service (using venv uvicorn)
cat > /etc/systemd/system/tantor-backend.service << 'SYSEOF'
[Unit]
Description=Tantor Kafka Manager — Backend API
After=network.target
Wants=nginx.service

[Service]
Type=simple
User=tantor
Group=tantor
WorkingDirectory=/opt/tantor/backend
Environment=DATABASE_URL=sqlite:////var/lib/tantor/db/tantor.db
Environment=PYTHONUNBUFFERED=1
ExecStart=/opt/tantor/venv/bin/uvicorn app.main:app --host 127.0.0.1 --port 8000 --workers 2
ExecReload=/bin/kill -HUP $MAINPID
Restart=always
RestartSec=5
StandardOutput=append:/var/log/tantor/backend/stdout.log
StandardError=append:/var/log/tantor/backend/stderr.log
NoNewPrivileges=false
ProtectSystem=false

[Install]
WantedBy=multi-user.target
SYSEOF

systemctl daemon-reload
systemctl enable tantor-backend nginx >/dev/null 2>&1

# Install tantorctl CLI
cp "$INSTALL_DIR/bin/tantorctl" "$TANTOR_HOME/bin/tantorctl"
chmod +x "$TANTOR_HOME/bin/tantorctl"
ln -sf "$TANTOR_HOME/bin/tantorctl" /usr/local/bin/tantorctl

# Symlink venv binaries so ansible-playbook is accessible
ln -sf "$TANTOR_HOME/venv/bin/ansible-playbook" /usr/local/bin/ansible-playbook 2>/dev/null || true
ln -sf "$TANTOR_HOME/venv/bin/ansible" /usr/local/bin/ansible 2>/dev/null || true

echo -e "${GREEN}✓ Nginx, systemd, and tantorctl configured${NC}"

# ─── Set Ownership & Start ───
echo -e "${BLUE}▶ Step 7/8: Setting up SSH for deployment...${NC}"

# Create tantor user home with SSH and Ansible support
mkdir -p /home/${TANTOR_USER}/.ssh /home/${TANTOR_USER}/.ansible/tmp
if [ ! -f /home/${TANTOR_USER}/.ssh/id_rsa ]; then
    ssh-keygen -t rsa -b 4096 -f /home/${TANTOR_USER}/.ssh/id_rsa -N "" -q
fi
chown -R "${TANTOR_USER}:${TANTOR_USER}" /home/${TANTOR_USER}
chmod 700 /home/${TANTOR_USER}/.ssh
chmod 600 /home/${TANTOR_USER}/.ssh/id_rsa 2>/dev/null || true
usermod -d /home/${TANTOR_USER} -s /bin/bash ${TANTOR_USER} 2>/dev/null || true

echo -e "${GREEN}✓ SSH keys generated for deployment${NC}"

echo -e "${BLUE}▶ Step 8/8: Starting services...${NC}"

chown -R "$TANTOR_USER:$TANTOR_USER" "$TANTOR_HOME" "$TANTOR_DATA" "$TANTOR_LOG"
# Nginx needs read access to frontend
chmod -R o+r "$TANTOR_HOME/frontend/dist"

systemctl start nginx
systemctl start tantor-backend

# Wait for health
echo -n "  Waiting for Tantor to start"
for i in $(seq 1 30); do
    HTTP=$(curl -sf -o /dev/null -w "%{http_code}" http://localhost/api/health 2>/dev/null || echo "000")
    if [ "$HTTP" = "200" ]; then
        echo ""
        break
    fi
    echo -n "."
    sleep 2
done

if [ "$HTTP" = "200" ]; then
    echo -e "${GREEN}✓ Tantor is running!${NC}"
else
    echo ""
    echo -e "${YELLOW}⚠ Tantor is still starting. Check: tantorctl logs error${NC}"
fi

# ─── Done ───
echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║           Installation Complete!                    ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${GREEN}Open in browser:${NC}  http://${SERVER_IP}"
echo -e "  ${GREEN}Login:${NC}            admin / admin"
echo ""
echo -e "  ${BLUE}Commands:${NC}"
echo "    tantorctl status         — Check service status"
echo "    tantorctl logs           — View logs"
echo "    tantorctl restart        — Restart services"
echo "    tantorctl backup         — Backup database"
echo "    tantorctl reset-password — Reset admin password"
echo ""
echo -e "  ${BLUE}Next steps:${NC}"
echo "    1. Open the UI and change the default password"
echo "    2. Add your Linux servers as hosts (Hosts → Add Host)"
echo "    3. Create a Kafka cluster (Clusters → Create)"
echo "    4. Deploy and manage from the UI"
echo ""
INSTALLER_EOF

chmod +x "$BUILD_DIR/install.sh"
echo -e "${GREEN}✓ Standalone installer created${NC}"

# ─── Create the tarball ───
echo -e "\n${BLUE}▶ Creating release tarball...${NC}"
# Remove macOS resource forks and __pycache__
find "$BUILD_DIR" -name '._*' -delete 2>/dev/null || true
find "$BUILD_DIR" -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null || true
find "$BUILD_DIR" -name '*.pyc' -delete 2>/dev/null || true

cd /tmp
# Use COPYFILE_DISABLE to prevent macOS from adding ._ files
COPYFILE_DISABLE=1 tar czf "$OUTPUT" "$RELEASE_NAME"
rm -rf "$BUILD_DIR"

# ─── Summary ───
SIZE=$(du -sh "$OUTPUT" | awk '{print $1}')

echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║              Release Built Successfully             ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${GREEN}File:${NC} ${RELEASE_NAME}-linux.tar.gz"
echo -e "  ${GREEN}Size:${NC} ${SIZE}"
echo -e "  ${GREEN}Path:${NC} ${OUTPUT}"
echo ""
echo -e "  ${BLUE}How your users install it:${NC}"
echo ""
echo "    # Download (from GitHub Releases)"
echo "    curl -LO https://github.com/jimmy-fb/tantor/releases/download/v${VERSION}/${RELEASE_NAME}-linux.tar.gz"
echo ""
echo "    # Extract"
echo "    tar xzf ${RELEASE_NAME}-linux.tar.gz"
echo ""
echo "    # Install"
echo "    cd ${RELEASE_NAME}"
echo "    sudo ./install.sh"
echo ""
echo -e "  ${BLUE}That's it. No git, no Node.js, no build tools needed.${NC}"
echo ""

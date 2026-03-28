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
#   Tantor Kafka Manager — One-Click Installer v1.0.0
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
KAFKA_VERSION="3.7.0"
KAFKA_SCALA="2.13"
KAFKA_TGZ="kafka_${KAFKA_SCALA}-${KAFKA_VERSION}.tgz"

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
echo -e "  ${BOLD}Kafka Cluster Manager — One-Click Installer v${VERSION}${NC}"
echo ""

detect_os
echo -e "  ${BLUE}OS Detected:${NC}  $OS_NAME"
echo -e "  ${BLUE}OS Family:${NC}    $OS_FAMILY"
echo -e "  ${BLUE}Install To:${NC}   $TANTOR_HOME"
echo ""

# ─── Verify source ───
if [ ! -d "$INSTALL_DIR/backend/app" ]; then
    echo -e "${RED}Error: backend/app not found. Run from the tantor repo root.${NC}"
    exit 1
fi

# ─── Confirm ───
if [ "$FORCE" != true ]; then
    echo -e "${YELLOW}This will install Tantor on this machine.${NC}"
    read -p "  Continue? [y/N] " CONFIRM
    case "$CONFIRM" in [yY]|[yY][eE][sS]) ;; *) echo "Cancelled."; exit 0 ;; esac
fi

# ─── Step 1: System Dependencies ───
echo -e "\n${BLUE}▶ Step 1/9: Installing system dependencies...${NC}"

install_deps_debian() {
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq \
        python3 python3-pip python3-venv python3-full \
        openjdk-21-jre-headless \
        nginx \
        openssh-client sshpass \
        wget curl jq gnupg ca-certificates net-tools \
        > /dev/null 2>&1

    # Install Node.js 20 for building frontend
    if ! command -v node &>/dev/null || [ "$(node -v | cut -d. -f1 | tr -d v)" -lt 18 ]; then
        curl -fsSL https://deb.nodesource.com/setup_20.x | bash - >/dev/null 2>&1
        apt-get install -y -qq nodejs > /dev/null 2>&1
    fi
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
        java-21-openjdk-headless \
        nginx \
        openssh-clients sshpass \
        wget curl jq ca-certificates net-tools \
        > /dev/null 2>&1

    # Install Node.js 20 for building frontend
    if ! command -v node &>/dev/null || [ "$(node -v | cut -d. -f1 | tr -d v)" -lt 18 ]; then
        curl -fsSL https://rpm.nodesource.com/setup_20.x | bash - >/dev/null 2>&1
        dnf install -y -q nodejs > /dev/null 2>&1
    fi
    echo -e "${GREEN}✓ System packages installed${NC}"
}

if [ "$OS_FAMILY" = "debian" ]; then
    install_deps_debian
else
    install_deps_rhel
fi

# ─── Step 2: Create User & Directories ───
echo -e "${BLUE}▶ Step 2/9: Creating user and directories...${NC}"

id "$TANTOR_USER" &>/dev/null || useradd -r -m -s /bin/bash "$TANTOR_USER"

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

# Grant tantor user passwordless sudo
echo "${TANTOR_USER} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/tantor
chmod 440 /etc/sudoers.d/tantor

echo -e "${GREEN}✓ User '${TANTOR_USER}' and directories created${NC}"

# ─── Step 3: Build Frontend ───
echo -e "${BLUE}▶ Step 3/9: Building frontend...${NC}"

# Check if pre-built dist exists (tarball install)
if [ -d "$INSTALL_DIR/frontend/dist" ] && [ -f "$INSTALL_DIR/frontend/dist/index.html" ]; then
    echo -e "${GREEN}✓ Frontend already built (pre-built dist found)${NC}"
else
    # Build from source (GitHub clone install)
    cd "$INSTALL_DIR/frontend"
    npm ci --prefer-offline 2>/dev/null || npm install 2>/dev/null
    npm run build 2>/dev/null
    cd "$INSTALL_DIR"
    echo -e "${GREEN}✓ Frontend built from source${NC}"
fi

# ─── Step 4: Python Dependencies ───
echo -e "${BLUE}▶ Step 4/9: Installing Python dependencies...${NC}"

python3 -m venv "$TANTOR_HOME/venv"
"$TANTOR_HOME/venv/bin/pip" install --upgrade pip -q 2>/dev/null
"$TANTOR_HOME/venv/bin/pip" install -q -r "$INSTALL_DIR/backend/requirements.txt"

echo -e "${GREEN}✓ Python venv created and dependencies installed${NC}"

# ─── Step 5: Install Backend ───
echo -e "${BLUE}▶ Step 5/9: Installing backend...${NC}"

cp -r "$INSTALL_DIR/backend/app" "$TANTOR_HOME/backend/"
cp "$INSTALL_DIR/backend/requirements.txt" "$TANTOR_HOME/backend/"

# Symlinks for persistent data
ln -sf "$TANTOR_DATA/db/tantor.db" "$TANTOR_HOME/backend/tantor.db"
ln -sf "$TANTOR_DATA/repo" "$TANTOR_HOME/backend/repo"
ln -sf "$TANTOR_DATA/ansible_work" "$TANTOR_HOME/backend/ansible_work"

# Create .env with CORS
SERVER_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "localhost")
cat > "$TANTOR_HOME/backend/.env" << ENVEOF
CORS_ORIGINS=["http://localhost","http://127.0.0.1","http://${SERVER_IP}"]
ENVEOF

echo -e "${GREEN}✓ Backend installed${NC}"

# ─── Step 6: Install Frontend ───
echo -e "${BLUE}▶ Step 6/9: Installing frontend...${NC}"

cp -r "$INSTALL_DIR/frontend/dist/"* "$TANTOR_HOME/frontend/dist/"

echo -e "${GREEN}✓ Frontend installed${NC}"

# ─── Step 7: Download Kafka Binary ───
echo -e "${BLUE}▶ Step 7/9: Installing Kafka binary...${NC}"

KAFKA_DEST="$TANTOR_DATA/repo/kafka/$KAFKA_TGZ"

# Check bundled (tarball install), local repo, or download
if [ -f "$INSTALL_DIR/repo/kafka/$KAFKA_TGZ" ]; then
    cp "$INSTALL_DIR/repo/kafka/$KAFKA_TGZ" "$KAFKA_DEST"
    echo -e "${GREEN}✓ Kafka ${KAFKA_VERSION} installed from bundle${NC}"
elif [ -f "$INSTALL_DIR/backend/repo/kafka/$KAFKA_TGZ" ]; then
    cp "$INSTALL_DIR/backend/repo/kafka/$KAFKA_TGZ" "$KAFKA_DEST"
    echo -e "${GREEN}✓ Kafka ${KAFKA_VERSION} installed from local repo${NC}"
elif [ -f "$KAFKA_DEST" ]; then
    echo -e "${GREEN}✓ Kafka ${KAFKA_VERSION} already present${NC}"
else
    echo -e "${YELLOW}  Downloading Kafka ${KAFKA_VERSION} (~113 MB)...${NC}"
    KAFKA_URL="https://archive.apache.org/dist/kafka/${KAFKA_VERSION}/${KAFKA_TGZ}"
    if curl -fSL --connect-timeout 15 --max-time 600 --progress-bar -o "$KAFKA_DEST" "$KAFKA_URL"; then
        echo -e "${GREEN}✓ Kafka ${KAFKA_VERSION} downloaded ($(du -sh "$KAFKA_DEST" | awk '{print $1}'))${NC}"
    else
        echo -e "${YELLOW}⚠ Download failed. Upload Kafka binary via UI after install.${NC}"
        rm -f "$KAFKA_DEST"
    fi
fi

# ─── Step 8: Configure Services ───
echo -e "${BLUE}▶ Step 8/9: Configuring services...${NC}"

# Nginx config
NGINX_CONF='server {
    listen 80 default_server;
    server_name _;

    root /opt/tantor/frontend/dist;
    index index.html;

    client_max_body_size 500M;

    gzip on;
    gzip_types text/plain text/css application/json application/javascript text/xml application/xml text/javascript image/svg+xml;
    gzip_min_length 256;

    location /api/ {
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 86400;
    }

    location /grafana/ {
        proxy_pass http://127.0.0.1:3000/;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    location /kafka-ui/ {
        proxy_pass http://127.0.0.1:8989/kafka-ui/;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 86400;
    }

    location / {
        try_files $uri $uri/ /index.html;
    }

    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot)$ {
        expires 1y;
        add_header Cache-Control "public, immutable";
    }
}'

if [ "$OS_FAMILY" = "debian" ]; then
    echo "$NGINX_CONF" > /etc/nginx/sites-enabled/tantor.conf
    rm -f /etc/nginx/sites-enabled/default
else
    echo "$NGINX_CONF" > /etc/nginx/conf.d/tantor.conf
    rm -f /etc/nginx/conf.d/default.conf
    # Remove default server block in RHEL nginx.conf
    if grep -q 'default_server' /etc/nginx/nginx.conf 2>/dev/null; then
        sed -i '/^    server {/,/^    }/d' /etc/nginx/nginx.conf
    fi
    # SELinux
    if command -v setsebool &>/dev/null; then
        setsebool -P httpd_can_network_connect 1 2>/dev/null || true
    fi
fi

# Systemd service
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

# Symlink ansible binaries
ln -sf "$TANTOR_HOME/venv/bin/ansible-playbook" /usr/local/bin/ansible-playbook 2>/dev/null || true
ln -sf "$TANTOR_HOME/venv/bin/ansible" /usr/local/bin/ansible 2>/dev/null || true

# Setup SSH for tantor user (for deploying Kafka to remote hosts)
mkdir -p /home/${TANTOR_USER}/.ssh /home/${TANTOR_USER}/.ansible/tmp
if [ ! -f /home/${TANTOR_USER}/.ssh/id_rsa ]; then
    ssh-keygen -t rsa -b 4096 -f /home/${TANTOR_USER}/.ssh/id_rsa -N "" -q
fi
chown -R "${TANTOR_USER}:${TANTOR_USER}" /home/${TANTOR_USER}
chmod 700 /home/${TANTOR_USER}/.ssh
chmod 600 /home/${TANTOR_USER}/.ssh/id_rsa 2>/dev/null || true

# Setup Kafka UI (kafbat/kafka-ui) as a local service
KAFKA_UI_DIR="$TANTOR_HOME/kafka-ui"
KAFKA_UI_JAR="$KAFKA_UI_DIR/kafka-ui.jar"
KAFKA_UI_VERSION="1.4.2"
KAFKA_UI_URL="https://github.com/kafbat/kafka-ui/releases/download/v${KAFKA_UI_VERSION}/api-v${KAFKA_UI_VERSION}.jar"

mkdir -p "$KAFKA_UI_DIR" "$TANTOR_LOG/kafka-ui"

if [ -f "$KAFKA_UI_JAR" ]; then
    echo -e "${GREEN}✓ Kafka UI jar already present${NC}"
else
    echo -e "${YELLOW}  Downloading Kafka UI v${KAFKA_UI_VERSION} (~137 MB)...${NC}"
    if curl -fSL --connect-timeout 15 --max-time 600 --progress-bar -o "$KAFKA_UI_JAR" "$KAFKA_UI_URL"; then
        echo -e "${GREEN}✓ Kafka UI downloaded${NC}"
    else
        echo -e "${YELLOW}⚠ Kafka UI download failed. It can be added later.${NC}"
        rm -f "$KAFKA_UI_JAR"
    fi
fi

# Default kafka-ui config (no clusters configured yet — will be synced on first deploy)
cat > "$KAFKA_UI_DIR/config.yml" << 'KUIEOF'
kafka:
  clusters: []
dynamic:
  config:
    enabled: true
server:
  port: 8989
  servlet:
    context-path: /kafka-ui
auth:
  type: DISABLED
logging:
  level:
    root: WARN
    io.kafbat.ui: INFO
KUIEOF

# Kafka UI systemd service
if [ -f "$KAFKA_UI_JAR" ]; then
    # Find java
    JAVA_BIN=$(which java 2>/dev/null || echo "/usr/bin/java")
    cat > /etc/systemd/system/tantor-kafka-ui.service << KUISEOF
[Unit]
Description=Tantor Kafka UI (kafbat-ui)
After=network.target tantor-backend.service
Wants=tantor-backend.service

[Service]
Type=simple
User=tantor
Group=tantor
WorkingDirectory=$KAFKA_UI_DIR
ExecStart=$JAVA_BIN --add-opens java.rmi/javax.rmi.ssl=ALL-UNNAMED -jar $KAFKA_UI_JAR --spring.config.additional-location=$KAFKA_UI_DIR/config.yml
Restart=on-failure
RestartSec=10
StandardOutput=append:$TANTOR_LOG/kafka-ui/stdout.log
StandardError=append:$TANTOR_LOG/kafka-ui/stderr.log
LimitNOFILE=65536
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
KUISEOF
    systemctl daemon-reload
    systemctl enable tantor-kafka-ui >/dev/null 2>&1
fi

echo -e "${GREEN}✓ Nginx, systemd, SSH, and Kafka UI configured${NC}"

# ─── Step 9: Start Services ───
echo -e "${BLUE}▶ Step 9/9: Starting services...${NC}"

chown -R "$TANTOR_USER:$TANTOR_USER" "$TANTOR_HOME" "$TANTOR_DATA" "$TANTOR_LOG"
chmod -R o+r "$TANTOR_HOME/frontend/dist"

systemctl restart nginx
systemctl restart tantor-backend
if [ -f "$KAFKA_UI_JAR" ]; then
    systemctl restart tantor-kafka-ui 2>/dev/null || true
fi

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
    echo -e "${YELLOW}⚠ Tantor is still starting. Check: journalctl -u tantor-backend${NC}"
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
echo -e "  ${BLUE}Quick start:${NC}"
echo "    1. Open the UI and change the default password"
echo "    2. Add your Linux servers as hosts (Hosts → Add Host)"
echo "    3. Create a Kafka cluster (Clusters → Create)"
echo "    4. Deploy and manage from the UI"
echo ""
echo -e "  ${BLUE}Service commands:${NC}"
echo "    systemctl status tantor-backend    — Check backend"
echo "    systemctl status nginx             — Check nginx"
echo "    journalctl -u tantor-backend -f    — View logs"
echo ""

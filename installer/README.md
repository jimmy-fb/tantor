# Tantor — Kafka Cluster Manager

**Like Cloudera Manager, but for Apache Kafka.**

Tantor is an all-in-one web platform for deploying, managing, monitoring, and security-scanning Apache Kafka clusters. One installer gives you a full management UI backed by automated SSH + Ansible deployments — no manual configuration required.

---

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    Tantor Server                        │
│                                                         │
│  ┌──────────┐   ┌──────────────┐   ┌────────────────┐  │
│  │  Nginx   │──▶│ FastAPI      │──▶│  SQLite DB     │  │
│  │  :80     │   │ Backend :8000│   │  (clusters,    │  │
│  │          │   │              │   │   hosts, users) │  │
│  │  Serves  │   │  SSH/Ansible │   └────────────────┘  │
│  │  React   │   │  Engine      │                        │
│  │  Frontend│   └──────┬───────┘                        │
│  └──────────┘          │                                │
│                        │ SSH                            │
└────────────────────────┼────────────────────────────────┘
                         │
         ┌───────────────┼───────────────┐
         ▼               ▼               ▼
   ┌──────────┐   ┌──────────┐   ┌──────────┐
   │  Kafka   │   │  Kafka   │   │  Kafka   │
   │ Broker 1 │   │ Broker 2 │   │ Broker 3 │
   │  :9092   │   │  :9092   │   │  :9092   │
   └──────────┘   └──────────┘   └──────────┘
```

---

## Quick Start

### Docker Install (Recommended)

```bash
git clone https://github.com/jimmy-fb/tantor.git
cd tantor

# Ubuntu-based image
sudo ./installer/install.sh --docker

# OR RHEL/Rocky Linux-based image
sudo ./installer/install.sh --docker --rhel
```

### Native Install (Ubuntu / RHEL)

```bash
git clone https://github.com/jimmy-fb/tantor.git
cd tantor

sudo ./installer/install.sh
```

### After Installation

1. Open **http://your-server-ip** in a browser
2. Login with **admin / admin**
3. Add your Kafka hosts (SSH credentials)
4. Create a cluster and deploy

---

## Docker Images

Two all-in-one Docker images are provided:

| Image | Base OS | Tag | Size |
|-------|---------|-----|------|
| **Ubuntu** | Ubuntu 22.04 LTS | `tantor:1.0.0-ubuntu` | ~650MB |
| **RHEL** | Rocky Linux 9 (RHEL 9 compatible) | `tantor:1.0.0-rhel` | ~750MB |

Both images contain:
- **Nginx** — Reverse proxy serving the React frontend on port 80
- **FastAPI** — Python backend API on port 8000 (internal)
- **Supervisor** — Process manager for Nginx + Backend
- **SSH/Ansible** — For remote Kafka cluster deployment
- **tantorctl** — CLI management tool

### Build Images Manually

```bash
# From the repo root
docker build -t tantor:1.0.0-ubuntu -f installer/docker/Dockerfile.ubuntu .
docker build -t tantor:1.0.0-rhel   -f installer/docker/Dockerfile.rhel .
```

### Run Directly with Docker

```bash
docker run -d \
  --name tantor \
  -p 80:80 \
  -v tantor-data:/var/lib/tantor \
  --restart unless-stopped \
  tantor:1.0.0-ubuntu
```

---

## Tools & Technologies

### Backend
| Component | Technology |
|-----------|-----------|
| **API Framework** | [FastAPI](https://fastapi.tiangolo.com/) (Python 3.12) |
| **Database** | SQLite via [SQLAlchemy](https://www.sqlalchemy.org/) ORM |
| **SSH Client** | [Paramiko](https://www.paramiko.org/) |
| **Deployment** | [Ansible](https://www.ansible.com/) (automated playbook generation) |
| **Auth** | JWT tokens ([PyJWT](https://pyjwt.readthedocs.io/)) + bcrypt password hashing |
| **Encryption** | [Fernet](https://cryptography.io/) symmetric encryption for SSH credentials |

### Frontend
| Component | Technology |
|-----------|-----------|
| **UI Framework** | [React 19](https://react.dev/) + TypeScript |
| **Build Tool** | [Vite 7](https://vitejs.dev/) |
| **Styling** | [Tailwind CSS 4](https://tailwindcss.com/) |
| **HTTP Client** | [Axios](https://axios-http.com/) |
| **Icons** | [Lucide React](https://lucide.dev/) |
| **Routing** | [React Router 7](https://reactrouter.com/) |

### Infrastructure
| Component | Technology |
|-----------|-----------|
| **Web Server** | [Nginx](https://nginx.org/) (reverse proxy + static files) |
| **Process Manager** | [Supervisor](http://supervisord.org/) (Docker) / systemd (native) |
| **Containers** | Docker (Ubuntu 22.04 / Rocky Linux 9) |

---

## Features

### Cluster Lifecycle Management
- **Deploy** — Automated KRaft-mode Kafka cluster deployment via SSH + Ansible
- **Configure** — Broker configuration management with full audit trail and rollback
- **Rolling Restart** — Zero-downtime broker restarts with health checks
- **Upgrade** — Cluster version upgrades
- **MirrorMaker 2** — Cross-cluster replication (cluster linking)

### Kafka Operations
- **Topics** — Create, delete, view partitions and replication
- **Consumer Groups** — List groups, monitor lag
- **Produce/Consume** — Send and read messages with full metadata
- **ACLs** — Access control list management
- **SASL Users** — SCRAM-SHA user management

### Advanced Services
- **ksqlDB** — SQL query console for streaming data
- **Kafka Connect** — Connector deployment and lifecycle management
- **Schema Registry** — Integration support

### Monitoring
- **Prometheus** — Auto-deployed with JMX and node exporters
- **Grafana** — Pre-configured dashboards for Kafka metrics
- Both installed automatically to the Tantor server

### Security Scanning (VAPT)
- **Kafka VAPT** — 40+ Kafka-specific security checks (TLS, auth, config, data)
- **OpenVAS** — 80,000+ NVT infrastructure vulnerability scanner
- **Qualys CE** — Cloud-based vulnerability assessment
- **OWASP ZAP** — Web application security scanner

### Authentication & Authorization
- JWT-based authentication (access + refresh tokens)
- Role-based access control: **Admin** (full) / **Monitor** (read-only)
- Encrypted SSH credential storage (Fernet cipher)
- Full audit logging

---

## Management CLI — `tantorctl`

After installation, use `tantorctl` to manage Tantor:

```bash
tantorctl status           # Show service status and health
tantorctl start            # Start all services
tantorctl stop             # Stop all services
tantorctl restart          # Restart all services
tantorctl logs             # Tail all logs
tantorctl logs backend     # Tail backend logs only
tantorctl logs error       # Tail error logs
tantorctl health           # Quick API health check
tantorctl version          # Show version and paths
tantorctl backup           # Backup the database
tantorctl restore <file>   # Restore from backup
tantorctl reset-password   # Reset admin password to 'admin'
tantorctl shell            # Open shell in container (Docker mode)
```

---

## Installation Options

### Option 1: Docker (Recommended)

```bash
# Ubuntu base (default)
sudo ./installer/install.sh --docker

# RHEL/Rocky Linux base
sudo ./installer/install.sh --docker --rhel

# Force reinstall (removes existing container)
sudo ./installer/install.sh --docker --force
```

**Requirements:** Docker installed and running.

### Option 2: Native (Bare Metal)

```bash
sudo ./installer/install.sh
```

**Supported OS:**
- Ubuntu 20.04+ / Debian 11+
- RHEL 8+ / Rocky Linux 8+ / AlmaLinux 8+ / CentOS Stream 8+

**Auto-installs:** Python 3, Nginx, Node.js 22, pip packages, systemd services.

### Uninstall

```bash
sudo ./installer/install.sh --uninstall
```

---

## Directory Layout

```
/opt/tantor/                 # Application home
  backend/                   # FastAPI backend
    app/                     # Python source code
  frontend/
    dist/                    # Pre-built React app
  bin/
    tantorctl                # Management CLI

/var/lib/tantor/             # Persistent data
  db/tantor.db               # SQLite database
  repo/                      # Kafka package cache (airgapped)
  ansible_work/              # Generated playbooks and logs
  ssh/                       # SSH key storage
  backups/                   # Database backups

/var/log/tantor/             # Logs
  backend/stdout.log         # Backend application logs
  backend/stderr.log         # Backend error logs
  nginx/access.log           # HTTP access logs
  nginx/error.log            # Nginx error logs
```

---

## Ports

| Port | Service | Access |
|------|---------|--------|
| **80** | Nginx (Frontend + API proxy) | External — browser access |
| 8000 | FastAPI Backend | Internal only (proxied via Nginx) |
| 9090 | Prometheus (optional) | Deployed to Tantor server |
| 3000 | Grafana (optional) | Proxied at `/grafana/` |

---

## Default Credentials

| Service | Username | Password |
|---------|----------|----------|
| **Tantor UI** | admin | admin |
| **Grafana** (if installed) | admin | admin |

Change the admin password after first login.

---

## License

MIT

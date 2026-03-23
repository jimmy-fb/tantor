# Tantor — Kafka Cluster Manager

Deploy, manage, and secure Apache Kafka clusters from a single web UI. Think of it as **Cloudera Manager for Kafka** — install Tantor on one server, point it at your Linux machines, and deploy production Kafka clusters in minutes.

```
┌─────────────────────────────────────────────────────────────┐
│                      Your Browser                           │
│              http://<tantor-server-ip>                       │
└────────────────────────┬────────────────────────────────────┘
                         │
┌────────────────────────▼────────────────────────────────────┐
│                  Tantor Server                              │
│          (installed on any Linux machine)                   │
│                                                             │
│   ┌──────────┐  ┌──────────┐  ┌──────────────────────┐     │
│   │ Web UI   │  │ REST API │  │ Deployment Engine    │     │
│   │ React    │  │ FastAPI  │  │ Ansible + SSH        │     │
│   └──────────┘  └──────────┘  └──────┬───────────────┘     │
└──────────────────────────────────────┼──────────────────────┘
                                       │ SSH
                    ┌──────────────────┼──────────────────┐
                    │                  │                   │
             ┌──────▼──────┐   ┌──────▼──────┐   ┌───────▼─────┐
             │  Kafka Node  │   │  Kafka Node  │   │  Kafka Node  │
             │  Broker +    │   │  Broker +    │   │  Broker +    │
             │  Controller  │   │  Controller  │   │  Controller  │
             └─────────────┘   └─────────────┘   └──────────────┘
```

---

## Quick Start — One-Click Install

```bash
git clone https://github.com/jimmy-fb/tantor.git
cd tantor
sudo ./install.sh
```

That's it. Open `http://<your-server-ip>` and log in with `admin` / `admin`.

The installer automatically:
- Detects your OS (Ubuntu/Debian or RHEL/CentOS/Rocky)
- Installs all dependencies (Python 3.11+, Node.js 20, Nginx, Ansible)
- Builds the frontend from source
- Downloads Kafka 3.7.0 binary (~113 MB) from Apache
- Configures Nginx reverse proxy on port 80
- Generates SSH keys for remote Kafka deployment
- Sets up systemd services for automatic startup

> **Tested and verified on:** RHEL 8.6, Ubuntu 24.04

---

## Supported Operating Systems

Tantor installs natively on any of these Linux distributions (no Docker required):

| OS | Versions | Tested |
|----|----------|--------|
| **Ubuntu** | 20.04, 22.04, 24.04 | Ubuntu 24.04 verified |
| **RHEL** | 8, 9 | RHEL 8.6 verified |
| **Rocky Linux** | 8, 9 | Compatible (RHEL-based) |
| **CentOS** | Stream 8, Stream 9 | Compatible (RHEL-based) |
| **Oracle Linux** | 8, 9 | Compatible (RHEL-based) |
| **AlmaLinux** | 8, 9 | Compatible (RHEL-based) |
| **Amazon Linux** | 2023 | Compatible (RHEL-based) |
| **Debian** | 11, 12 | Compatible (Debian-based) |

---

## Prerequisites

### Tantor Server (the machine where you install Tantor)

| Requirement | Minimum |
|-------------|---------|
| **OS** | Any supported Linux (see above) |
| **RAM** | 4 GB |
| **Disk** | 20 GB free |
| **CPU** | 2 cores |
| **Network** | SSH access to all Kafka target nodes |
| **Ports** | 80 (web UI) |
| **User** | Root or sudo access (for installation) |

> The installer handles everything else — Python, Node.js, Nginx, Ansible, Kafka binaries, SSH keys.

### Kafka Target Nodes (the machines where Kafka will be deployed)

| Requirement | Minimum |
|-------------|---------|
| **OS** | Any supported Linux (see above) |
| **RAM** | 4 GB (8 GB recommended for production) |
| **Disk** | 50 GB+ (depends on data retention) |
| **CPU** | 2 cores (4 recommended) |
| **Java** | Java 17+ (Tantor installs this automatically during deployment) |
| **Network** | SSH accessible from Tantor server |
| **Ports** | 22 (SSH), 9092 (Kafka), 9093 (KRaft controller) |
| **User** | SSH user with sudo privileges |

---

## Installation

### Option A: Install from GitHub (Recommended)

```bash
git clone https://github.com/jimmy-fb/tantor.git
cd tantor
sudo ./install.sh
```

### Option B: Install from Release Tarball (Air-Gapped)

```bash
# Download the release (includes pre-built frontend + Kafka binary)
curl -LO https://github.com/jimmy-fb/tantor/releases/download/v1.0.0/tantor-1.0.0-linux.tar.gz
tar xzf tantor-1.0.0-linux.tar.gz
cd tantor-1.0.0
sudo ./install.sh
```

The tarball is self-contained — no internet access needed during install.

### Verify Installation

```bash
curl http://localhost/api/health
# {"status":"ok","version":"1.0.0"}
```

Open `http://<your-server-ip>` in a browser. Default login: **admin / admin**

---

## How to Deploy a Kafka Cluster

### 1. Add Your Servers

Go to **Hosts** in the sidebar and click **Add Host**.

For each server that will run Kafka:
- **Hostname** — Friendly name (e.g., `kafka-1`)
- **IP Address** — Private IP of the server
- **SSH Port** — Usually `22`
- **Username** — SSH user (e.g., `ubuntu`, `ec2-user`)
- **Authentication** — Paste the SSH private key from `/home/tantor/.ssh/id_rsa` on the Tantor server, or use a password

> **SSH Key Setup:** The installer generates an SSH key at `/home/tantor/.ssh/id_rsa`. Copy the public key to each Kafka node:
> ```bash
> # On the Tantor server:
> sudo cat /home/tantor/.ssh/id_rsa.pub
> # Add this to ~/.ssh/authorized_keys on each Kafka node
> ```

Click **Test Connection** to verify SSH access.

### 2. Create a Cluster

Go to **New Cluster** and follow the wizard:

- **Cluster Name** — e.g., `production-cluster`
- **Kafka Version** — 3.7.0 (pre-downloaded during install)
- **Mode** — KRaft (recommended) or ZooKeeper

### 3. Assign Roles

For each host, assign a role:

| Role | Description |
|------|-------------|
| **Broker + Controller** | Combined mode (recommended for 1-3 node clusters) |
| **Broker** | Data node only (for larger clusters) |
| **Controller** | KRaft controller only (for larger clusters) |
| **ksqlDB** | Stream processing engine |
| **Kafka Connect** | Data integration connectors |

### 4. Deploy

Click **Deploy**. Tantor will:

1. Validate SSH connections to all nodes
2. Install Java and prerequisites on each node
3. Upload Kafka binaries (~113 MB per node)
4. Generate per-node configurations
5. Format KRaft storage
6. Start Kafka as a systemd service
7. Verify cluster health

Watch the deployment in real-time via the live log stream.

---

## Features

### Cluster Management

| Feature | Description |
|---------|-------------|
| **Topics** | Create, delete, configure topics. Modify retention period and partition count inline. |
| **Consumer Groups** | View consumer lag, offsets, members, and IP information. |
| **Produce / Consume** | Send and read messages directly from the UI. |
| **Broker Config** | Edit all broker-level Kafka settings by category (Core, Log, Network, Performance, Replication). |
| **Rolling Restart** | Zero-downtime broker/controller restarts with pre-restart health checks. |
| **Cluster Upgrades** | Upload newer Kafka binaries and orchestrate rolling upgrades. |
| **Partition Rebalance** | Visualize broker partition distribution, generate and execute reassignment plans. |
| **Service Logs** | Real-time log streaming from each Kafka node — no SSH needed. |
| **Validation** | End-to-end cluster health check: connectivity, topic creation, produce/consume round-trip. |

### Security

| Feature | Description |
|---------|-------------|
| **SASL/SCRAM Users** | Create and manage SCRAM-SHA-256 authentication users. |
| **ACLs** | Fine-grained access control policies for topics, groups, and clusters. |
| **AD/LDAP Integration** | Authenticate Tantor users against Active Directory or OpenLDAP. Group-to-role mapping, user sync. |
| **Security Scanner** | Comprehensive VAPT assessment — authentication, encryption, ACLs, network config. |
| **mTLS** | Mutual TLS support (coming soon). |

### Monitoring

| Feature | Description |
|---------|-------------|
| **Built-in Metrics** | Live uptime, JVM memory, data size, topics, partitions, connections — no external stack needed. |
| **System Resources** | CPU, memory, and disk utilization per broker. |
| **ISR / Replica Info** | Color-coded ISR status with under-replication warnings. |
| **Grafana Dashboards** | Integrated Prometheus/Grafana with 7-day, 30-day, and 6-month views. |

### Platform

| Feature | Description |
|---------|-------------|
| **Multi-OS Support** | Deploy Kafka to any mix of Ubuntu, RHEL, Rocky, CentOS, Oracle Linux nodes. |
| **Cluster Linking** | MirrorMaker 2 cross-cluster replication for DR and data migration. |
| **Kafka Versions** | Binary repository for air-gapped deployments. Upload once, deploy anywhere. |
| **User Management** | Role-based access control (Admin / Monitor) with login tracking. |
| **Host Editing** | Update hostname, IP, port, username, or credentials for registered hosts. |

---

## Uploading Kafka Binaries (Air-Gapped Environments)

The installer downloads Kafka 3.7.0 automatically. For air-gapped environments or additional versions:

1. Download the Kafka tarball on a machine with internet:
   ```bash
   curl -O https://archive.apache.org/dist/kafka/3.7.0/kafka_2.13-3.7.0.tgz
   ```

2. Copy it to the Tantor server:
   ```bash
   scp kafka_2.13-3.7.0.tgz user@tantor-server:/var/lib/tantor/repo/kafka/
   ```

3. Set ownership:
   ```bash
   sudo chown tantor:tantor /var/lib/tantor/repo/kafka/kafka_2.13-3.7.0.tgz
   ```

Or upload via the UI: **Kafka Versions → Upload Binary**.

---

## Ports

| Port | Service | Open To |
|------|---------|---------|
| **80** | Tantor Web UI | Your browser |
| **22** | SSH | Tantor server → Kafka nodes |
| **9092** | Kafka broker | Applications, inter-broker |
| **9093** | KRaft controller | Inter-broker only |
| **8088** | ksqlDB REST API | Applications (if deployed) |
| **8083** | Kafka Connect REST API | Applications (if deployed) |

---

## Directory Structure (After Installation)

```
/opt/tantor/                    # Application home
  ├── backend/                  # FastAPI backend
  ├── frontend/dist/            # Built React frontend
  ├── venv/                     # Python virtual environment
  └── bin/                      # CLI tools

/var/lib/tantor/                # Persistent data
  ├── db/tantor.db              # SQLite database
  ├── repo/kafka/               # Kafka binaries (air-gapped repo)
  ├── ansible_work/             # Generated playbooks and logs
  └── ssh/                      # SSH key storage

/home/tantor/.ssh/              # SSH keys for Kafka deployment
  ├── id_rsa                    # Private key (auto-generated)
  └── id_rsa.pub                # Public key (add to Kafka nodes)

/var/log/tantor/                # Logs
  ├── backend/                  # API server logs
  └── nginx/                    # Web server logs
```

---

## Uninstall

```bash
sudo ./install.sh --uninstall
```

Removes all Tantor files, services, and the `tantor` system user. Does **not** affect deployed Kafka clusters or the database in `/var/lib/tantor`.

---

## Tech Stack

| Component | Technology |
|-----------|------------|
| Frontend | React 19, TypeScript, Vite, Tailwind CSS |
| Backend | FastAPI, Python 3.11+, SQLAlchemy, SQLite |
| Deployment | Ansible, Paramiko (SSH) |
| Web Server | Nginx |
| Auth | JWT + bcrypt, RBAC (Admin / Monitor), AD/LDAP |
| Credential Storage | Fernet symmetric encryption |
| Kafka | Apache Kafka 3.7.0 (KRaft mode, ZooKeeper optional) |

---

## Troubleshooting

| Problem | Solution |
|---------|----------|
| Can't reach the UI | Check: `systemctl status tantor-backend nginx`. Run `sudo systemctl restart tantor-backend nginx`. |
| Port 80 in use | Stop the conflicting service or change the Nginx listen port in `/etc/nginx/sites-enabled/tantor.conf` (Ubuntu) or `/etc/nginx/conf.d/tantor.conf` (RHEL). |
| SSH connection fails to a host | Verify the host is reachable: `ssh user@ip`. Check firewall allows port 22. Copy the tantor public key: `sudo cat /home/tantor/.ssh/id_rsa.pub`. |
| Deployment stuck | Check logs: `sudo journalctl -u tantor-backend -f`. Common cause: Java not available on target node. |
| "Permission denied" on Kafka nodes | Ensure the SSH user has passwordless sudo: `echo "user ALL=(ALL) NOPASSWD:ALL" \| sudo tee /etc/sudoers.d/user` |
| Kafka binary not found | The installer downloads Kafka 3.7.0 automatically. Check: `ls /var/lib/tantor/repo/kafka/`. Upload via UI if needed. |
| Forgot admin password | `sudo /opt/tantor/venv/bin/python3 -c "from app.services.auth_service import AuthService; AuthService().reset_admin_password()" --chdir /opt/tantor/backend` |
| RHEL Python too old | The installer automatically installs Python 3.11 on RHEL 8.x. If it fails, run: `sudo dnf install python3.11 python3.11-pip python3.11-devel` |

---

## License

Proprietary — Tantor.ai

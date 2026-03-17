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

## Supported Operating Systems

Tantor installs natively on any of these Linux distributions (no Docker required):

| OS | Versions | Tested |
|----|----------|--------|
| **Ubuntu** | 20.04, 22.04, 24.04 | Yes |
| **RHEL** | 8, 9 | Yes |
| **Rocky Linux** | 8, 9 | Yes |
| **CentOS** | Stream 8, Stream 9 | Yes |
| **Oracle Linux** | 8, 9 | Yes |
| **AlmaLinux** | 8, 9 | Yes |
| **Amazon Linux** | 2023 | Yes |
| **Debian** | 11, 12 | Yes |

> Docker-based installation is also available as an alternative.

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

> The installer automatically installs all dependencies: Python 3, Node.js, Nginx, Ansible, and SSH tools. You don't need to install anything beforehand.

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

### Step 1: Download Tantor

```bash
git clone https://github.com/jimmy-fb/tantor.git
cd tantor
```

### Step 2: Install

```bash
sudo ./installer/install.sh
```

That's it. The installer:
- Detects your OS automatically (Ubuntu/Debian or RHEL/CentOS/Rocky/Oracle)
- Installs all system dependencies (Python 3, Node.js 22, Nginx, Ansible, SSH tools)
- Builds the frontend
- Configures Nginx as reverse proxy on port 80
- Sets up systemd services for automatic startup
- Creates the `tantorctl` CLI tool
- Creates the `tantor` system user

### Step 3: Verify

```bash
tantorctl health
# ✓ Tantor is running — http://localhost
```

### Step 4: Open the UI

Open `http://<your-server-ip>` in a browser.

**Default login:** `admin` / `admin`

> Change the password after first login.

---

## How to Deploy a Kafka Cluster

### 1. Add Your Servers

Go to **Hosts** in the left sidebar and click **Add Host**.

For each server that will run Kafka, enter:
- **Hostname** — A friendly name (e.g., `kafka-1`)
- **IP Address** — The private IP of the server
- **SSH Port** — Usually `22`
- **Username** — SSH user (e.g., `ubuntu`, `ec2-user`, `root`)
- **Authentication** — Password or SSH private key

Click **Test Connection** to verify SSH access.

### 2. Create a Cluster

Go to **Clusters** and click **Create Cluster**.

- **Cluster Name** — e.g., `production-cluster`
- **Kafka Version** — Select version (default: 3.7.0)
- **Mode** — KRaft (recommended) or ZooKeeper

### 3. Assign Roles

For each host, assign a role:

| Role | Description |
|------|-------------|
| **Broker + Controller** | Combined mode (recommended for 3-node clusters) |
| **Broker** | Data node only (for larger clusters) |
| **Controller** | KRaft controller only (for larger clusters) |
| **ksqlDB** | Stream processing engine |
| **Kafka Connect** | Data integration connectors |

### 4. Deploy

Click **Deploy**. Tantor will:

1. Validate SSH connections to all nodes
2. Install Java and prerequisites on each node
3. Upload Kafka binaries
4. Generate per-node configurations
5. Format KRaft storage
6. Start Kafka as a systemd service
7. Verify cluster health

Watch the deployment in real-time via the live log stream.

### 5. Manage

Once deployed, use the UI to:

| Feature | Description |
|---------|-------------|
| **Topics** | Create, delete, configure topics. Adjust partitions and replication. |
| **Consumer Groups** | View consumer lag, offsets, and group members. |
| **Broker Config** | Modify broker settings with audit trail and rollback. |
| **ACLs** | Manage access control lists for topics and groups. |
| **SASL Users** | Create and manage SCRAM-SHA authentication users. |
| **Rolling Restart** | Zero-downtime broker restarts. |
| **Cluster Upgrades** | Upgrade Kafka versions across the cluster. |
| **Monitoring** | Deploy Prometheus + Grafana dashboards. |
| **Cluster Linking** | Set up MirrorMaker 2 between clusters. |
| **ksqlDB** | SQL console for stream processing queries. |
| **Kafka Connect** | Deploy and manage data connectors. |
| **Security Scan** | Run VAPT security assessment on the cluster. |
| **Service Logs** | View broker logs from the UI. |

---

## Uploading Kafka Binaries (Air-Gapped Environments)

If your servers don't have internet access, upload Kafka binaries to Tantor first:

1. Download the Kafka tarball on a machine with internet:
   ```bash
   curl -O https://downloads.apache.org/kafka/3.7.0/kafka_2.13-3.7.0.tgz
   ```

2. Copy it to the Tantor server:
   ```bash
   scp kafka_2.13-3.7.0.tgz user@tantor-server:/var/lib/tantor/repo/kafka/
   ```

3. Set ownership:
   ```bash
   sudo chown tantor:tantor /var/lib/tantor/repo/kafka/kafka_2.13-3.7.0.tgz
   ```

The binary is now available for deployment. Tantor copies it to each Kafka node during deployment.

---

## CLI Tool — `tantorctl`

After installation, use `tantorctl` for server management:

```bash
tantorctl status           # Show service status
tantorctl start            # Start Tantor services
tantorctl stop             # Stop Tantor services
tantorctl restart          # Restart services
tantorctl health           # Check if Tantor is running
tantorctl logs             # Tail all logs
tantorctl logs backend     # Tail backend logs only
tantorctl logs nginx       # Tail nginx logs only
tantorctl logs error       # Tail error logs only
tantorctl version          # Show version and paths
tantorctl backup           # Backup database
tantorctl restore <file>   # Restore database from backup
tantorctl reset-password   # Reset admin password to 'admin'
```

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
| **9090** | Prometheus | Internal (if monitoring deployed) |
| **3000** | Grafana | Via Tantor UI (if monitoring deployed) |

---

## Directory Structure (After Installation)

```
/opt/tantor/                    # Application home
  ├── backend/                  # FastAPI backend
  ├── frontend/dist/            # Built React frontend
  └── bin/tantorctl             # CLI tool

/var/lib/tantor/                # Persistent data
  ├── db/tantor.db              # SQLite database
  ├── repo/kafka/               # Kafka binaries (air-gapped repo)
  ├── ansible_work/             # Generated playbooks and logs
  └── ssh/                      # SSH key storage

/var/log/tantor/                # Logs
  ├── backend/                  # API server logs
  └── nginx/                    # Web server logs
```

---

## Docker Installation (Alternative)

If you prefer Docker over native install:

```bash
# Ubuntu-based image
sudo ./installer/install.sh --docker

# RHEL-based image
sudo ./installer/install.sh --docker --rhel
```

This builds an all-in-one Docker image with everything bundled (Nginx + Backend + Frontend).

---

## Uninstall

```bash
sudo ./installer/install.sh --uninstall
```

Removes all Tantor files, services, and the `tantor` system user. Does **not** affect deployed Kafka clusters.

---

## AWS Deployment (Terraform)

For cloud testing, Terraform scripts are included to provision infrastructure on AWS and deploy Tantor + a Kafka cluster automatically:

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
terraform init

# Deploy on Ubuntu
terraform apply -var="os_variant=ubuntu"

# Deploy on RHEL (Rocky Linux 9)
terraform apply -var="os_variant=rhel"

# Full E2E test (Ubuntu + RHEL, auto-teardown)
./scripts/test-e2e.sh
```

See [`terraform/README.md`](terraform/README.md) for details.

---

## Security Scanning (VAPT)

Tantor includes built-in security scanning tools:

| Scanner | What It Scans | How to Run |
|---------|---------------|------------|
| **Built-in Security Scan** | Kafka ACLs, auth, configs, network | From the UI: Clusters → Security Scan |
| **kafka-vapt** | 40+ Kafka-specific checks (nmap, kcat, openssl) | `cd kafka-vapt && ./run-kafka-vapt.sh --bootstrap broker:9092` |
| **OWASP ZAP** | Web UI + API vulnerabilities | `cd vapt-scan && ./run-vapt.sh https://tantor-server` |

---

## Tech Stack

| Component | Technology |
|-----------|------------|
| Frontend | React 19, TypeScript, Vite, Tailwind CSS |
| Backend | FastAPI, Python 3.12, SQLAlchemy, SQLite |
| Deployment | Ansible, Paramiko (SSH) |
| Web Server | Nginx |
| Auth | JWT + bcrypt, role-based (Admin / Monitor) |
| Credential Storage | Fernet symmetric encryption |

---

## Troubleshooting

| Problem | Solution |
|---------|----------|
| Can't reach the UI | Check: `tantorctl status` — services may not be running. Run `tantorctl start`. |
| Port 80 in use | Stop the conflicting service or change Nginx port in `/etc/nginx/sites-enabled/tantor.conf`. |
| SSH connection fails to a host | Verify the host is reachable: `ssh -i key user@ip`. Check firewall allows port 22. |
| Deployment stuck | Check logs: `tantorctl logs backend`. Common cause: Java not available on target node. |
| "Permission denied" on Kafka nodes | Ensure the SSH user has passwordless sudo: `echo "user ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/tantor` |
| Kafka binary not found | Upload it to `/var/lib/tantor/repo/kafka/` — see Air-Gapped section above. |
| Forgot admin password | Run `tantorctl reset-password` to reset to `admin/admin`. |
| Database backup | Run `tantorctl backup` — saves to `/var/lib/tantor/db/backups/`. |

---

## License

MIT

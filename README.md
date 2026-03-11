# Tantor - Kafka Cluster Management & Security Platform

Tantor is a full-stack platform for deploying, managing, and security-scanning Apache Kafka clusters. It combines a web-based management UI with automated VAPT (Vulnerability Assessment & Penetration Testing) scanning.

---

## Architecture

```
┌──────────────────────────────────────────────────────────┐
│                     Tantor Platform                      │
├──────────────┬──────────────┬────────────────────────────┤
│   Frontend   │   Backend    │     Security Scanning      │
│  React + TS  │   FastAPI    │                            │
│   Vite SPA   │  Python 3.12 │  ┌──────────┐ ┌─────────┐ │
│              │              │  │ vapt-scan│ │kafka-vapt│ │
│  Mantine UI  │  SQLAlchemy  │  │ OWASP ZAP│ │ nmap     │ │
│              │  Ansible     │  │ Web App  │ │ openssl  │ │
│              │  Paramiko    │  │ Scanner  │ │ kcat     │ │
│              │              │  └──────────┘ └─────────┘ │
├──────────────┴──────────────┴────────────────────────────┤
│              Kafka Clusters (KRaft Mode)                 │
│          Deployed via SSH + Ansible Playbooks             │
└──────────────────────────────────────────────────────────┘
```

## Project Structure

```
tantor/
├── backend/                 # FastAPI backend (Python 3.12)
│   ├── app/
│   │   ├── api/             # REST API routes (auth, clusters, topics, etc.)
│   │   ├── models/          # SQLAlchemy ORM models
│   │   ├── schemas/         # Pydantic request/response schemas
│   │   ├── services/        # Business logic (SSH, Ansible, Kafka admin)
│   │   └── templates/       # Jinja2 templates for Ansible/configs
│   ├── requirements.txt
│   └── Dockerfile
│
├── frontend/                # React + TypeScript SPA
│   ├── src/
│   │   ├── pages/           # Dashboard, Clusters, Hosts, Topics, etc.
│   │   ├── components/      # Reusable UI components
│   │   ├── hooks/           # Custom React hooks (WebSocket, etc.)
│   │   └── lib/             # API client, auth utilities
│   ├── package.json
│   └── Dockerfile.prod
│
├── kafka-vapt/              # Kafka cluster VAPT scanner
│   ├── run-kafka-vapt.sh    # Main scanner (30+ security checks)
│   ├── run-e2e-vapt.sh      # End-to-end runner (cluster + scan)
│   ├── docker-compose.kafka-test.yml  # Test cluster (3-broker KRaft)
│   ├── Dockerfile           # Containerized scanner
│   └── README.md            # Detailed scanner docs
│
├── vapt-scan/               # Web application VAPT scanner (OWASP ZAP)
│   ├── run-vapt.sh          # ZAP scanning wrapper
│   └── README.md
│
├── docker-compose.yml       # Production deployment
├── docker-compose.e2e.yml   # E2E test environment
├── Caddyfile                # Caddy reverse proxy config
├── nginx.conf               # Nginx reverse proxy config
└── e2e-test.sh              # E2E integration test script
```

---

## Prerequisites

| Tool | Version | Purpose |
|------|---------|---------|
| Docker | 20+ | Container runtime |
| Node.js | 18+ | Frontend build |
| Python | 3.12+ | Backend runtime |
| nmap | any | Network scanning (VAPT) |
| kcat | 1.7+ | Kafka testing (VAPT) |
| jq | any | JSON processing (VAPT) |

### Install scanning tools

```bash
# macOS
brew install nmap jq kcat

# Ubuntu / Debian
sudo apt-get install -y nmap jq kafkacat
```

---

## Quick Start

### 1. Start the Platform

```bash
# Start backend + frontend
docker compose up -d

# Open the UI
open http://localhost
# Default login: admin / admin
```

### 2. Deploy a Kafka Cluster (via UI)

1. **Add Hosts** - Navigate to Hosts, add your target servers (SSH credentials)
2. **Create Cluster** - Go to Clusters > New, select KRaft mode
3. **Configure Brokers** - Assign broker/controller roles to hosts
4. **Deploy** - Click Deploy and monitor progress in real-time

### 3. Run VAPT Security Scan on the Cluster

```bash
cd kafka-vapt

# Scan your deployed cluster
./run-kafka-vapt.sh --bootstrap <broker-ip>:9092

# Or run the full end-to-end (spins up a test cluster, scans it, generates report)
./run-e2e-vapt.sh
```

---

## Kafka VAPT Scanner - How to Use

The `kafka-vapt/` directory contains a standalone security scanner for Kafka clusters. It performs **30+ automated checks** across 6 security categories using open-source tools.

### Open-Source Tools Used

| Tool | What it does in the scan |
|------|--------------------------|
| **nmap** | Scans ports, detects exposed services (Kafka, ZooKeeper, JMX, ksqlDB) |
| **openssl** | Tests TLS/SSL certificates, cipher suites, protocol versions |
| **kcat** | Tests unauthenticated access, PLAINTEXT listeners, data exposure |
| **Kafka CLI** | Inspects broker configs, ACLs, replication, topic settings |
| **curl** | Tests ksqlDB REST API security, authentication, query execution |
| **jq** | Processes JSON results, generates structured reports |

### Security Categories

| # | Category | What it checks |
|---|----------|----------------|
| 1 | **Network** (NET-*) | Open ports, unnecessary services, ZooKeeper exposure |
| 2 | **TLS/SSL** (TLS-*) | Encryption enabled, cert expiry, weak ciphers, old protocols |
| 3 | **Authentication** (AUTH-*) | Unauth access, PLAINTEXT listeners, ACLs, SASL config |
| 4 | **Configuration** (CFG-*) | Auto-create topics, replication factor, HA, authorizer |
| 5 | **Data** (DATA-*) | Sensitive topic names, data access controls, encryption at rest |
| 6 | **Operational** (OPS-*) | JMX exposure, Kafka Connect API, Schema Registry |
| 7 | **ksqlDB** (KSQL-*) | REST API auth, TLS, query execution, topic enumeration, schema exposure, command/processing log topics |

### Run Options

```bash
cd kafka-vapt

# ─── Option A: Full End-to-End (includes test cluster) ───
./run-e2e-vapt.sh                    # Start cluster → scan → report → cleanup
./run-e2e-vapt.sh --no-cleanup       # Keep cluster running after scan
./run-e2e-vapt.sh --skip-setup       # Use an already-running cluster

# ─── Option B: Scan an Existing Cluster ───
./run-kafka-vapt.sh --bootstrap broker1:9092

# Multiple brokers
./run-kafka-vapt.sh --bootstrap broker1:9092 \
  --brokers broker1:9092,broker2:9092,broker3:9092

# With SSL/TLS
./run-kafka-vapt.sh --bootstrap broker1:9093 --ssl

# With SASL authentication
./run-kafka-vapt.sh --bootstrap broker1:9092 \
  --sasl-mechanism SCRAM-SHA-256 \
  --sasl-username admin \
  --sasl-password secret

# With a client.properties file
./run-kafka-vapt.sh --bootstrap broker1:9092 \
  --client-props /path/to/client.properties

# With Kafka CLI tools path
./run-kafka-vapt.sh --bootstrap broker1:9092 \
  --kafka-home /opt/kafka

# With ksqlDB scanning
./run-kafka-vapt.sh --bootstrap broker1:9092 \
  --ksqldb http://ksqldb-host:8088

# ─── Option C: Docker Mode (no local tools needed) ───
./run-kafka-vapt.sh --bootstrap broker1:9092 --docker
```

### Report Output

Reports are saved in `kafka-vapt/reports/`:

| File | Format | Usage |
|------|--------|-------|
| `*-report.html` | HTML | Interactive dashboard, open in browser |
| `*-results.json` | JSON | CI/CD integration, programmatic access |

#### Security Grading

| Grade | Meaning |
|-------|---------|
| **A** | No failures, no warnings - production ready |
| **B+** | No failures, 1-2 minor warnings |
| **B** | No failures, 3-5 warnings |
| **C** | 1 failure or 6+ warnings - needs attention |
| **D** | 2-3 failures - significant security gaps |
| **F** | 4+ failures or any critical finding - not production ready |

### Example: Scan a Local Test Cluster

```bash
cd kafka-vapt

# 1. Start the 3-broker KRaft test cluster
docker compose -f docker-compose.kafka-test.yml up -d

# 2. Wait for brokers to be ready (~30 seconds)
sleep 30

# 3. Run the VAPT scan
./run-kafka-vapt.sh --bootstrap localhost:9092 --output ./reports --format both

# 4. Open the HTML report
open ./reports/*-report.html

# 5. Cleanup
docker compose -f docker-compose.kafka-test.yml down -v
```

### CI/CD Integration (GitHub Actions)

```yaml
name: Kafka Security Scan
on:
  schedule:
    - cron: '0 6 * * 1'    # Weekly Monday 6am
  workflow_dispatch:        # Manual trigger

jobs:
  vapt-scan:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Install scanning tools
        run: sudo apt-get update && sudo apt-get install -y nmap jq kafkacat

      - name: Start test Kafka cluster
        run: |
          cd kafka-vapt
          docker compose -f docker-compose.kafka-test.yml up -d
          sleep 30

      - name: Run VAPT scan
        run: |
          cd kafka-vapt
          chmod +x run-kafka-vapt.sh
          ./run-kafka-vapt.sh --bootstrap localhost:9092 --format both

      - name: Upload reports
        uses: actions/upload-artifact@v4
        with:
          name: kafka-vapt-report
          path: kafka-vapt/reports/

      - name: Teardown
        if: always()
        run: cd kafka-vapt && docker compose -f docker-compose.kafka-test.yml down -v
```

---

## Web Application VAPT Scanner

The `vapt-scan/` directory contains OWASP ZAP-based security scanning for the Tantor web UI and API.

```bash
cd vapt-scan

# Baseline (passive) scan of the backend API
./run-vapt.sh --api

# Full active scan
./run-vapt.sh --full

# See all options
./run-vapt.sh --help
```

---

## E2E Testing

```bash
# Start the full test environment (backend + 2 Ubuntu VMs)
./e2e-test.sh

# This will:
# 1. Build and start containers
# 2. Wait for health checks
# 3. Provide instructions for manual testing
```

---

## Development

### Backend

```bash
cd backend
python -m venv venv
source venv/bin/activate
pip install -r requirements.txt
uvicorn app.main:app --reload --port 8000
```

### Frontend

```bash
cd frontend
npm install
npm run dev    # Starts on http://localhost:5173
```

### Production

```bash
# Using Docker Compose
docker compose up -d

# Access at http://localhost (Nginx) or configure Caddy
```

---

## Tech Stack

| Layer | Technology |
|-------|------------|
| Frontend | React 19, TypeScript, Vite, Mantine UI |
| Backend | FastAPI, Python 3.12, SQLAlchemy, SQLite |
| Orchestration | Ansible, Paramiko (SSH) |
| Auth | JWT + bcrypt |
| Reverse Proxy | Caddy or Nginx |
| Kafka Scanning | nmap, openssl, kcat, Kafka CLI |
| Web Scanning | OWASP ZAP |
| Containers | Docker, Docker Compose |

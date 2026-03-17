# Tantor — AWS Terraform E2E Deployment

Terraform scripts to deploy Tantor **natively** on AWS EC2 instances (no Docker required) and automatically deploy a 3-node Apache Kafka KRaft cluster through the Tantor API. Supports both **Ubuntu 22.04** and **RHEL 9** (Rocky Linux).

---

## What It Does

1. **Provisions AWS infrastructure** — VPC, subnet, security groups, SSH key pair
2. **Deploys Tantor server** — EC2 instance with native `install.sh` (Python, Nginx, Node.js, systemd)
3. **Deploys 3 Kafka nodes** — EC2 instances with Java 17 pre-installed
4. **Automates Kafka deployment** — Uses Tantor's REST API to register hosts, create a KRaft cluster, and deploy
5. **Verifies end-to-end** — Confirms all 3 brokers are running
6. **Cleans up** — Destroys all infrastructure after testing

### Supported Operating Systems

| OS | AMI | SSH User |
|----|-----|----------|
| Ubuntu 22.04 LTS | Canonical official | `ubuntu` |
| Rocky Linux 9 | Rocky Linux official (RHEL 9 compatible) | `ec2-user` |

Also compatible with: CentOS, AlmaLinux, Oracle Linux, Amazon Linux, Fedora, Debian.

---

## Prerequisites

- **AWS CLI** configured with credentials (`aws configure`)
- **Terraform** >= 1.5 — [Install](https://developer.hashicorp.com/terraform/install)
- **jq** — `brew install jq` (macOS) or `apt install jq`
- Tantor repo accessible from EC2 (public GitHub or provide a token)

---

## Quick Start

### Run Full E2E Test (Both OS)

```bash
cd terraform/
cp terraform.tfvars.example terraform.tfvars  # Edit if needed

./scripts/test-e2e.sh
```

This runs the complete cycle for **Ubuntu first, then RHEL**:
- Provisions 4 EC2 instances per OS variant
- Installs Tantor natively
- Deploys a 3-node Kafka KRaft cluster
- Verifies, then tears down

### Run Single OS

```bash
./scripts/test-e2e.sh ubuntu       # Ubuntu only
./scripts/test-e2e.sh rhel         # RHEL only
```

### Keep Infrastructure Running (for debugging)

```bash
./scripts/test-e2e.sh ubuntu --no-destroy
```

---

## Manual Step-by-Step

### 1. Initialize and Apply

```bash
cd terraform/
terraform init

# Deploy with Ubuntu
terraform apply -var="os_variant=ubuntu"

# Or deploy with RHEL
terraform apply -var="os_variant=rhel"
```

### 2. Wait for Tantor to Install (~5 minutes)

```bash
# Check cloud-init progress
ssh -i tantor-key.pem ubuntu@$(terraform output -raw tantor_public_ip) \
  'tail -f /var/log/tantor-cloud-init.log'
```

### 3. Deploy Kafka via API

```bash
./scripts/deploy-kafka.sh
```

### 4. Access Tantor UI

```bash
echo "Open: $(terraform output -raw tantor_url)"
# Login: admin / admin
```

### 5. SSH into Instances

```bash
# Save SSH key
terraform output -raw private_key_pem > tantor-key.pem && chmod 600 tantor-key.pem

# SSH to Tantor server
ssh -i tantor-key.pem ubuntu@$(terraform output -raw tantor_public_ip)

# SSH to Kafka nodes
ssh -i tantor-key.pem ubuntu@$(terraform output -json kafka_public_ips | jq -r '.[0]')
```

### 6. Teardown

```bash
terraform destroy
```

---

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                      AWS VPC (10.0.0.0/16)              │
│  ┌───────────────────────────────────────────────────┐  │
│  │              Public Subnet (10.0.1.0/24)          │  │
│  │                                                   │  │
│  │  ┌──────────────────┐                             │  │
│  │  │  Tantor Server   │ ◄─── Port 80 (UI + API)    │  │
│  │  │  (t3.large)      │                             │  │
│  │  │                  │──── SSH (port 22) ────┐     │  │
│  │  │  - Nginx         │                      │     │  │
│  │  │  - FastAPI       │                      ▼     │  │
│  │  │  - Node.js       │  ┌────────┐ ┌────────┐    │  │
│  │  │  - Ansible       │  │Kafka-1 │ │Kafka-2 │    │  │
│  │  │  - tantorctl     │  │(broker+│ │(broker+│    │  │
│  │  └──────────────────┘  │control)│ │control)│    │  │
│  │                        └────────┘ └────────┘    │  │
│  │                              ┌────────┐          │  │
│  │                              │Kafka-3 │          │  │
│  │                              │(broker+│          │  │
│  │                              │control)│          │  │
│  │                              └────────┘          │  │
│  └───────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────┘
```

---

## Configuration

Copy and edit the example tfvars:

```bash
cp terraform.tfvars.example terraform.tfvars
```

| Variable | Default | Description |
|----------|---------|-------------|
| `aws_region` | `us-east-1` | AWS region |
| `os_variant` | `ubuntu` | `ubuntu` or `rhel` |
| `tantor_instance_type` | `t3.large` | Tantor server instance type |
| `kafka_instance_type` | `t3.medium` | Kafka node instance type |
| `kafka_node_count` | `3` | Number of Kafka nodes |
| `kafka_version` | `3.7.0` | Apache Kafka version |
| `github_repo` | (tantor repo) | Git repo URL for Tantor source |
| `github_token` | `""` | GitHub PAT for private repos |

---

## Security Groups

| Security Group | Inbound Rules |
|----------------|---------------|
| **tantor-server** | SSH (22), HTTP (80) from anywhere |
| **kafka-nodes** | SSH (22) from Tantor SG, Kafka (9092-9093) self + from Tantor SG |

---

## Costs

Approximate AWS costs for running the E2E test:

| Resource | Type | Cost/Hour |
|----------|------|-----------|
| Tantor Server | t3.large | ~$0.083 |
| Kafka Nodes (x3) | t3.medium | ~$0.125 |
| **Total** | | **~$0.21/hr** |

A full E2E test run (Ubuntu + RHEL) takes approximately 30-45 minutes and costs roughly **$0.15-0.20**.

---

## Troubleshooting

| Issue | Solution |
|-------|----------|
| Terraform apply fails | Check AWS credentials: `aws sts get-caller-identity` |
| Tantor API not responding | SSH in and check: `tail /var/log/tantor-cloud-init.log` |
| SSH test fails | Cloud-init may still be running — script retries 5x with 20s delay |
| Kafka deploy fails | Check Tantor logs: `ssh ... 'tantorctl logs backend'` |
| AMI not found | Region may not have the AMI — try `us-east-1` |
| Timeout waiting for health | Install takes ~5min; increase `MAX_WAIT` in deploy-kafka.sh |

---

## Native Installation (No Docker)

The Tantor server is installed **natively** using `install.sh --force`, which:

1. Detects the OS family (Debian/Ubuntu or RHEL/Rocky/CentOS/Oracle Linux)
2. Installs system packages: Python 3, Nginx, Node.js 22, Ansible, SSH tools
3. Builds the React frontend with `npm run build`
4. Configures Nginx as a reverse proxy (port 80 → frontend + `/api/` → backend)
5. Creates systemd services (`tantor-backend.service`)
6. Installs the `tantorctl` CLI tool
7. Starts all services

No Docker is required on the Tantor server or Kafka nodes.

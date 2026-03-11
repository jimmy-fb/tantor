# Qualys Community Edition - Kafka VAPT Scanner

Vulnerability Assessment and Penetration Testing for Apache Kafka clusters using **Qualys Community Edition** (free tier).

## What is Qualys CE?

Qualys is a cloud-based vulnerability management platform. The **Community Edition** is free with limitations:

| Feature | Free CE | Paid (VMDR) |
|---------|---------|-------------|
| Internal IPs | 16 | Unlimited |
| External IPs | 3 | Unlimited |
| Scanner Appliances | 1 | Unlimited |
| API Access | No | Yes |
| Compliance Scans | No | Yes |
| Scheduled Scans | Limited | Yes |
| Reports | Basic | Full |

## What Qualys Scans (Infrastructure Level)

| Category | Description | Kafka Relevance |
|----------|-------------|-----------------|
| Open Ports | TCP/UDP scanning | Detects exposed Kafka, ZK, ksqlDB ports |
| OS Vulnerabilities | Known CVEs | Broker host OS security |
| Service Detection | Version fingerprinting | Kafka version, Java version |
| SSL/TLS | Certificate & cipher analysis | Kafka SSL listener config |
| Known Exploits | CVE database matching | Apache Kafka CVEs, Log4j |
| Network Config | Routing, segmentation | Broker network isolation |

> **Note:** Qualys does NOT have Kafka-specific checks (ACLs, SASL, topic-level security). Use the `kafka-vapt/` scanner for those.

## Quick Start

### 1. Prerequisites

- Docker & Docker Compose
- curl, jq
- Qualys CE account ([Sign up free](https://www.qualys.com/community-edition/))

### 2. Start Test Kafka Cluster

```bash
docker compose -f docker-compose.qualys-test.yml up -d
```

### 3. Setup Qualys (First Time)

```bash
./run-qualys-vapt.sh --setup
```

### 4. Run Scan

**Manual Mode (Free CE Tier):**
```bash
./run-qualys-vapt.sh --scan --manual
```

**API Mode (Paid/Trial):**
```bash
./run-qualys-vapt.sh --scan
```

### 5. Download Report

```bash
./run-qualys-vapt.sh --report
```

### 6. End-to-End Pipeline

```bash
./run-e2e-qualys.sh                # Full pipeline
./run-e2e-qualys.sh --no-cluster   # Skip cluster startup
./run-e2e-qualys.sh --cleanup      # Tear down
```

## File Structure

```
qualys-vapt/
├── run-qualys-vapt.sh              # Main scanner script
├── run-e2e-qualys.sh               # End-to-end pipeline
├── docker-compose.qualys-test.yml  # Test Kafka cluster
├── config/
│   ├── qualys-config.env.example   # Config template
│   └── qualys-config.env           # Your config (git-ignored)
├── reports/                        # Scan reports (git-ignored)
└── README.md
```

## Qualys Virtual Scanner Setup

To scan internal Docker network IPs, you need a Virtual Scanner:

1. Log in to [Qualys Portal](https://qualysguard.qualys.com)
2. Go to **Scans > Appliances > New > Virtual Scanner**
3. Choose **Docker** as platform
4. Copy the Personalization Code
5. Run the scanner:

```bash
docker run -d --name qualys-scanner \
  --network qualys-vapt_kafka-qualys-net \
  --ip 172.28.0.100 \
  -e PERSO_CODE=YOUR_CODE_HERE \
  qualys/qvsa:latest
```

## Kafka-Specific Ports to Scan

Configure these ports in your Qualys Option Profile:

| Port | Service | Security Risk |
|------|---------|---------------|
| 9092 | Kafka PLAINTEXT | Unencrypted connections |
| 9093 | Kafka Controller | Cluster control plane |
| 9094 | Kafka SSL | Encrypted connections |
| 8088 | ksqlDB REST | Query execution |
| 2181 | ZooKeeper | Cluster control |
| 8081 | Schema Registry | Schema exposure |
| 8083 | Kafka Connect | Connector manipulation |

## Combining with Kafka-Specific VAPT

For comprehensive coverage, run both scanners:

```bash
# 1. Infrastructure-level scan (Qualys)
./qualys-vapt/run-qualys-vapt.sh --scan --manual

# 2. Kafka-specific security scan
./kafka-vapt/run-kafka-vapt.sh --bootstrap "localhost:19092" --ksqldb "http://localhost:18088"
```

| Check Type | Qualys CE | kafka-vapt |
|-----------|-----------|------------|
| Port scanning | ✅ | ✅ |
| OS CVEs | ✅ | ❌ |
| Kafka ACLs | ❌ | ✅ |
| SASL/Auth | ❌ | ✅ |
| Topic security | ❌ | ✅ |
| SSL/TLS certs | ✅ | ✅ |
| ksqlDB checks | ❌ | ✅ |
| Network vulns | ✅ | ❌ |
| Java CVEs | ✅ | ❌ |

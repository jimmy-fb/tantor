# OpenVAS (Greenbone) - Kafka VAPT Scanner

Vulnerability Assessment and Penetration Testing for Apache Kafka clusters using **OpenVAS / Greenbone Community Edition** - 100% free and open-source.

## Why OpenVAS?

| Feature | OpenVAS (Greenbone CE) | Qualys CE | kafka-vapt |
|---------|----------------------|-----------|------------|
| Cost | **100% Free** | Free (limited) | Free |
| Open Source | **Yes (GPL)** | No | Yes |
| API Access | **Yes** | No (CE tier) | N/A |
| Vulnerability Tests | **80,000+ NVTs** | Extensive | 40+ Kafka-specific |
| Automation | **Full API** | Manual only (CE) | Full CLI |
| Infrastructure Scanning | **Yes** | Yes | No |
| Kafka-Specific Checks | No | No | **Yes** |
| OS/CVE Detection | **Yes** | Yes | No |
| Compliance Checks | **Basic** | No (CE) | No |

## Quick Start

### 1. Prerequisites

- Docker & Docker Compose (4GB+ RAM recommended)
- curl, jq
- ~5GB disk space for first-time image downloads

### 2. Start Everything (Kafka + OpenVAS)

```bash
# Full end-to-end pipeline
./run-e2e-openvas.sh

# Or step by step:
docker compose -f docker-compose.openvas-test.yml up -d
```

> **Note:** First startup takes **10-15 minutes** for OpenVAS to download and sync 80,000+ vulnerability feeds.

### 3. Check Status

```bash
./run-openvas-vapt.sh --status
```

### 4. Run Scan

```bash
# Automated scan via GMP API
./run-openvas-vapt.sh --scan

# Custom targets
./run-openvas-vapt.sh --scan --targets "172.29.0.10,172.29.0.11,172.29.0.12"

# Full pipeline (wait for ready + scan + report)
./run-openvas-vapt.sh --full
```

### 5. Download Report

```bash
./run-openvas-vapt.sh --report
```

### 6. Web UI

```bash
./run-openvas-vapt.sh --webui
```

- URL: **https://localhost:9443**
- Username: `admin`
- Password: `admin`

### 7. Cleanup

```bash
./run-e2e-openvas.sh --cleanup
```

## File Structure

```
openvas-vapt/
├── run-openvas-vapt.sh                # Main scanner (GMP API automation)
├── run-e2e-openvas.sh                 # End-to-end pipeline
├── docker-compose.openvas-test.yml    # Kafka + OpenVAS full stack
├── config/                            # Configuration files
├── reports/                           # Scan reports (git-ignored)
└── README.md
```

## Architecture

```
┌──────────────────────────────────────────────────────┐
│                Docker Network (172.29.0.0/16)         │
│                                                       │
│  ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌──────────┐  │
│  │ kafka-1 │ │ kafka-2 │ │ kafka-3 │ │ ksqlDB   │  │
│  │ .0.10   │ │ .0.11   │ │ .0.12   │ │ .0.20    │  │
│  │ :9092   │ │ :9092   │ │ :9092   │ │ :8088    │  │
│  └─────────┘ └─────────┘ └─────────┘ └──────────┘  │
│                      ▲                                │
│                      │ Scans                          │
│  ┌───────────────────┴────────────────────────────┐  │
│  │            OpenVAS / Greenbone CE               │  │
│  │  ┌──────────┐ ┌──────┐ ┌────────┐ ┌────────┐  │  │
│  │  │ Scanner  │ │ GVMD │ │ GSAD   │ │Postgres│  │  │
│  │  │ .0.100   │ │.0.101│ │.0.102  │ │.0.103  │  │  │
│  │  └──────────┘ └──────┘ └────────┘ └────────┘  │  │
│  │  ┌──────┐ ┌──────┐ ┌───────┐ ┌──────────┐    │  │
│  │  │Redis │ │ MQTT │ │ Notus │ │ OSPD     │    │  │
│  │  │.0.104│ │.0.105│ │ .0.106│ │ .0.107   │    │  │
│  │  └──────┘ └──────┘ └───────┘ └──────────┘    │  │
│  └────────────────────────────────────────────────┘  │
│                                                       │
│  Web UI: https://localhost:9443                        │
└──────────────────────────────────────────────────────┘
```

## What OpenVAS Detects

### Infrastructure-Level Checks

| Category | NVTs | Kafka Relevance |
|----------|------|-----------------|
| Port Scanning | ~500 | Open Kafka, ZK, ksqlDB ports |
| OS CVEs | ~5000 | Broker host vulnerabilities |
| SSL/TLS | ~150 | Kafka SSL listener analysis |
| Java/JVM | ~300 | Log4Shell, Java CVEs |
| Apache CVEs | ~100 | Kafka-specific vulnerabilities |
| Web Services | ~1500 | ksqlDB REST, Schema Registry |
| Network Config | ~500 | Misconfigurations |
| Brute Force | ~200 | Weak credentials |

### Key Kafka CVEs Detected

| CVE | Severity | Description |
|-----|----------|-------------|
| CVE-2021-44228 | Critical | Log4Shell (Log4j RCE) |
| CVE-2023-25194 | High | Kafka Connect JNDI injection |
| CVE-2023-34455 | High | Snappy decompression DoS |
| CVE-2024-31141 | Medium | Kafka Clients SSRF |

## GMP API Commands

The script uses Greenbone Management Protocol (GMP) via `gvm-tools`:

```bash
# Check version
docker exec openvas-gvm-tools gvm-cli \
  --gmp-username admin --gmp-password admin \
  socket --socketpath /run/ospd/gvmd.sock \
  --xml '<get_version/>'

# List scans
docker exec openvas-gvm-tools gvm-cli \
  --gmp-username admin --gmp-password admin \
  socket --socketpath /run/ospd/gvmd.sock \
  --xml '<get_tasks/>'

# Get feeds status
docker exec openvas-gvm-tools gvm-cli \
  --gmp-username admin --gmp-password admin \
  socket --socketpath /run/ospd/gvmd.sock \
  --xml '<get_feeds/>'
```

## CI/CD Integration

### GitHub Actions

```yaml
jobs:
  openvas-vapt:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Start OpenVAS + Kafka
        run: |
          cd openvas-vapt
          docker compose -f docker-compose.openvas-test.yml up -d
          ./run-openvas-vapt.sh --wait-ready

      - name: Run VAPT Scan
        run: |
          cd openvas-vapt
          ./run-openvas-vapt.sh --full

      - name: Upload Report
        uses: actions/upload-artifact@v4
        with:
          name: openvas-vapt-report
          path: openvas-vapt/reports/
```

## Combining All Scanners

For maximum VAPT coverage, run all three scanners:

```bash
# 1. OpenVAS - Infrastructure/CVE scanning (this folder)
./openvas-vapt/run-openvas-vapt.sh --full

# 2. Kafka VAPT - Kafka-specific security checks
./kafka-vapt/run-kafka-vapt.sh --bootstrap "localhost:29092" --ksqldb "http://localhost:28088"

# 3. Qualys CE - Commercial-grade scanning (optional)
./qualys-vapt/run-qualys-vapt.sh --scan --manual
```

### Coverage Matrix

| Check | OpenVAS | kafka-vapt | Qualys CE |
|-------|---------|------------|-----------|
| Port scanning | ✅ | ✅ | ✅ |
| OS CVEs | ✅ | ❌ | ✅ |
| Java CVEs | ✅ | ❌ | ✅ |
| Kafka ACLs | ❌ | ✅ | ❌ |
| SASL/Auth | ❌ | ✅ | ❌ |
| Topic security | ❌ | ✅ | ❌ |
| SSL/TLS certs | ✅ | ✅ | ✅ |
| ksqlDB checks | ❌ | ✅ | ❌ |
| Network vulns | ✅ | ❌ | ✅ |
| Log4j/Log4Shell | ✅ | ❌ | ✅ |
| Web app vulns | ✅ | ❌ | ✅ |
| Compliance | ✅ | ❌ | ❌ (CE) |
| Full API automation | ✅ | ✅ | ❌ (CE) |
| Cost | Free | Free | Free (limited) |

## Troubleshooting

### OpenVAS won't start
```bash
# Check logs
docker compose -f docker-compose.openvas-test.yml logs gvmd
docker compose -f docker-compose.openvas-test.yml logs ospd-openvas

# Restart everything
docker compose -f docker-compose.openvas-test.yml down -v
docker compose -f docker-compose.openvas-test.yml up -d
```

### Feed sync takes too long
First-time feed sync can take 15-30 minutes. Check progress:
```bash
docker logs openvas-gvmd 2>&1 | tail -20
```

### Scan doesn't find anything
Ensure the scanner container is on the same Docker network as Kafka brokers:
```bash
docker network inspect openvas-vapt_kafka-openvas-net
```

### Memory issues
OpenVAS requires significant RAM. Recommended: 4GB+ for Docker.
```bash
# Check container resource usage
docker stats --no-stream
```

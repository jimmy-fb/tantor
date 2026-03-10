# Kafka Cluster VAPT Scanner

Automated Vulnerability Assessment & Penetration Testing (VAPT) toolkit for Apache Kafka clusters using open-source tools.

## Open-Source Tools Used

| Tool | Purpose |
|------|---------|
| **nmap** | Network/port scanning, service detection |
| **openssl** | TLS/SSL certificate & cipher analysis |
| **kcat** (kafkacat) | Kafka connectivity, auth, and data access testing |
| **Kafka CLI** | Native broker config, ACL, and metadata inspection |
| **jq** | JSON processing for report generation |

## Security Checks (30+ checks across 6 categories)

### 1. Network Security (NET-*)
- Port scanning for Kafka services
- Detection of unnecessary open ports
- ZooKeeper exposure check
- DNS resolution validation

### 2. TLS/SSL Security (TLS-*)
- TLS enabled/disabled detection
- Certificate expiry monitoring
- Weak cipher suite detection
- Deprecated protocol version check (TLSv1.0, TLSv1.1)
- Certificate chain validation

### 3. Authentication & Authorization (AUTH-*)
- Unauthenticated access testing
- PLAINTEXT listener detection
- ACL configuration audit
- Inter-broker authentication check
- SASL mechanism validation

### 4. Configuration Security (CFG-*)
- Auto topic creation check
- Topic deletion policy
- Message size limits
- Log retention compliance
- Advertised listeners validation
- Authorizer configuration
- Replication factor analysis
- High availability assessment

### 5. Data Security (DATA-*)
- Sensitive topic name detection
- Topic data access testing
- Encryption at rest guidance

### 6. Operational Security (OPS-*)
- JMX port exposure (RCE risk)
- Consumer group auditing
- Kafka Connect REST API exposure
- Schema Registry exposure

## Quick Start

### Prerequisites

```bash
# macOS
brew install nmap jq kcat

# Ubuntu/Debian
sudo apt-get install nmap jq kafkacat
```

### End-to-End (with test cluster)

```bash
cd kafka-vapt

# Start local Kafka cluster + run scan + generate report
./run-e2e-vapt.sh

# Keep cluster running after scan
./run-e2e-vapt.sh --no-cleanup

# Skip cluster setup (use existing)
./run-e2e-vapt.sh --skip-setup
```

### Scan an Existing Cluster

```bash
# Basic scan (no auth)
./run-kafka-vapt.sh --bootstrap broker1:9092

# With multiple brokers
./run-kafka-vapt.sh --bootstrap broker1:9092 --brokers broker1:9092,broker2:9092,broker3:9092

# With SSL/TLS
./run-kafka-vapt.sh --bootstrap broker1:9093 --ssl

# With SASL authentication
./run-kafka-vapt.sh --bootstrap broker1:9092 \
  --sasl-mechanism SCRAM-SHA-256 \
  --sasl-username admin \
  --sasl-password secret

# With client.properties file
./run-kafka-vapt.sh --bootstrap broker1:9092 \
  --client-props /path/to/client.properties

# With Kafka CLI tools
./run-kafka-vapt.sh --bootstrap broker1:9092 \
  --kafka-home /opt/kafka

# Run inside Docker (no local tools needed)
./run-kafka-vapt.sh --bootstrap broker1:9092 --docker
```

### Docker Mode

Run the scanner inside Docker when you don't have tools installed locally:

```bash
# Build and run in Docker
./run-kafka-vapt.sh --bootstrap localhost:9092 --docker

# Or build manually
docker build -t kafka-vapt-scanner .
docker run --rm \
  --add-host=host.docker.internal:host-gateway \
  -v $(pwd)/reports:/reports \
  kafka-vapt-scanner \
  --bootstrap host.docker.internal:9092 --output /reports
```

## Report Output

Reports are generated in `reports/` directory:

- **HTML Report**: Interactive dashboard with collapsible categories, severity badges, and grade
- **JSON Report**: Machine-readable results for CI/CD integration

### Security Grade

| Grade | Criteria |
|-------|----------|
| **A** | No failures, no warnings |
| **B+** | No failures, 1-2 warnings |
| **B** | No failures, 3-5 warnings |
| **C** | 1 failure or 6+ warnings |
| **D** | 2-3 failures |
| **F** | 4+ failures or any critical finding |

## CI/CD Integration

### GitHub Actions

```yaml
name: Kafka VAPT Scan
on:
  schedule:
    - cron: '0 6 * * 1'  # Weekly Monday 6am
  workflow_dispatch:

jobs:
  vapt-scan:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Install tools
        run: |
          sudo apt-get update
          sudo apt-get install -y nmap jq kafkacat

      - name: Start test cluster
        run: |
          cd kafka-vapt
          docker compose -f docker-compose.kafka-test.yml up -d
          sleep 30

      - name: Run VAPT scan
        run: |
          cd kafka-vapt
          chmod +x run-kafka-vapt.sh
          ./run-kafka-vapt.sh --bootstrap localhost:9092 --format both

      - name: Check results
        run: |
          GRADE=$(jq -r '.summary.grade' kafka-vapt/reports/*-results.json | tail -1)
          FAILS=$(jq '.summary.fail' kafka-vapt/reports/*-results.json | tail -1)
          echo "Grade: $GRADE, Failures: $FAILS"
          if [ "$FAILS" -gt 0 ]; then
            echo "::warning::VAPT scan found $FAILS failures (Grade: $GRADE)"
          fi

      - name: Upload reports
        uses: actions/upload-artifact@v4
        with:
          name: kafka-vapt-report
          path: kafka-vapt/reports/

      - name: Cleanup
        if: always()
        run: |
          cd kafka-vapt
          docker compose -f docker-compose.kafka-test.yml down -v
```

## File Structure

```
kafka-vapt/
├── run-kafka-vapt.sh              # Main VAPT scanner script
├── run-e2e-vapt.sh                # End-to-end runner (cluster + scan)
├── docker-compose.kafka-test.yml  # 3-broker KRaft test cluster
├── Dockerfile                     # Scanner Docker image
├── README.md                      # This file
├── checks/                        # Additional check modules (extensible)
├── templates/                     # Report templates
└── reports/                       # Generated reports (gitignored)
    ├── *-report.html              # HTML dashboard report
    └── *-results.json             # Machine-readable JSON results
```

## Extending

Add custom checks by following the pattern in `run-kafka-vapt.sh`:

```bash
add_finding "CUSTOM-001" "Custom Category" "Check title" "MEDIUM" "WARN" \
    "Description of what was found." \
    "Recommendation for remediation." \
    "Raw output details"
```

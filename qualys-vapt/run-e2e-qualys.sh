#!/usr/bin/env bash
###############################################################################
# Qualys CE - End-to-End Kafka VAPT Pipeline
# =============================================
# Starts test Kafka cluster → Guides Qualys CE scan → Collects results
#
# Usage:
#   ./run-e2e-qualys.sh              # Full pipeline
#   ./run-e2e-qualys.sh --no-cluster # Skip cluster startup (already running)
#   ./run-e2e-qualys.sh --cleanup    # Just tear down the cluster
###############################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.qualys-test.yml"
REPORT_DIR="${SCRIPT_DIR}/reports"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
log_step()  { echo -e "${BLUE}[STEP]${NC}  $*"; }

SKIP_CLUSTER=false
CLEANUP_ONLY=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-cluster) SKIP_CLUSTER=true; shift ;;
        --cleanup)    CLEANUP_ONLY=true; shift ;;
        *)            shift ;;
    esac
done

cleanup() {
    log_step "Tearing down test cluster..."
    docker compose -f "$COMPOSE_FILE" down -v --remove-orphans 2>/dev/null || true
    log_info "Cleanup complete"
}

# Cleanup-only mode
if [[ "$CLEANUP_ONLY" == true ]]; then
    cleanup
    exit 0
fi

echo -e "${CYAN}"
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║       Qualys CE - End-to-End Kafka VAPT Pipeline               ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

# Trap for cleanup
trap 'echo ""; log_warn "Interrupted. Run ./run-e2e-qualys.sh --cleanup to tear down."' INT TERM

mkdir -p "$REPORT_DIR"

# ── Step 1: Start Kafka Cluster ──────────────────────────────────────────
if [[ "$SKIP_CLUSTER" == false ]]; then
    log_step "Step 1: Starting Kafka test cluster..."
    docker compose -f "$COMPOSE_FILE" down -v --remove-orphans 2>/dev/null || true
    docker compose -f "$COMPOSE_FILE" up -d

    # Wait for brokers
    log_step "Waiting for Kafka brokers to be ready..."
    local_timeout=120
    elapsed=0
    while [[ $elapsed -lt $local_timeout ]]; do
        healthy=0
        for broker in qualys-kafka-1 qualys-kafka-2 qualys-kafka-3; do
            if docker inspect "$broker" 2>/dev/null | grep -q '"Status": "healthy"'; then
                healthy=$((healthy + 1))
            fi
        done

        if [[ $healthy -ge 3 ]]; then
            log_info "All 3 brokers healthy!"
            break
        fi

        echo -ne "\r  Brokers ready: ${healthy}/3 (${elapsed}s / ${local_timeout}s)"
        sleep 5
        elapsed=$((elapsed + 5))
    done
    echo ""

    if [[ $elapsed -ge $local_timeout ]]; then
        log_error "Timeout waiting for brokers. Check: docker compose -f $COMPOSE_FILE logs"
        exit 1
    fi

    # Wait for ksqlDB
    log_step "Waiting for ksqlDB..."
    elapsed=0
    ksql_timeout=90
    while [[ $elapsed -lt $ksql_timeout ]]; do
        if curl -sf http://localhost:18088/info &>/dev/null; then
            log_info "ksqlDB is ready!"
            break
        fi
        echo -ne "\r  Waiting for ksqlDB... (${elapsed}s / ${ksql_timeout}s)"
        sleep 5
        elapsed=$((elapsed + 5))
    done
    echo ""

    # Create test data
    log_step "Creating test topics and streams..."
    docker exec qualys-kafka-1 /opt/kafka/bin/kafka-topics.sh \
        --bootstrap-server kafka-1:9092 \
        --create --topic qualys-test-topic \
        --partitions 3 --replication-factor 3 2>/dev/null || true

    curl -sf -X POST http://localhost:18088/ksql \
        -H "Content-Type: application/vnd.ksql.v1+json" \
        -d '{"ksql": "CREATE STREAM IF NOT EXISTS qualys_test_stream (id VARCHAR, data VARCHAR) WITH (KAFKA_TOPIC='\''qualys-test-topic'\'', VALUE_FORMAT='\''JSON'\'', PARTITIONS=3);"}' \
        >/dev/null 2>&1 || true

    log_info "Test data created"
else
    log_info "Skipping cluster startup (--no-cluster)"
fi

# ── Step 2: Display Target Information ───────────────────────────────────
echo ""
log_step "Step 2: Target Cluster Information"
echo ""
echo -e "${BOLD}Container IPs:${NC}"
for container in qualys-kafka-1 qualys-kafka-2 qualys-kafka-3 qualys-ksqldb; do
    ip=$(docker inspect "$container" 2>/dev/null | jq -r '.[0].NetworkSettings.Networks | to_entries[0].value.IPAddress' 2>/dev/null || echo "N/A")
    ports=$(docker port "$container" 2>/dev/null | head -3 || echo "N/A")
    echo -e "  ${CYAN}${container}${NC}: ${ip}"
    echo "    Ports: ${ports}" | head -2
done
echo ""

# ── Step 3: Run Qualys Scan ──────────────────────────────────────────────
log_step "Step 3: Qualys CE Vulnerability Scan"
echo ""
echo "Choose scan method:"
echo "  1) API-based scan (requires paid/trial Qualys account)"
echo "  2) Manual scan guidance (works with free CE tier)"
echo ""

read -rp "Enter choice (1 or 2) [2]: " scan_choice
scan_choice=${scan_choice:-2}

case "$scan_choice" in
    1)
        "${SCRIPT_DIR}/run-qualys-vapt.sh" --scan
        ;;
    2)
        "${SCRIPT_DIR}/run-qualys-vapt.sh" --scan --manual
        ;;
esac

# ── Step 4: Summary ──────────────────────────────────────────────────────
echo ""
log_step "Step 4: Pipeline Summary"
echo ""
echo -e "${BOLD}Test Cluster:${NC}"
echo "  Kafka Brokers: 3 (KRaft mode)"
echo "  ksqlDB: 1 instance"
echo "  Network: qualys-vapt_kafka-qualys-net (172.28.0.0/16)"
echo ""
echo -e "${BOLD}Scan Targets:${NC}"
echo "  172.28.0.10 (kafka-1) - Ports: 9092, 9093"
echo "  172.28.0.11 (kafka-2) - Ports: 9092, 9093"
echo "  172.28.0.12 (kafka-3) - Ports: 9092, 9093"
echo "  172.28.0.20 (ksqldb)  - Port:  8088"
echo ""
echo -e "${BOLD}Reports:${NC}"
ls -la "${REPORT_DIR}/"* 2>/dev/null || echo "  No reports yet. Complete the scan in Qualys portal."
echo ""
echo -e "${BOLD}Next Steps:${NC}"
echo "  1. Complete scan in Qualys portal (if using manual mode)"
echo "  2. Download report from Qualys portal"
echo "  3. Save report to: ${REPORT_DIR}/"
echo "  4. Cleanup: ./run-e2e-qualys.sh --cleanup"
echo ""
echo -e "${GREEN}Pipeline complete!${NC}"

#!/usr/bin/env bash
###############################################################################
# End-to-End Kafka VAPT Scanner
#
# This script:
#   1. Starts a local 3-broker KRaft Kafka cluster (Docker)
#   2. Creates sample topics for testing
#   3. Runs the full VAPT scan
#   4. Generates HTML + JSON reports
#   5. Optionally tears down the cluster
#
# Usage:
#   ./run-e2e-vapt.sh              # Full e2e run
#   ./run-e2e-vapt.sh --no-cleanup # Keep cluster running after scan
#   ./run-e2e-vapt.sh --skip-setup # Skip cluster setup (use existing)
###############################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.kafka-test.yml"
BOOTSTRAP="localhost:9092"
CLEANUP=true
SKIP_SETUP=false

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_fail()  { echo -e "${RED}[FAIL]${NC}  $*"; }
log_step()  { echo -e "\n${CYAN}▶ $*${NC}\n"; }

# Parse args
for arg in "$@"; do
    case "$arg" in
        --no-cleanup) CLEANUP=false ;;
        --skip-setup) SKIP_SETUP=true ;;
        --help|-h)
            echo "Usage: $0 [--no-cleanup] [--skip-setup]"
            echo "  --no-cleanup  Keep Kafka cluster running after scan"
            echo "  --skip-setup  Skip cluster startup (use existing)"
            exit 0
            ;;
    esac
done

# Cleanup handler
cleanup() {
    if [[ "$CLEANUP" == true ]] && [[ "$SKIP_SETUP" == false ]]; then
        log_step "Cleaning up Kafka cluster..."
        docker compose -f "$COMPOSE_FILE" down -v 2>/dev/null || true
        log_ok "Cluster stopped and volumes removed"
    fi
}

trap cleanup EXIT

###############################################################################
# Step 1: Check prerequisites
###############################################################################
log_step "Step 1: Checking prerequisites"

if ! command -v docker &>/dev/null; then
    log_fail "Docker is required but not installed"
    exit 1
fi
log_ok "Docker found"

if ! docker info &>/dev/null 2>&1; then
    log_fail "Docker daemon is not running"
    exit 1
fi
log_ok "Docker daemon running"

# Check for required tools (install hints)
for tool in nmap jq; do
    if command -v "$tool" &>/dev/null; then
        log_ok "$tool found"
    else
        log_warn "$tool not found - install with: brew install $tool (macOS) or apt install $tool (Linux)"
    fi
done

if command -v kcat &>/dev/null || command -v kafkacat &>/dev/null; then
    log_ok "kcat found"
else
    log_warn "kcat not found - install with: brew install kcat (macOS) or apt install kafkacat (Linux)"
fi

###############################################################################
# Step 2: Start Kafka cluster
###############################################################################
if [[ "$SKIP_SETUP" == false ]]; then
    log_step "Step 2: Starting 3-broker KRaft Kafka cluster"

    # Stop any existing cluster
    docker compose -f "$COMPOSE_FILE" down -v 2>/dev/null || true

    # Start cluster
    docker compose -f "$COMPOSE_FILE" up -d
    log_ok "Containers started"

    # Wait for Kafka to be ready
    log_info "Waiting for Kafka brokers to be ready..."
    MAX_WAIT=120
    WAIT=0
    while [[ $WAIT -lt $MAX_WAIT ]]; do
        if docker exec kafka-vapt-1 /opt/kafka/bin/kafka-metadata.sh --snapshot /tmp/kraft-combined-logs/__cluster_metadata-0/00000000000000000000.log --cluster-id MkU3OEVBNTcwNTJENDM2Qk 2>&1 | grep -q "MetadataRecordCount" 2>/dev/null; then
            break
        fi

        # Alternative: try connecting with a simple metadata request
        if command -v kcat &>/dev/null; then
            if kcat -b "$BOOTSTRAP" -L 2>/dev/null | grep -q "broker"; then
                break
            fi
        fi

        # Basic port check fallback
        if nc -z localhost 9092 2>/dev/null; then
            sleep 5
            break
        fi

        sleep 2
        WAIT=$((WAIT + 2))
        echo -ne "\r  Waiting... ${WAIT}s / ${MAX_WAIT}s"
    done
    echo ""

    if [[ $WAIT -ge $MAX_WAIT ]]; then
        log_fail "Kafka cluster did not start within ${MAX_WAIT}s"
        docker compose -f "$COMPOSE_FILE" logs --tail=50
        exit 1
    fi

    log_ok "Kafka cluster is ready"

    # Create test topics
    log_info "Creating test topics..."
    docker exec kafka-vapt-1 /opt/kafka/bin/kafka-topics.sh \
        --bootstrap-server kafka-1:9092 \
        --create --topic test-topic \
        --partitions 3 --replication-factor 3 \
        2>/dev/null || true

    docker exec kafka-vapt-1 /opt/kafka/bin/kafka-topics.sh \
        --bootstrap-server kafka-1:9092 \
        --create --topic user-events \
        --partitions 2 --replication-factor 3 \
        2>/dev/null || true

    docker exec kafka-vapt-1 /opt/kafka/bin/kafka-topics.sh \
        --bootstrap-server kafka-1:9092 \
        --create --topic payment-transactions \
        --partitions 3 --replication-factor 3 \
        2>/dev/null || true

    log_ok "Test topics created"

    # Produce some test messages
    log_info "Producing test messages..."
    echo '{"user":"test","action":"login"}' | docker exec -i kafka-vapt-1 /opt/kafka/bin/kafka-console-producer.sh \
        --bootstrap-server kafka-1:9092 --topic test-topic 2>/dev/null || true
    log_ok "Test messages produced"

else
    log_step "Step 2: Skipping cluster setup (--skip-setup)"
    log_info "Using existing cluster at $BOOTSTRAP"
fi

###############################################################################
# Step 3: Run VAPT scan
###############################################################################
log_step "Step 3: Running Kafka VAPT Scan"

chmod +x "${SCRIPT_DIR}/run-kafka-vapt.sh"

"${SCRIPT_DIR}/run-kafka-vapt.sh" \
    --bootstrap "$BOOTSTRAP" \
    --output "${SCRIPT_DIR}/reports" \
    --format both

###############################################################################
# Step 4: Show results
###############################################################################
log_step "Step 4: Results"

# Find latest report
LATEST_REPORT=$(ls -t "${SCRIPT_DIR}"/reports/*-report.html 2>/dev/null | head -1)
LATEST_JSON=$(ls -t "${SCRIPT_DIR}"/reports/*-results.json 2>/dev/null | head -1)

if [[ -n "$LATEST_REPORT" ]]; then
    log_ok "HTML Report: $LATEST_REPORT"
    echo ""

    # Print summary from JSON
    if [[ -n "$LATEST_JSON" ]]; then
        echo -e "  ${CYAN}═══ Scan Summary ═══${NC}"
        echo -e "  Grade:     $(jq -r '.summary.grade' "$LATEST_JSON")"
        echo -e "  Total:     $(jq '.summary.total' "$LATEST_JSON") checks"
        echo -e "  ${GREEN}Passed:    $(jq '.summary.pass' "$LATEST_JSON")${NC}"
        echo -e "  ${RED}Failed:    $(jq '.summary.fail' "$LATEST_JSON")${NC}"
        echo -e "  ${YELLOW}Warnings:  $(jq '.summary.warn' "$LATEST_JSON")${NC}"
        echo -e "  Critical:  $(jq '.summary.critical' "$LATEST_JSON")"
        echo -e "  High:      $(jq '.summary.high' "$LATEST_JSON")"
        echo -e "  Medium:    $(jq '.summary.medium' "$LATEST_JSON")"
        echo -e "  Low:       $(jq '.summary.low' "$LATEST_JSON")"
        echo ""
    fi

    # Try to open report in browser
    if command -v open &>/dev/null; then
        log_info "Opening HTML report in browser..."
        open "$LATEST_REPORT"
    elif command -v xdg-open &>/dev/null; then
        log_info "Opening HTML report in browser..."
        xdg-open "$LATEST_REPORT"
    else
        log_info "Open in browser: file://$LATEST_REPORT"
    fi
else
    log_warn "No HTML report found"
fi

echo ""
if [[ "$CLEANUP" == true ]] && [[ "$SKIP_SETUP" == false ]]; then
    log_info "Kafka cluster will be stopped on exit"
else
    log_info "Kafka cluster is still running at $BOOTSTRAP"
    log_info "Stop with: docker compose -f $COMPOSE_FILE down -v"
fi

echo ""
log_ok "Kafka VAPT scan complete!"

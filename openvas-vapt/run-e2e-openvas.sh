#!/usr/bin/env bash
###############################################################################
# OpenVAS (Greenbone) - End-to-End Kafka VAPT Pipeline
# ======================================================
# Starts Kafka cluster + OpenVAS → Syncs feeds → Scans → Reports
#
# Usage:
#   ./run-e2e-openvas.sh              # Full pipeline
#   ./run-e2e-openvas.sh --no-cluster # Skip cluster startup
#   ./run-e2e-openvas.sh --cleanup    # Tear down everything
###############################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.openvas-test.yml"
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
    log_step "Tearing down all containers and volumes..."
    docker compose -f "$COMPOSE_FILE" down -v --remove-orphans 2>/dev/null || true
    log_info "Cleanup complete"
}

if [[ "$CLEANUP_ONLY" == true ]]; then
    cleanup
    exit 0
fi

echo -e "${CYAN}"
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║       OpenVAS (Greenbone) - End-to-End Kafka VAPT Pipeline     ║"
echo "║       100% Open-Source | 80,000+ Vulnerability Tests           ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

trap 'echo ""; log_warn "Interrupted. Run ./run-e2e-openvas.sh --cleanup to tear down."' INT TERM

mkdir -p "$REPORT_DIR"

# ── Step 1: Start Everything ─────────────────────────────────────────────
if [[ "$SKIP_CLUSTER" == false ]]; then
    log_step "Step 1: Starting Kafka cluster + OpenVAS stack..."
    echo "  This starts 12+ containers. First run downloads ~5GB of images."
    echo ""

    docker compose -f "$COMPOSE_FILE" down -v --remove-orphans 2>/dev/null || true
    docker compose -f "$COMPOSE_FILE" up -d

    # Wait for Kafka brokers
    log_step "Waiting for Kafka brokers..."
    timeout_sec=120
    elapsed=0
    while [[ $elapsed -lt $timeout_sec ]]; do
        healthy=0
        for broker in openvas-kafka-1 openvas-kafka-2 openvas-kafka-3; do
            if docker inspect "$broker" 2>/dev/null | grep -q '"Status": "healthy"'; then
                healthy=$((healthy + 1))
            fi
        done
        if [[ $healthy -ge 3 ]]; then
            log_info "All 3 Kafka brokers healthy!"
            break
        fi
        echo -ne "\r  Brokers: ${healthy}/3 ready (${elapsed}s)"
        sleep 5
        elapsed=$((elapsed + 5))
    done
    echo ""

    # Wait for ksqlDB
    log_step "Waiting for ksqlDB..."
    elapsed=0
    while [[ $elapsed -lt 90 ]]; do
        if curl -sf http://localhost:28088/info &>/dev/null; then
            log_info "ksqlDB ready!"
            break
        fi
        echo -ne "\r  ksqlDB: waiting... (${elapsed}s)"
        sleep 5
        elapsed=$((elapsed + 5))
    done
    echo ""

    # Create test data
    log_step "Creating test topics..."
    docker exec openvas-kafka-1 /opt/kafka/bin/kafka-topics.sh \
        --bootstrap-server kafka-1:9092 \
        --create --topic openvas-test-topic \
        --partitions 3 --replication-factor 3 2>/dev/null || true
    log_info "Test topic created"

    # Wait for OpenVAS to be ready
    log_step "Waiting for OpenVAS feed synchronization..."
    echo "  This takes 10-15 minutes on first startup."
    echo "  OpenVAS downloads 80,000+ vulnerability tests."
    echo ""

    elapsed=0
    max_openvas_wait=900  # 15 min
    while [[ $elapsed -lt $max_openvas_wait ]]; do
        # Check if gvmd is responding
        if docker exec openvas-gvm-tools gvm-cli \
            --gmp-username admin --gmp-password admin \
            socket --socketpath /run/ospd/gvmd.sock \
            --xml '<get_version/>' 2>/dev/null | grep -q "status=\"200\""; then
            log_info "OpenVAS GMP API is responding!"
            break
        fi

        elapsed_min=$((elapsed / 60))
        echo -ne "\r  OpenVAS initializing... ${elapsed_min}m ${elapsed}s / 15m"
        sleep 15
        elapsed=$((elapsed + 15))
    done
    echo ""

    if [[ $elapsed -ge $max_openvas_wait ]]; then
        log_warn "OpenVAS may still be initializing. Proceeding anyway..."
    fi

else
    log_info "Skipping cluster startup (--no-cluster)"
fi

# ── Step 2: Display Environment ──────────────────────────────────────────
echo ""
log_step "Step 2: Environment Overview"
echo ""
echo -e "${BOLD}Kafka Cluster:${NC}"
for container in openvas-kafka-1 openvas-kafka-2 openvas-kafka-3 openvas-ksqldb; do
    ip=$(docker inspect "$container" 2>/dev/null | jq -r '.[0].NetworkSettings.Networks | to_entries[0].value.IPAddress' 2>/dev/null || echo "N/A")
    echo -e "  ${CYAN}${container}${NC}: ${ip}"
done
echo ""
echo -e "${BOLD}OpenVAS Stack:${NC}"
for container in openvas-scanner openvas-gvmd openvas-gsad openvas-ospd openvas-postgres openvas-redis; do
    status=$(docker inspect --format='{{.State.Status}}' "$container" 2>/dev/null || echo "not found")
    if [[ "$status" == "running" ]]; then
        echo -e "  ${GREEN}✓${NC} $container: running"
    else
        echo -e "  ${RED}✗${NC} $container: $status"
    fi
done
echo ""
echo -e "${BOLD}Web UI:${NC} https://localhost:9443 (admin/admin)"
echo ""

# ── Step 3: Run Scan ─────────────────────────────────────────────────────
log_step "Step 3: Running OpenVAS vulnerability scan..."
echo ""

"${SCRIPT_DIR}/run-openvas-vapt.sh" --full 2>&1 || {
    log_warn "Scan may have failed. Check: ./run-openvas-vapt.sh --status"
}

# ── Step 4: Summary ──────────────────────────────────────────────────────
echo ""
log_step "Step 4: Pipeline Summary"
echo ""
echo -e "${BOLD}Infrastructure:${NC}"
echo "  Kafka: 3 brokers (KRaft mode) + ksqlDB"
echo "  OpenVAS: Greenbone CE (full open-source scanner)"
echo "  Network: 172.29.0.0/16"
echo ""
echo -e "${BOLD}Scan Targets:${NC}"
echo "  172.29.0.10 (kafka-1) - Ports: 9092, 9093"
echo "  172.29.0.11 (kafka-2) - Ports: 9092, 9093"
echo "  172.29.0.12 (kafka-3) - Ports: 9092, 9093"
echo "  172.29.0.20 (ksqldb)  - Port:  8088"
echo ""
echo -e "${BOLD}Reports:${NC}"
ls -lh "${REPORT_DIR}"/*.* 2>/dev/null || echo "  Check ${REPORT_DIR}/"
echo ""
echo -e "${BOLD}Access Points:${NC}"
echo "  OpenVAS Web UI:  https://localhost:9443 (admin/admin)"
echo "  Kafka Brokers:   localhost:29092, :29094, :29096"
echo "  ksqlDB:          http://localhost:28088"
echo ""
echo -e "${BOLD}Cleanup:${NC}"
echo "  ./run-e2e-openvas.sh --cleanup"
echo ""
echo -e "${GREEN}Pipeline complete!${NC}"

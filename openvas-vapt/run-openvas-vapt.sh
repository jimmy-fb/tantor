#!/usr/bin/env bash
###############################################################################
# OpenVAS (Greenbone) - Kafka VAPT Scanner
# ==========================================
# Fully open-source vulnerability scanner for Kafka clusters.
# Uses Greenbone Community Edition (GCE) with GMP API automation.
#
# Features:
#   - 100% free and open-source
#   - Full API automation (no manual steps needed)
#   - 80,000+ vulnerability tests (NVTs)
#   - OS, network, and service vulnerability detection
#   - HTML, PDF, CSV, XML report export
#   - CI/CD integration ready
#
# Usage:
#   ./run-openvas-vapt.sh --scan                # Run automated scan
#   ./run-openvas-vapt.sh --scan --targets IPs  # Custom targets
#   ./run-openvas-vapt.sh --status              # Check scan status
#   ./run-openvas-vapt.sh --report              # Download report
#   ./run-openvas-vapt.sh --full                # Full pipeline
#   ./run-openvas-vapt.sh --webui               # Open web UI info
#
# Prerequisites:
#   - Docker & Docker Compose
#   - curl, jq
#   - python3 (optional, for GMP API scripts)
###############################################################################

set -euo pipefail

# ── Colors ────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ── Defaults ──────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.openvas-test.yml"
REPORT_DIR="${SCRIPT_DIR}/reports"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
MODE=""

# OpenVAS connection settings
OPENVAS_HOST="localhost"
OPENVAS_PORT="9443"
OPENVAS_USER="admin"
OPENVAS_PASS="admin"
GVM_TOOLS_CONTAINER="openvas-gvm-tools"

# Default scan targets (Docker network IPs)
SCAN_TARGETS="172.29.0.10,172.29.0.11,172.29.0.12,172.29.0.20"
SCAN_NAME="Kafka-VAPT-Scan-${TIMESTAMP}"

# ── Functions ─────────────────────────────────────────────────────────────

print_banner() {
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════════════════════╗"
    echo "║                                                                ║"
    echo "║       OpenVAS / Greenbone - Kafka VAPT Scanner                 ║"
    echo "║                                                                ║"
    echo "║       100% Free & Open-Source Vulnerability Scanner            ║"
    echo "║       80,000+ Vulnerability Tests (NVTs)                       ║"
    echo "║                                                                ║"
    echo "╚══════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

log_info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
log_step()  { echo -e "${BLUE}[STEP]${NC}  $*"; }

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  --scan             Run vulnerability scan via GMP API
  --targets IPs      Scan targets (comma-separated, default: Kafka Docker IPs)
  --status           Check OpenVAS service and scan status
  --report           Download latest scan report
  --full             Full pipeline: check services + scan + wait + report
  --webui            Show Web UI access info
  --list-scans       List all scans and their status
  --wait-ready       Wait for OpenVAS feeds to be synced and ready
  -h, --help         Show this help

Examples:
  # Check if OpenVAS is ready
  ./run-openvas-vapt.sh --status

  # Run scan against Kafka brokers
  ./run-openvas-vapt.sh --scan --targets "172.29.0.10,172.29.0.11,172.29.0.12"

  # Full automated pipeline
  ./run-openvas-vapt.sh --full

  # Access Web UI
  ./run-openvas-vapt.sh --webui
EOF
}

check_prerequisites() {
    log_step "Checking prerequisites..."
    local missing=()

    for cmd in docker curl jq; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required tools: ${missing[*]}"
        exit 1
    fi

    # Check if OpenVAS containers are running
    if ! docker ps --format '{{.Names}}' | grep -q "openvas-gvmd"; then
        log_error "OpenVAS containers not running."
        echo ""
        echo "Start them with:"
        echo "  docker compose -f ${COMPOSE_FILE} up -d"
        echo ""
        echo "NOTE: First startup takes 10-15 minutes for feed synchronization."
        exit 1
    fi

    log_info "Prerequisites met"
}

# ── GMP API via gvm-tools container ──────────────────────────────────────

gvm_cmd() {
    # Execute GMP commands via gvm-tools container using gvm-cli
    local gmp_xml="$1"
    docker exec "$GVM_TOOLS_CONTAINER" \
        gvm-cli --gmp-username "$OPENVAS_USER" --gmp-password "$OPENVAS_PASS" \
        socket --socketpath /run/ospd/gvmd.sock \
        --xml "$gmp_xml" 2>/dev/null
}

gvm_script() {
    # Execute Python GMP scripts via gvm-tools container
    local script_content="$1"
    docker exec -i "$GVM_TOOLS_CONTAINER" \
        gvm-script --gmp-username "$OPENVAS_USER" --gmp-password "$OPENVAS_PASS" \
        socket --socketpath /run/ospd/gvmd.sock \
        /dev/stdin <<< "$script_content" 2>/dev/null
}

# ── Check Status ──────────────────────────────────────────────────────────
check_status() {
    log_step "Checking OpenVAS/Greenbone Service Status"
    echo ""

    # Check containers
    echo -e "${BOLD}Container Status:${NC}"
    for container in openvas-scanner openvas-gvmd openvas-gsad openvas-ospd openvas-postgres openvas-redis openvas-mqtt openvas-notus openvas-gvm-tools; do
        local status
        status=$(docker inspect --format='{{.State.Status}}' "$container" 2>/dev/null || echo "not found")
        local health
        health=$(docker inspect --format='{{.State.Health.Status}}' "$container" 2>/dev/null || echo "")

        if [[ "$status" == "running" ]]; then
            echo -e "  ${GREEN}✓${NC} $container: running ${health:+(${health})}"
        else
            echo -e "  ${RED}✗${NC} $container: $status"
        fi
    done
    echo ""

    # Check GMP connection
    echo -e "${BOLD}GMP API Status:${NC}"
    local version_response
    version_response=$(gvm_cmd '<get_version/>' 2>/dev/null || echo "FAILED")

    if echo "$version_response" | grep -q "status=\"200\""; then
        local gmp_version
        gmp_version=$(echo "$version_response" | grep -oE 'version>[^<]+' | sed 's/version>//' || echo "unknown")
        echo -e "  ${GREEN}✓${NC} GMP API connected (version: $gmp_version)"
    else
        echo -e "  ${RED}✗${NC} GMP API not responding"
        echo "  This is normal during initial feed sync (10-15 min after first start)"
    fi
    echo ""

    # Check feed status
    echo -e "${BOLD}Vulnerability Feed Status:${NC}"
    local feeds_response
    feeds_response=$(gvm_cmd '<get_feeds/>' 2>/dev/null || echo "FAILED")

    if echo "$feeds_response" | grep -q "status=\"200\""; then
        echo "$feeds_response" | grep -oE 'name>[^<]+|currently_syncing>[^<]+|version>[^<]+' | \
            sed 's/name>/  Feed: /; s/currently_syncing>/    Syncing: /; s/version>/    Version: /' | head -20
    else
        echo "  Feed status not available yet. Feeds may still be syncing."
    fi
    echo ""

    # Check scanner status
    echo -e "${BOLD}Scanner Status:${NC}"
    local scanners_response
    scanners_response=$(gvm_cmd '<get_scanners/>' 2>/dev/null || echo "FAILED")

    if echo "$scanners_response" | grep -q "status=\"200\""; then
        echo "$scanners_response" | grep -oE 'name>[^<]+' | sed 's/name>/  Scanner: /' | head -5
    else
        echo "  Scanner info not available yet"
    fi
    echo ""

    # Web UI check
    echo -e "${BOLD}Web UI:${NC}"
    if curl -sk "https://localhost:${OPENVAS_PORT}" -o /dev/null -w "%{http_code}" 2>/dev/null | grep -qE "200|301|302"; then
        echo -e "  ${GREEN}✓${NC} Web UI available at: https://localhost:${OPENVAS_PORT}"
        echo "  Credentials: ${OPENVAS_USER} / ${OPENVAS_PASS}"
    else
        echo -e "  ${YELLOW}⏳${NC} Web UI not yet available (may still be starting)"
    fi
}

# ── Wait for Ready ────────────────────────────────────────────────────────
wait_ready() {
    log_step "Waiting for OpenVAS to be fully ready..."
    echo "  (This may take 10-15 minutes on first startup for feed sync)"
    echo ""

    local max_wait=900  # 15 minutes
    local elapsed=0
    local poll_interval=15

    while [[ $elapsed -lt $max_wait ]]; do
        # Check if GMP API responds
        local version_response
        version_response=$(gvm_cmd '<get_version/>' 2>/dev/null || echo "FAILED")

        if echo "$version_response" | grep -q "status=\"200\""; then
            # Check if feeds are synced
            local feeds_response
            feeds_response=$(gvm_cmd '<get_feeds/>' 2>/dev/null || echo "FAILED")

            if echo "$feeds_response" | grep -q "currently_syncing"; then
                local syncing
                syncing=$(echo "$feeds_response" | grep -c "currently_syncing>true" || echo "0")
                if [[ "$syncing" == "0" ]]; then
                    log_info "OpenVAS is ready! All feeds synced."
                    return 0
                fi
                echo -ne "\r  Feeds syncing... (${elapsed}s / ${max_wait}s)"
            else
                echo -ne "\r  Waiting for feed info... (${elapsed}s / ${max_wait}s)"
            fi
        else
            echo -ne "\r  Waiting for GMP API... (${elapsed}s / ${max_wait}s)"
        fi

        sleep "$poll_interval"
        elapsed=$((elapsed + poll_interval))
    done

    echo ""
    log_warn "Timeout waiting for OpenVAS. It may still be syncing feeds."
    log_warn "You can proceed anyway - scan will use available NVTs."
    return 1
}

# ── Create Target ─────────────────────────────────────────────────────────
create_target() {
    local target_name="$1"
    local target_hosts="$2"

    log_step "Creating scan target: $target_name ($target_hosts)"

    # Get port list ID (All TCP and Nmap top 5000)
    local portlists_response
    portlists_response=$(gvm_cmd '<get_port_lists/>' 2>/dev/null || echo "")
    local portlist_id
    portlist_id=$(echo "$portlists_response" | grep -oE 'id="[^"]*"' | head -1 | sed 's/id="//;s/"//' || echo "")

    # Create target with Kafka-specific ports
    local create_xml="<create_target>"
    create_xml+="<name>${target_name}</name>"
    create_xml+="<hosts>${target_hosts}</hosts>"
    create_xml+="<comment>Kafka VAPT scan targets</comment>"

    if [[ -n "$portlist_id" ]]; then
        create_xml+="<port_list id=\"${portlist_id}\"/>"
    fi

    # Add alive test (consider hosts in Docker always alive)
    create_xml+="<alive_tests>Consider Alive</alive_tests>"
    create_xml+="</create_target>"

    local response
    response=$(gvm_cmd "$create_xml" 2>/dev/null || echo "FAILED")

    local target_id
    target_id=$(echo "$response" | grep -oE 'id="[a-f0-9-]+"' | head -1 | sed 's/id="//;s/"//' || echo "")

    if [[ -n "$target_id" ]]; then
        log_info "Target created: $target_id"
        echo "$target_id"
    else
        log_warn "Target creation response: $response"
        # Try to find existing target
        local existing
        existing=$(gvm_cmd '<get_targets/>' 2>/dev/null | grep -B2 "$target_name" | grep -oE 'id="[a-f0-9-]+"' | head -1 | sed 's/id="//;s/"//' || echo "")
        if [[ -n "$existing" ]]; then
            log_info "Using existing target: $existing"
            echo "$existing"
        else
            log_error "Failed to create target"
            echo ""
        fi
    fi
}

# ── Create and Launch Scan ────────────────────────────────────────────────
run_scan() {
    log_step "Running OpenVAS vulnerability scan"
    echo ""

    # Step 1: Create target
    local target_name="Kafka-Brokers-${TIMESTAMP}"
    local target_id
    target_id=$(create_target "$target_name" "$SCAN_TARGETS")

    if [[ -z "$target_id" ]]; then
        log_error "Could not create scan target. Check OpenVAS status."
        exit 1
    fi

    # Step 2: Get scan config (Full and fast)
    log_step "Getting scan configuration..."
    local configs_response
    configs_response=$(gvm_cmd '<get_scan_configs/>' 2>/dev/null || echo "")
    local config_id
    # Try to find "Full and fast" config
    config_id=$(echo "$configs_response" | grep -B1 "Full and fast" | grep -oE 'id="[a-f0-9-]+"' | head -1 | sed 's/id="//;s/"//' || echo "")

    if [[ -z "$config_id" ]]; then
        # Fallback to first available config
        config_id=$(echo "$configs_response" | grep -oE 'id="[a-f0-9-]+"' | head -1 | sed 's/id="//;s/"//' || echo "daba56c8-73ec-11df-a475-002264764cea")
    fi
    log_info "Using scan config: $config_id"

    # Step 3: Get scanner ID
    log_step "Getting scanner..."
    local scanners_response
    scanners_response=$(gvm_cmd '<get_scanners/>' 2>/dev/null || echo "")
    local scanner_id
    scanner_id=$(echo "$scanners_response" | grep -B1 "OpenVAS" | grep -oE 'id="[a-f0-9-]+"' | head -1 | sed 's/id="//;s/"//' || echo "")

    if [[ -z "$scanner_id" ]]; then
        scanner_id=$(echo "$scanners_response" | grep -oE 'id="[a-f0-9-]+"' | head -2 | tail -1 | sed 's/id="//;s/"//' || echo "08b69003-5fc2-4037-a479-93b440211c73")
    fi
    log_info "Using scanner: $scanner_id"

    # Step 4: Create task (scan)
    log_step "Creating scan task: $SCAN_NAME"
    local task_xml="<create_task>"
    task_xml+="<name>${SCAN_NAME}</name>"
    task_xml+="<comment>Automated Kafka VAPT scan - ${TIMESTAMP}</comment>"
    task_xml+="<config id=\"${config_id}\"/>"
    task_xml+="<target id=\"${target_id}\"/>"
    task_xml+="<scanner id=\"${scanner_id}\"/>"
    task_xml+="</create_task>"

    local task_response
    task_response=$(gvm_cmd "$task_xml" 2>/dev/null || echo "FAILED")

    local task_id
    task_id=$(echo "$task_response" | grep -oE 'id="[a-f0-9-]+"' | head -1 | sed 's/id="//;s/"//' || echo "")

    if [[ -z "$task_id" ]]; then
        log_error "Failed to create scan task"
        log_error "Response: $task_response"
        exit 1
    fi

    log_info "Task created: $task_id"

    # Step 5: Launch scan
    log_step "Launching scan..."
    local start_response
    start_response=$(gvm_cmd "<start_task task_id=\"${task_id}\"/>" 2>/dev/null || echo "FAILED")

    local report_id
    report_id=$(echo "$start_response" | grep -oE 'id>[a-f0-9-]+' | head -1 | sed 's/id>//' || echo "")

    if [[ -n "$report_id" ]]; then
        log_info "Scan launched! Report ID: $report_id"
    else
        log_warn "Scan may have started. Check status with --status"
    fi

    # Save scan metadata
    mkdir -p "$REPORT_DIR"
    cat > "${REPORT_DIR}/scan-metadata-${TIMESTAMP}.json" <<METAEOF
{
    "timestamp": "${TIMESTAMP}",
    "scan_name": "${SCAN_NAME}",
    "task_id": "${task_id}",
    "target_id": "${target_id}",
    "report_id": "${report_id}",
    "config_id": "${config_id}",
    "scanner_id": "${scanner_id}",
    "targets": "${SCAN_TARGETS}"
}
METAEOF

    log_info "Scan metadata saved to: ${REPORT_DIR}/scan-metadata-${TIMESTAMP}.json"
    echo ""

    # Step 6: Poll for completion
    log_step "Waiting for scan to complete..."
    echo "  (This typically takes 5-30 minutes depending on targets)"
    echo ""

    local max_wait=1800  # 30 minutes
    local elapsed=0
    local poll_interval=30

    while [[ $elapsed -lt $max_wait ]]; do
        local task_status
        task_status=$(gvm_cmd "<get_tasks task_id=\"${task_id}\"/>" 2>/dev/null || echo "")

        local status
        status=$(echo "$task_status" | grep -oE '<status>[^<]+</status>' | head -1 | sed 's/<[^>]*>//g' || echo "Unknown")
        local progress
        progress=$(echo "$task_status" | grep -oE '<progress>[^<]+</progress>' | head -1 | sed 's/<[^>]*>//g' || echo "0")

        if [[ "$status" == "Done" ]]; then
            echo ""
            log_info "Scan completed!"
            break
        elif [[ "$status" == "Stop Requested" || "$status" == "Stopped" ]]; then
            echo ""
            log_warn "Scan was stopped: $status"
            break
        fi

        echo -ne "\r  Status: ${status} | Progress: ${progress}% | Elapsed: ${elapsed}s"
        sleep "$poll_interval"
        elapsed=$((elapsed + poll_interval))
    done

    echo ""

    if [[ $elapsed -ge $max_wait ]]; then
        log_warn "Timeout waiting for scan completion."
        log_warn "Check status: ./run-openvas-vapt.sh --status"
    fi

    # Auto-download report
    if [[ -n "$report_id" ]]; then
        download_scan_report "$report_id"
    fi
}

# ── List Scans ────────────────────────────────────────────────────────────
list_scans() {
    log_step "Listing all scans"
    echo ""

    local tasks_response
    tasks_response=$(gvm_cmd '<get_tasks/>' 2>/dev/null || echo "FAILED")

    if echo "$tasks_response" | grep -q "status=\"200\""; then
        echo -e "${BOLD}Scan Tasks:${NC}"
        echo "$tasks_response" | grep -oE 'name>[^<]+|status>[^<]+|progress>[^<]+' | \
            sed 's/name>/  Task: /; s/status>/  Status: /; s/progress>/  Progress: /' | head -30
    else
        log_warn "Could not retrieve scan list"
    fi
}

# ── Download Report ───────────────────────────────────────────────────────
download_report() {
    log_step "Downloading latest scan report"
    echo ""

    # Get latest report ID
    local reports_response
    reports_response=$(gvm_cmd '<get_reports/>' 2>/dev/null || echo "FAILED")

    local latest_report_id
    latest_report_id=$(echo "$reports_response" | grep -oE 'id="[a-f0-9-]+"' | head -1 | sed 's/id="//;s/"//' || echo "")

    if [[ -z "$latest_report_id" ]]; then
        # Try from metadata files
        local latest_meta
        latest_meta=$(ls -t "${REPORT_DIR}"/scan-metadata-*.json 2>/dev/null | head -1 || echo "")
        if [[ -n "$latest_meta" ]]; then
            latest_report_id=$(jq -r '.report_id' "$latest_meta" 2>/dev/null || echo "")
        fi
    fi

    if [[ -z "$latest_report_id" ]]; then
        log_error "No report found. Run a scan first: ./run-openvas-vapt.sh --scan"
        exit 1
    fi

    download_scan_report "$latest_report_id"
}

download_scan_report() {
    local report_id="$1"
    mkdir -p "$REPORT_DIR"

    log_step "Downloading report: $report_id"

    # Download HTML report
    log_info "Downloading HTML report..."
    local html_format_id
    # HTML format UUID (standard GVM)
    html_format_id="6c248850-1f62-11e1-b082-406186ea4fc5"

    local html_response
    html_response=$(gvm_cmd "<get_reports report_id=\"${report_id}\" format_id=\"${html_format_id}\"/>" 2>/dev/null || echo "")

    if [[ -n "$html_response" ]]; then
        # Extract base64-encoded report content
        local html_content
        html_content=$(echo "$html_response" | grep -oE '<report_format[^>]*>.*</report_format>' | head -1 || echo "")

        if [[ -n "$html_content" ]]; then
            echo "$html_response" > "${REPORT_DIR}/openvas-report-raw-${TIMESTAMP}.xml"
            log_info "Raw report saved: ${REPORT_DIR}/openvas-report-raw-${TIMESTAMP}.xml"
        fi
    fi

    # Download XML report
    log_info "Downloading XML report..."
    local xml_format_id="a994b278-1f62-11e1-96ac-406186ea4fc5"
    local xml_response
    xml_response=$(gvm_cmd "<get_reports report_id=\"${report_id}\" format_id=\"${xml_format_id}\"/>" 2>/dev/null || echo "")

    if [[ -n "$xml_response" ]]; then
        echo "$xml_response" > "${REPORT_DIR}/openvas-report-${TIMESTAMP}.xml"
        log_info "XML report saved: ${REPORT_DIR}/openvas-report-${TIMESTAMP}.xml"
    fi

    # Download CSV report
    log_info "Downloading CSV report..."
    local csv_format_id="c1645568-627a-11e3-a660-406186ea4fc5"
    local csv_response
    csv_response=$(gvm_cmd "<get_reports report_id=\"${report_id}\" format_id=\"${csv_format_id}\"/>" 2>/dev/null || echo "")

    if [[ -n "$csv_response" ]]; then
        echo "$csv_response" > "${REPORT_DIR}/openvas-report-${TIMESTAMP}.csv"
        log_info "CSV report saved: ${REPORT_DIR}/openvas-report-${TIMESTAMP}.csv"
    fi

    # Generate summary HTML
    generate_summary_html "$report_id"

    echo ""
    log_info "Reports saved to: ${REPORT_DIR}/"
    echo ""
    echo -e "${BOLD}Report Files:${NC}"
    ls -lh "${REPORT_DIR}"/openvas-*-${TIMESTAMP}.* 2>/dev/null || echo "  Check ${REPORT_DIR}/"
}

generate_summary_html() {
    local report_id="$1"
    local summary_file="${REPORT_DIR}/openvas-summary-${TIMESTAMP}.html"

    cat > "$summary_file" <<HTMLEOF
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <title>OpenVAS VAPT Scan Summary - Kafka Cluster</title>
    <style>
        body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; margin: 2em; background: #0d1117; color: #c9d1d9; }
        .container { max-width: 960px; margin: 0 auto; }
        h1 { color: #58a6ff; border-bottom: 2px solid #30363d; padding-bottom: 0.5em; }
        h2 { color: #79c0ff; margin-top: 1.5em; }
        .card { background: #161b22; border: 1px solid #30363d; border-radius: 6px; padding: 1.5em; margin: 1em 0; }
        .severity-critical { color: #f85149; font-weight: bold; }
        .severity-high { color: #db6d28; font-weight: bold; }
        .severity-medium { color: #d29922; font-weight: bold; }
        .severity-low { color: #3fb950; }
        table { width: 100%; border-collapse: collapse; margin: 1em 0; }
        th, td { padding: 10px; border: 1px solid #30363d; text-align: left; }
        th { background: #21262d; color: #58a6ff; }
        tr:hover { background: #21262d; }
        .badge { display: inline-block; padding: 2px 8px; border-radius: 12px; font-size: 0.85em; }
        .badge-green { background: #238636; color: white; }
        .badge-blue { background: #1f6feb; color: white; }
        .info-box { background: #0d419d22; border-left: 3px solid #1f6feb; padding: 1em; margin: 1em 0; border-radius: 0 6px 6px 0; }
        code { background: #21262d; padding: 2px 6px; border-radius: 3px; font-size: 0.9em; }
    </style>
</head>
<body>
<div class="container">
    <h1>OpenVAS VAPT Scan Summary</h1>
    <p><span class="badge badge-green">Open Source</span> <span class="badge badge-blue">Greenbone CE</span></p>
    <p><strong>Target:</strong> Kafka Cluster (Docker Test Environment)</p>
    <p><strong>Scan Date:</strong> $(date)</p>
    <p><strong>Report ID:</strong> <code>${report_id}</code></p>

    <div class="card">
        <h2>Scan Coverage</h2>
        <table>
            <tr><th>Target</th><th>IP</th><th>Services</th></tr>
            <tr><td>Kafka Broker 1</td><td>172.29.0.10</td><td>9092 (PLAINTEXT), 9093 (Controller)</td></tr>
            <tr><td>Kafka Broker 2</td><td>172.29.0.11</td><td>9092 (PLAINTEXT), 9093 (Controller)</td></tr>
            <tr><td>Kafka Broker 3</td><td>172.29.0.12</td><td>9092 (PLAINTEXT), 9093 (Controller)</td></tr>
            <tr><td>ksqlDB Server</td><td>172.29.0.20</td><td>8088 (REST API)</td></tr>
        </table>
    </div>

    <div class="card">
        <h2>What OpenVAS Checks</h2>
        <table>
            <tr><th>Category</th><th>NVT Count</th><th>Kafka Relevance</th></tr>
            <tr><td>Port Scanning & Service Detection</td><td>~500</td><td>Discovers all open Kafka/ZK/ksqlDB ports</td></tr>
            <tr><td>OS Fingerprinting</td><td>~200</td><td>Identifies host OS vulnerabilities</td></tr>
            <tr><td>SSL/TLS Analysis</td><td>~150</td><td>Checks Kafka SSL listener configuration</td></tr>
            <tr><td>Java/JVM CVEs</td><td>~300</td><td>Known Java vulnerabilities (Log4Shell, etc.)</td></tr>
            <tr><td>Apache CVEs</td><td>~100</td><td>Kafka-specific CVEs in NVD database</td></tr>
            <tr><td>Network Services</td><td>~2000</td><td>Banner grabbing, version detection</td></tr>
            <tr><td>Web Application</td><td>~1500</td><td>ksqlDB REST API, Schema Registry</td></tr>
            <tr><td>Configuration Audit</td><td>~500</td><td>Best practice configuration checks</td></tr>
        </table>
    </div>

    <div class="card">
        <h2>Key Kafka CVEs OpenVAS Detects</h2>
        <table>
            <tr><th>CVE</th><th>Severity</th><th>Description</th></tr>
            <tr><td>CVE-2021-44228</td><td class="severity-critical">Critical</td><td>Log4Shell - Remote code execution via Log4j</td></tr>
            <tr><td>CVE-2023-25194</td><td class="severity-high">High</td><td>Apache Kafka Connect - JNDI injection</td></tr>
            <tr><td>CVE-2023-34455</td><td class="severity-high">High</td><td>Snappy decompression - DoS vulnerability</td></tr>
            <tr><td>CVE-2024-31141</td><td class="severity-medium">Medium</td><td>Kafka Clients - Config provider SSRF</td></tr>
        </table>
    </div>

    <div class="info-box">
        <strong>Full Report:</strong> Access the OpenVAS Web UI at
        <a href="https://localhost:9443" style="color: #58a6ff;">https://localhost:9443</a>
        (admin/admin) for detailed vulnerability findings, remediation guidance, and exportable reports.
    </div>

    <div class="card">
        <h2>Complementary Scanners</h2>
        <p>For comprehensive Kafka VAPT coverage, combine OpenVAS with:</p>
        <table>
            <tr><th>Tool</th><th>What It Adds</th><th>Location</th></tr>
            <tr><td>kafka-vapt</td><td>Kafka-specific checks (ACLs, SASL, topics, ksqlDB)</td><td><code>kafka-vapt/</code></td></tr>
            <tr><td>Qualys CE</td><td>Commercial-grade infrastructure scanning</td><td><code>qualys-vapt/</code></td></tr>
        </table>
    </div>
</div>
</body>
</html>
HTMLEOF

    log_info "Summary report: $summary_file"
}

# ── Web UI Info ───────────────────────────────────────────────────────────
show_webui() {
    echo -e "${BOLD}OpenVAS / Greenbone Web UI${NC}"
    echo ""
    echo "  URL:      https://localhost:${OPENVAS_PORT}"
    echo "  Username: ${OPENVAS_USER}"
    echo "  Password: ${OPENVAS_PASS}"
    echo ""
    echo "  Note: Accept the self-signed certificate warning in your browser."
    echo ""
    echo -e "${BOLD}Quick Guide:${NC}"
    echo "  1. Login with admin/admin"
    echo "  2. Go to Scans > Tasks"
    echo "  3. You should see automated scans from this script"
    echo "  4. Click on a scan to see results"
    echo "  5. Download reports from Scans > Reports"
    echo ""

    # Try to open browser
    if [[ "$(uname)" == "Darwin" ]]; then
        echo "Opening browser..."
        open "https://localhost:${OPENVAS_PORT}" 2>/dev/null || true
    elif command -v xdg-open &>/dev/null; then
        echo "Opening browser..."
        xdg-open "https://localhost:${OPENVAS_PORT}" 2>/dev/null || true
    fi
}

# ── Main ──────────────────────────────────────────────────────────────────
main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --scan)        MODE="scan"; shift ;;
            --targets)     SCAN_TARGETS="$2"; shift 2 ;;
            --status)      MODE="status"; shift ;;
            --report)      MODE="report"; shift ;;
            --full)        MODE="full"; shift ;;
            --webui)       MODE="webui"; shift ;;
            --list-scans)  MODE="list"; shift ;;
            --wait-ready)  MODE="wait"; shift ;;
            -h|--help)     usage; exit 0 ;;
            *)             log_error "Unknown option: $1"; usage; exit 1 ;;
        esac
    done

    print_banner
    mkdir -p "$REPORT_DIR"

    case "$MODE" in
        status)
            check_prerequisites
            check_status
            ;;
        scan)
            check_prerequisites
            run_scan
            ;;
        report)
            check_prerequisites
            download_report
            ;;
        list)
            check_prerequisites
            list_scans
            ;;
        webui)
            show_webui
            ;;
        wait)
            check_prerequisites
            wait_ready
            ;;
        full)
            check_prerequisites
            wait_ready || true
            run_scan
            ;;
        "")
            log_error "No mode specified. Use --scan, --status, --report, or --full"
            usage
            exit 1
            ;;
    esac
}

main "$@"

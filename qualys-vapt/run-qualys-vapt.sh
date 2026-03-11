#!/usr/bin/env bash
###############################################################################
# Qualys Community Edition - Kafka VAPT Scanner
# ================================================
# Uses Qualys CE (free tier) to run vulnerability scans against Kafka clusters.
#
# Qualys CE Limitations (Free Tier):
#   - 16 internal IPs / 3 external IPs / 1 scanner appliance
#   - 3 web applications
#   - No API automation (manual scans only in free tier)
#   - Limited scan frequency
#
# This script provides:
#   1. Setup wizard for Qualys CE account
#   2. API-based scanning (requires paid/trial for full API)
#   3. Fallback: Manual scan guidance for CE free tier
#   4. Report download and parsing
#
# Usage:
#   ./run-qualys-vapt.sh --setup              # First-time setup wizard
#   ./run-qualys-vapt.sh --scan               # Run scan via API
#   ./run-qualys-vapt.sh --scan --manual      # Manual scan guidance
#   ./run-qualys-vapt.sh --report             # Download latest report
#   ./run-qualys-vapt.sh --full               # Full pipeline (setup check + scan + report)
#
# Prerequisites:
#   - curl, jq
#   - Qualys Community Edition account (free signup)
#   - Docker (for test Kafka cluster)
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
CONFIG_FILE="${SCRIPT_DIR}/config/qualys-config.env"
REPORT_DIR="${SCRIPT_DIR}/reports"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
MODE=""
MANUAL_MODE=false

# ── Qualys API variables ─────────────────────────────────────────────────
QUALYS_API_URL=""
QUALYS_USERNAME=""
QUALYS_PASSWORD=""
QUALYS_SCAN_TARGETS=""
QUALYS_SCAN_TITLE="Kafka-VAPT-Scan"
QUALYS_OPTION_PROFILE_ID=""
QUALYS_SCANNER_NAME=""
QUALYS_REPORT_FORMAT="PDF"

# ── Functions ─────────────────────────────────────────────────────────────

print_banner() {
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════════════════════╗"
    echo "║                                                                ║"
    echo "║       Qualys Community Edition - Kafka VAPT Scanner            ║"
    echo "║                                                                ║"
    echo "║       Vulnerability Assessment for Apache Kafka                ║"
    echo "║       Using Qualys Cloud Security Platform                     ║"
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
  --setup          First-time setup wizard (create config, verify account)
  --scan           Run vulnerability scan via Qualys API
  --manual         Use manual scan mode (for CE free tier without API)
  --report         Download the latest scan report
  --full           Full pipeline: setup check + scan + report
  --config FILE    Path to config file (default: config/qualys-config.env)
  --targets IPs    Override scan targets (comma-separated IPs)
  -h, --help       Show this help

Examples:
  # First time setup
  ./run-qualys-vapt.sh --setup

  # Run scan against test cluster
  ./run-qualys-vapt.sh --scan --targets "172.28.0.10,172.28.0.11,172.28.0.12"

  # Manual mode for free CE tier
  ./run-qualys-vapt.sh --scan --manual

  # Full automated pipeline
  ./run-qualys-vapt.sh --full
EOF
}

check_prerequisites() {
    log_step "Checking prerequisites..."
    local missing=()

    for cmd in curl jq; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required tools: ${missing[*]}"
        echo ""
        echo "Install them with:"
        if [[ "$(uname)" == "Darwin" ]]; then
            echo "  brew install ${missing[*]}"
        else
            echo "  sudo apt-get install -y ${missing[*]}"
        fi
        exit 1
    fi

    log_info "All prerequisites met: curl, jq"
}

load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        log_info "Loading config from $CONFIG_FILE"
        # shellcheck disable=SC1090
        source "$CONFIG_FILE"
    else
        log_warn "Config file not found: $CONFIG_FILE"
        log_warn "Run with --setup to create configuration"
    fi
}

# ── Setup Wizard ──────────────────────────────────────────────────────────
run_setup() {
    log_step "Starting Qualys Community Edition Setup Wizard"
    echo ""
    echo -e "${BOLD}Qualys Community Edition (CE) - What You Get for FREE:${NC}"
    echo "  - Scan up to 16 internal IPs and 3 external IPs"
    echo "  - 1 virtual scanner appliance"
    echo "  - Unlimited vulnerability scans"
    echo "  - Basic reporting (PDF, CSV)"
    echo ""
    echo -e "${YELLOW}Limitations of Free CE Tier:${NC}"
    echo "  - NO API access (scans must be run from web portal)"
    echo "  - Limited to 1 scanner appliance"
    echo "  - No compliance scanning (PCI, etc.)"
    echo "  - Community support only"
    echo ""
    echo -e "${BOLD}For API access (automated scans), you need:${NC}"
    echo "  - Qualys VMDR (paid) or"
    echo "  - Qualys Free Trial (30-day full API access)"
    echo ""

    # Step 1: Account creation guidance
    echo -e "${CYAN}═══ Step 1: Create Qualys CE Account ═══${NC}"
    echo ""
    echo "1. Go to: https://www.qualys.com/community-edition/"
    echo "2. Click 'Get Started Free'"
    echo "3. Fill in the registration form"
    echo "4. Verify your email"
    echo "5. Log in to your Qualys portal"
    echo ""

    read -rp "Do you already have a Qualys account? (y/n): " has_account

    if [[ "$has_account" != "y" && "$has_account" != "Y" ]]; then
        echo ""
        log_info "Please create a Qualys CE account first, then re-run --setup"
        echo "  URL: https://www.qualys.com/community-edition/"
        echo ""
        exit 0
    fi

    # Step 2: Determine platform URL
    echo ""
    echo -e "${CYAN}═══ Step 2: Identify Your Qualys Platform ═══${NC}"
    echo ""
    echo "Your Qualys platform URL depends on where your account was created:"
    echo "  1. US Platform 1:  https://qualysapi.qualys.com"
    echo "  2. US Platform 2:  https://qualysapi.qg2.apps.qualys.com"
    echo "  3. EU Platform:    https://qualysapi.qualys.eu"
    echo "  4. India Platform: https://qualysapi.qg1.apps.qualys.in"
    echo ""
    read -rp "Enter platform number (1-4) [1]: " platform_num
    platform_num=${platform_num:-1}

    case "$platform_num" in
        1) QUALYS_API_URL="https://qualysapi.qualys.com" ;;
        2) QUALYS_API_URL="https://qualysapi.qg2.apps.qualys.com" ;;
        3) QUALYS_API_URL="https://qualysapi.qualys.eu" ;;
        4) QUALYS_API_URL="https://qualysapi.qg1.apps.qualys.in" ;;
        *) QUALYS_API_URL="https://qualysapi.qualys.com" ;;
    esac

    # Step 3: Credentials
    echo ""
    echo -e "${CYAN}═══ Step 3: API Credentials ═══${NC}"
    echo ""
    read -rp "Qualys Username: " QUALYS_USERNAME
    read -srp "Qualys Password: " QUALYS_PASSWORD
    echo ""

    # Step 4: Test API connectivity
    echo ""
    log_step "Testing API connectivity..."
    local api_response
    api_response=$(curl -sS -w "\n%{http_code}" \
        -u "${QUALYS_USERNAME}:${QUALYS_PASSWORD}" \
        "${QUALYS_API_URL}/api/2.0/fo/activity_log/?action=list&truncation_limit=1" \
        -H "X-Requested-With: curl" 2>&1) || true

    local http_code
    http_code=$(echo "$api_response" | tail -1)
    local response_body
    response_body=$(echo "$api_response" | sed '$d')

    if [[ "$http_code" == "200" ]]; then
        log_info "API connection successful!"
    elif [[ "$http_code" == "401" ]]; then
        log_warn "Authentication failed (401). Check username/password."
        log_warn "Note: CE free tier may not have API access."
        echo ""
        echo "Options:"
        echo "  1. Use --manual mode for free CE tier"
        echo "  2. Sign up for Qualys Free Trial for API access"
        echo "  3. Check credentials and re-run --setup"
    elif [[ "$http_code" == "409" ]]; then
        log_warn "API access restricted (409). CE free tier doesn't include API access."
        log_warn "Use --manual mode or upgrade to trial/paid for API scanning."
    else
        log_warn "Unexpected response (HTTP $http_code)."
        log_warn "Response: $response_body"
    fi

    # Step 5: Scanner setup guidance
    echo ""
    echo -e "${CYAN}═══ Step 4: Virtual Scanner Setup ═══${NC}"
    echo ""
    echo "To scan internal Kafka brokers, you need a Virtual Scanner:"
    echo ""
    echo "1. Log in to Qualys portal"
    echo "2. Go to: Scans > Appliances > New > Virtual Scanner Appliance"
    echo "3. Choose 'Docker' as the platform"
    echo "4. Copy the Personalization Code"
    echo ""
    read -rp "Personalization Code (or press Enter to skip): " QUALYS_PERSO_CODE
    QUALYS_PERSO_CODE=${QUALYS_PERSO_CODE:-"NOT_CONFIGURED"}

    # Step 6: Scan targets
    echo ""
    echo -e "${CYAN}═══ Step 5: Configure Scan Targets ═══${NC}"
    echo ""
    echo "Default Kafka test cluster IPs (Docker network):"
    echo "  172.28.0.10 (kafka-1), 172.28.0.11 (kafka-2), 172.28.0.12 (kafka-3)"
    echo "  172.28.0.20 (ksqldb-server)"
    echo ""
    read -rp "Scan targets [172.28.0.10-172.28.0.12,172.28.0.20]: " scan_targets
    QUALYS_SCAN_TARGETS=${scan_targets:-"172.28.0.10-172.28.0.12,172.28.0.20"}

    # Save config
    echo ""
    log_step "Saving configuration..."
    mkdir -p "$(dirname "$CONFIG_FILE")"
    cat > "$CONFIG_FILE" <<ENVEOF
# Qualys Configuration - Generated $(date)
QUALYS_API_URL=${QUALYS_API_URL}
QUALYS_USERNAME=${QUALYS_USERNAME}
QUALYS_PASSWORD=${QUALYS_PASSWORD}
QUALYS_PERSO_CODE=${QUALYS_PERSO_CODE}
QUALYS_SCANNER_NAME=kafka-vapt-scanner
QUALYS_SCAN_TARGETS=${QUALYS_SCAN_TARGETS}
QUALYS_SCAN_TITLE=Kafka-VAPT-Scan
QUALYS_OPTION_PROFILE_ID=
QUALYS_REPORT_FORMAT=PDF
ENVEOF

    log_info "Config saved to: $CONFIG_FILE"
    echo ""
    echo -e "${GREEN}Setup complete!${NC}"
    echo ""
    echo "Next steps:"
    echo "  1. Start test cluster: docker compose -f docker-compose.qualys-test.yml up -d"
    echo "  2. Run scan:           ./run-qualys-vapt.sh --scan"
    echo "  3. Or manual mode:     ./run-qualys-vapt.sh --scan --manual"
}

# ── API-Based Scan ────────────────────────────────────────────────────────
run_api_scan() {
    log_step "Running Qualys API-based vulnerability scan"
    echo ""

    if [[ -z "$QUALYS_USERNAME" || -z "$QUALYS_API_URL" ]]; then
        log_error "Qualys credentials not configured. Run --setup first."
        exit 1
    fi

    local auth_header
    auth_header="-u ${QUALYS_USERNAME}:${QUALYS_PASSWORD}"

    # Step 1: Verify API access
    log_step "Verifying API access..."
    local api_test
    api_test=$(curl -sS -o /dev/null -w "%{http_code}" \
        ${auth_header} \
        "${QUALYS_API_URL}/api/2.0/fo/scan/?action=list&show_status=1" \
        -H "X-Requested-With: curl" 2>&1) || true

    if [[ "$api_test" != "200" ]]; then
        log_error "API access failed (HTTP $api_test)."
        log_error "CE free tier may not have API access. Use --manual mode instead."
        exit 1
    fi
    log_info "API access verified"

    # Step 2: Check for available scanners
    log_step "Checking available scanners..."
    local scanners
    scanners=$(curl -sS ${auth_header} \
        "${QUALYS_API_URL}/api/2.0/fo/appliance/?action=list" \
        -H "X-Requested-With: curl" 2>&1)

    echo "$scanners" | head -20
    log_info "Scanner list retrieved"

    # Step 3: Add scan targets as assets
    log_step "Adding scan targets as assets..."
    local add_ips_response
    add_ips_response=$(curl -sS ${auth_header} \
        "${QUALYS_API_URL}/api/2.0/fo/asset/ip/?action=add" \
        -H "X-Requested-With: curl" \
        -d "ips=${QUALYS_SCAN_TARGETS}&enable_vm=1" 2>&1) || true

    log_info "Assets added: ${QUALYS_SCAN_TARGETS}"

    # Step 4: Launch vulnerability scan
    log_step "Launching vulnerability scan..."
    local scan_title="${QUALYS_SCAN_TITLE}-${TIMESTAMP}"
    local scan_response
    local scan_params="action=launch&scan_title=${scan_title}&ip=${QUALYS_SCAN_TARGETS}&iscanner_name=External"

    if [[ -n "$QUALYS_OPTION_PROFILE_ID" ]]; then
        scan_params="${scan_params}&option_id=${QUALYS_OPTION_PROFILE_ID}"
    else
        scan_params="${scan_params}&option_title=Initial+Options"
    fi

    scan_response=$(curl -sS ${auth_header} \
        "${QUALYS_API_URL}/api/2.0/fo/scan/" \
        -H "X-Requested-With: curl" \
        -d "$scan_params" 2>&1) || true

    echo "$scan_response" | tee "${REPORT_DIR}/scan-launch-${TIMESTAMP}.xml"

    # Extract scan reference
    local scan_ref
    scan_ref=$(echo "$scan_response" | grep -oE 'scan/[0-9]+\.[0-9]+' | head -1 || echo "")

    if [[ -n "$scan_ref" ]]; then
        log_info "Scan launched: $scan_ref"
        log_info "Title: $scan_title"
        echo ""

        # Step 5: Poll for completion
        log_step "Waiting for scan to complete..."
        local max_wait=600  # 10 minutes
        local elapsed=0
        local poll_interval=30

        while [[ $elapsed -lt $max_wait ]]; do
            local status_response
            status_response=$(curl -sS ${auth_header} \
                "${QUALYS_API_URL}/api/2.0/fo/scan/?action=list&scan_ref=${scan_ref}&show_status=1" \
                -H "X-Requested-With: curl" 2>&1) || true

            local scan_status
            scan_status=$(echo "$status_response" | grep -oE '<STATUS>[^<]+</STATUS>' | head -1 || echo "")

            if echo "$scan_status" | grep -qi "Finished"; then
                log_info "Scan completed!"
                break
            elif echo "$scan_status" | grep -qi "Error\|Failed"; then
                log_error "Scan failed: $scan_status"
                break
            fi

            echo -ne "\r  Elapsed: ${elapsed}s / ${max_wait}s - Status: ${scan_status:-Scanning...}"
            sleep "$poll_interval"
            elapsed=$((elapsed + poll_interval))
        done

        echo ""
    else
        log_warn "Could not extract scan reference from response"
        log_warn "Check the Qualys portal for scan status"
    fi
}

# ── Manual Scan Mode (CE Free Tier) ──────────────────────────────────────
run_manual_scan() {
    log_step "Manual Scan Mode - For Qualys Community Edition (Free Tier)"
    echo ""
    echo -e "${BOLD}Since CE free tier doesn't include API access, follow these steps:${NC}"
    echo ""

    # Check if test cluster is running
    local cluster_running=false
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "qualys-kafka"; then
        cluster_running=true
        log_info "Test Kafka cluster is running"
    else
        log_warn "Test Kafka cluster not detected"
        echo ""
        echo "Start it with:"
        echo "  cd ${SCRIPT_DIR}"
        echo "  docker compose -f docker-compose.qualys-test.yml up -d"
        echo ""
    fi

    # Get Docker network info
    echo -e "${CYAN}═══ Step 1: Identify Target IPs ═══${NC}"
    echo ""
    if [[ "$cluster_running" == true ]]; then
        echo "Detected Kafka broker IPs:"
        docker inspect qualys-kafka-1 2>/dev/null | jq -r '.[0].NetworkSettings.Networks | to_entries[] | "  \(.key): \(.value.IPAddress)"' || true
        docker inspect qualys-kafka-2 2>/dev/null | jq -r '.[0].NetworkSettings.Networks | to_entries[] | "  \(.key): \(.value.IPAddress)"' || true
        docker inspect qualys-kafka-3 2>/dev/null | jq -r '.[0].NetworkSettings.Networks | to_entries[] | "  \(.key): \(.value.IPAddress)"' || true
        docker inspect qualys-ksqldb 2>/dev/null | jq -r '.[0].NetworkSettings.Networks | to_entries[] | "  \(.key): \(.value.IPAddress)"' || true
        echo ""
    fi
    echo "Default scan targets: 172.28.0.10-172.28.0.12, 172.28.0.20"
    echo ""

    echo -e "${CYAN}═══ Step 2: Set Up Virtual Scanner ═══${NC}"
    echo ""
    echo "1. Log in to your Qualys portal"
    echo "2. Navigate to: Scans > Appliances"
    echo "3. Click 'New' > 'Virtual Scanner Appliance'"
    echo "4. Select platform: Docker"
    echo "5. Download the Docker image or note the pull command"
    echo "6. Run the scanner container on the same Docker network:"
    echo ""
    echo "   docker run -d --name qualys-scanner \\"
    echo "     --network qualys-vapt_kafka-qualys-net \\"
    echo "     --ip 172.28.0.100 \\"
    echo "     -e PERSO_CODE=YOUR_CODE_HERE \\"
    echo "     qualys/qvsa:latest"
    echo ""

    echo -e "${CYAN}═══ Step 3: Add Assets in Qualys Portal ═══${NC}"
    echo ""
    echo "1. Go to: Assets > Host Assets"
    echo "2. Click 'Add IPs' and enter:"
    echo "   172.28.0.10, 172.28.0.11, 172.28.0.12, 172.28.0.20"
    echo "3. Assign them to your default asset group"
    echo ""

    echo -e "${CYAN}═══ Step 4: Create and Launch Scan ═══${NC}"
    echo ""
    echo "1. Go to: Scans > Scans > New > Scan"
    echo "2. Configure:"
    echo "   - Title: Kafka-VAPT-Scan-${TIMESTAMP}"
    echo "   - Scanner: Your virtual scanner appliance"
    echo "   - Target IPs: 172.28.0.10-172.28.0.12, 172.28.0.20"
    echo "   - Option Profile: 'Initial Options' (or custom)"
    echo "   - Port Settings: Add custom ports: 9092,9093,9094,9095,9096,9097,8088"
    echo "3. Launch the scan"
    echo ""

    echo -e "${CYAN}═══ Step 5: Configure Kafka-Specific Ports ═══${NC}"
    echo ""
    echo "For better Kafka detection, create a custom Option Profile:"
    echo ""
    echo "1. Go to: Scans > Option Profiles > New"
    echo "2. Name: 'Kafka VAPT Profile'"
    echo "3. Under 'Scan' tab > 'TCP Ports':"
    echo "   Add: 9092,9093,9094,9095,9096,9097,8088,2181,8083,8081,3888"
    echo "4. Under 'Authentication' tab:"
    echo "   - Enable Unix authentication if brokers run on Linux"
    echo "5. Save and use this profile for Kafka scans"
    echo ""

    echo -e "${CYAN}═══ Step 6: Download Report ═══${NC}"
    echo ""
    echo "After scan completes:"
    echo "1. Go to: Scans > Scans"
    echo "2. Click on your completed scan"
    echo "3. Click 'Report' to generate a vulnerability report"
    echo "4. Download the PDF/HTML report"
    echo "5. Save it to: ${REPORT_DIR}/"
    echo ""

    # Generate a manual scan checklist
    local checklist_file="${REPORT_DIR}/qualys-scan-checklist-${TIMESTAMP}.txt"
    mkdir -p "$REPORT_DIR"
    cat > "$checklist_file" <<CHECKEOF
Qualys CE Manual Scan Checklist - ${TIMESTAMP}
================================================

Target Kafka Cluster:
  Broker 1: 172.28.0.10 (ports 9092, 9093)
  Broker 2: 172.28.0.11 (ports 9092, 9093)
  Broker 3: 172.28.0.12 (ports 9092, 9093)
  ksqlDB:   172.28.0.20 (port 8088)

Steps:
  [ ] 1. Created Qualys CE account
  [ ] 2. Set up Virtual Scanner Appliance (Docker)
  [ ] 3. Added target IPs as assets
  [ ] 4. Created Kafka-specific Option Profile
  [ ] 5. Launched vulnerability scan
  [ ] 6. Scan completed successfully
  [ ] 7. Downloaded report (PDF/HTML)
  [ ] 8. Reviewed findings and severity ratings

Qualys Kafka-Specific Checks to Verify:
  [ ] Open ports detected (9092, 9093, 8088)
  [ ] SSL/TLS configuration checked
  [ ] Authentication mechanisms detected
  [ ] Known CVEs for Apache Kafka version
  [ ] Known CVEs for Java/JVM version
  [ ] Network services enumeration
  [ ] Banner grabbing results
  [ ] OS fingerprinting results

Notes:
  - Qualys CE scans general network/OS vulnerabilities
  - For Kafka-specific security checks, use kafka-vapt/ scanner
  - Combine both reports for comprehensive VAPT coverage
CHECKEOF

    log_info "Checklist saved to: $checklist_file"
    echo ""
    echo -e "${GREEN}Manual scan instructions generated!${NC}"
}

# ── Download Report ───────────────────────────────────────────────────────
download_report() {
    log_step "Downloading latest Qualys scan report"
    echo ""

    if [[ -z "$QUALYS_USERNAME" || -z "$QUALYS_API_URL" ]]; then
        log_error "Qualys credentials not configured. Run --setup first."
        exit 1
    fi

    local auth_header="-u ${QUALYS_USERNAME}:${QUALYS_PASSWORD}"
    mkdir -p "$REPORT_DIR"

    # List recent scans
    log_step "Fetching recent scan list..."
    local scans_response
    scans_response=$(curl -sS ${auth_header} \
        "${QUALYS_API_URL}/api/2.0/fo/scan/?action=list&show_last=5&show_status=1" \
        -H "X-Requested-With: curl" 2>&1) || true

    echo "$scans_response" > "${REPORT_DIR}/recent-scans-${TIMESTAMP}.xml"
    log_info "Recent scans saved to: ${REPORT_DIR}/recent-scans-${TIMESTAMP}.xml"

    # Try to get the latest finished scan ref
    local scan_ref
    scan_ref=$(echo "$scans_response" | grep -oE 'scan/[0-9]+\.[0-9]+' | head -1 || echo "")

    if [[ -z "$scan_ref" ]]; then
        log_warn "No recent scans found via API"
        log_warn "Download report manually from Qualys portal"
        return
    fi

    # Fetch scan results
    log_step "Downloading results for scan: $scan_ref"
    local results_response
    results_response=$(curl -sS ${auth_header} \
        "${QUALYS_API_URL}/api/2.0/fo/scan/?action=fetch&scan_ref=${scan_ref}&output_format=json" \
        -H "X-Requested-With: curl" 2>&1) || true

    local report_file="${REPORT_DIR}/qualys-scan-${TIMESTAMP}.json"
    echo "$results_response" > "$report_file"
    log_info "Scan results saved to: $report_file"

    # Generate summary
    log_step "Generating scan summary..."
    if command -v jq &>/dev/null && echo "$results_response" | jq -e '.' &>/dev/null; then
        generate_summary "$report_file"
    else
        log_warn "Results may be in XML format. Check the file directly."
    fi
}

generate_summary() {
    local report_file="$1"
    local summary_file="${REPORT_DIR}/qualys-summary-${TIMESTAMP}.html"

    cat > "$summary_file" <<'HTMLEOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <title>Qualys VAPT Scan Summary - Kafka Cluster</title>
    <style>
        body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; margin: 2em; background: #f5f5f5; }
        .container { max-width: 900px; margin: 0 auto; background: white; padding: 2em; border-radius: 8px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
        h1 { color: #1a1a2e; border-bottom: 3px solid #e94560; padding-bottom: 0.5em; }
        h2 { color: #16213e; margin-top: 1.5em; }
        .severity-critical { color: #d32f2f; font-weight: bold; }
        .severity-high { color: #f57c00; font-weight: bold; }
        .severity-medium { color: #fbc02d; font-weight: bold; }
        .severity-low { color: #388e3c; }
        table { width: 100%; border-collapse: collapse; margin: 1em 0; }
        th, td { padding: 8px 12px; border: 1px solid #ddd; text-align: left; }
        th { background: #1a1a2e; color: white; }
        tr:nth-child(even) { background: #f9f9f9; }
        .info-box { background: #e3f2fd; border-left: 4px solid #1976d2; padding: 1em; margin: 1em 0; }
        .warn-box { background: #fff3e0; border-left: 4px solid #f57c00; padding: 1em; margin: 1em 0; }
    </style>
</head>
<body>
<div class="container">
    <h1>Qualys VAPT Scan Summary</h1>
    <p><strong>Target:</strong> Kafka Cluster (Docker Test Environment)</p>
HTMLEOF

    echo "    <p><strong>Scan Date:</strong> $(date)</p>" >> "$summary_file"
    echo "    <p><strong>Report File:</strong> ${report_file}</p>" >> "$summary_file"

    cat >> "$summary_file" <<'HTMLEOF'

    <div class="info-box">
        <strong>Note:</strong> This is a Qualys network/infrastructure scan.
        For Kafka-specific security checks (ACLs, SASL, topic-level security),
        use the dedicated <code>kafka-vapt/run-kafka-vapt.sh</code> scanner.
    </div>

    <h2>What Qualys Scans For</h2>
    <table>
        <tr><th>Category</th><th>Description</th><th>Kafka Relevance</th></tr>
        <tr><td>Open Ports</td><td>TCP/UDP port scanning</td><td>Detects exposed Kafka, ZooKeeper, ksqlDB ports</td></tr>
        <tr><td>OS Vulnerabilities</td><td>Known CVEs for host OS</td><td>Broker host security</td></tr>
        <tr><td>Service Detection</td><td>Banner grabbing, version detection</td><td>Kafka version, Java version</td></tr>
        <tr><td>SSL/TLS</td><td>Certificate and cipher analysis</td><td>Kafka SSL listener configuration</td></tr>
        <tr><td>Network Config</td><td>Routing, firewall, segmentation</td><td>Broker network isolation</td></tr>
        <tr><td>Known Exploits</td><td>CVE database matching</td><td>Apache Kafka CVEs, Log4j, etc.</td></tr>
    </table>

    <h2>Recommended Kafka-Specific Ports to Scan</h2>
    <table>
        <tr><th>Port</th><th>Service</th><th>Security Concern</th></tr>
        <tr><td>9092</td><td>Kafka PLAINTEXT</td><td>Unencrypted client connections</td></tr>
        <tr><td>9093</td><td>Kafka SSL</td><td>Check cert validity, cipher strength</td></tr>
        <tr><td>9094</td><td>Kafka SASL_PLAINTEXT</td><td>Auth without encryption</td></tr>
        <tr><td>9095</td><td>Kafka SASL_SSL</td><td>Best practice (auth + encryption)</td></tr>
        <tr><td>8088</td><td>ksqlDB REST</td><td>Unauthenticated query execution</td></tr>
        <tr><td>2181</td><td>ZooKeeper</td><td>ZK access = cluster control</td></tr>
        <tr><td>8081</td><td>Schema Registry</td><td>Schema exposure/modification</td></tr>
        <tr><td>8083</td><td>Kafka Connect</td><td>Connector manipulation</td></tr>
    </table>

    <div class="warn-box">
        <strong>Important:</strong> Qualys provides infrastructure-level vulnerability detection.
        Always combine with Kafka-specific VAPT checks for complete security coverage.
    </div>
</div>
</body>
</html>
HTMLEOF

    log_info "Summary report saved to: $summary_file"
}

# ── Main ──────────────────────────────────────────────────────────────────
main() {
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --setup)    MODE="setup"; shift ;;
            --scan)     MODE="scan"; shift ;;
            --manual)   MANUAL_MODE=true; shift ;;
            --report)   MODE="report"; shift ;;
            --full)     MODE="full"; shift ;;
            --config)   CONFIG_FILE="$2"; shift 2 ;;
            --targets)  QUALYS_SCAN_TARGETS="$2"; shift 2 ;;
            -h|--help)  usage; exit 0 ;;
            *)          log_error "Unknown option: $1"; usage; exit 1 ;;
        esac
    done

    print_banner
    check_prerequisites
    mkdir -p "$REPORT_DIR"

    case "$MODE" in
        setup)
            run_setup
            ;;
        scan)
            load_config
            if [[ "$MANUAL_MODE" == true ]]; then
                run_manual_scan
            else
                run_api_scan
            fi
            ;;
        report)
            load_config
            download_report
            ;;
        full)
            load_config
            if [[ -z "$QUALYS_USERNAME" ]]; then
                run_setup
                load_config
            fi
            if [[ "$MANUAL_MODE" == true ]]; then
                run_manual_scan
            else
                run_api_scan
            fi
            download_report
            ;;
        "")
            log_error "No mode specified. Use --setup, --scan, --report, or --full"
            usage
            exit 1
            ;;
    esac
}

main "$@"

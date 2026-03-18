#!/usr/bin/env bash
#
# Tantor VAPT Scanner — Run OWASP ZAP against any target
#
# Usage:
#   ./run-vapt.sh <target-url>                     # Baseline scan only
#   ./run-vapt.sh <target-url> --api <openapi-url> # Baseline + API scan
#   ./run-vapt.sh <target-url> --full              # Full active scan (slow)
#
# Examples:
#   ./run-vapt.sh https://myapp.example.com
#   ./run-vapt.sh https://myapp.example.com --api https://myapp.example.com/openapi.json
#   ./run-vapt.sh http://localhost:8000 --api http://localhost:8000/openapi.json
#   ./run-vapt.sh https://staging.myapp.com --full
#   ./run-vapt.sh https://myapp.com --api https://myapp.com/swagger.json --full
#
# Prerequisites:
#   - Docker installed and running
#   - Target application accessible from your machine
#
# Output:
#   Reports are saved to ./reports/<timestamp>/
#

set -e

# ─── Colors ───
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# ─── Help ───
show_help() {
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║         OWASP ZAP — VAPT Security Scanner          ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${YELLOW}Usage:${NC}"
    echo "  $0 <target-url> [options]"
    echo ""
    echo -e "${YELLOW}Options:${NC}"
    echo "  --api <url>       URL to OpenAPI/Swagger spec (enables API scan)"
    echo "  --full            Run full active scan (slower, more thorough)"
    echo "  --output <dir>    Custom output directory (default: ./reports/<timestamp>)"
    echo "  --ajax            Enable AJAX spider (for JS-heavy SPAs)"
    echo "  --auth <token>    Bearer token for authenticated scanning"
    echo "  --minutes <n>     Max scan duration in minutes (default: 10)"
    echo "  --help            Show this help message"
    echo ""
    echo -e "${YELLOW}Examples:${NC}"
    echo -e "  ${GREEN}# Basic scan against a website${NC}"
    echo "  $0 https://myapp.example.com"
    echo ""
    echo -e "  ${GREEN}# Scan with OpenAPI spec (recommended for APIs)${NC}"
    echo "  $0 https://api.example.com --api https://api.example.com/openapi.json"
    echo ""
    echo -e "  ${GREEN}# Full active scan with authentication${NC}"
    echo "  $0 https://myapp.com --full --auth 'eyJhbGciOiJIUzI1NiI...'"
    echo ""
    echo -e "  ${GREEN}# Scan a local dev server${NC}"
    echo "  $0 http://localhost:3000 --ajax"
    echo ""
    echo -e "  ${GREEN}# Scan with Swagger spec${NC}"
    echo "  $0 https://petstore.swagger.io --api https://petstore.swagger.io/v2/swagger.json"
    echo ""
    exit 0
}

# ─── Parse Arguments ───
TARGET_URL=""
API_SPEC_URL=""
FULL_SCAN=false
AJAX_SPIDER=false
AUTH_TOKEN=""
OUTPUT_DIR=""
MAX_MINUTES=10

while [[ $# -gt 0 ]]; do
    case $1 in
        --help|-h)
            show_help
            ;;
        --api)
            API_SPEC_URL="$2"
            shift 2
            ;;
        --full)
            FULL_SCAN=true
            shift
            ;;
        --ajax)
            AJAX_SPIDER=true
            shift
            ;;
        --auth)
            AUTH_TOKEN="$2"
            shift 2
            ;;
        --output)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --minutes)
            MAX_MINUTES="$2"
            shift 2
            ;;
        -*)
            echo -e "${RED}Unknown option: $1${NC}"
            echo "Use --help for usage information"
            exit 1
            ;;
        *)
            if [ -z "$TARGET_URL" ]; then
                TARGET_URL="$1"
            else
                echo -e "${RED}Unexpected argument: $1${NC}"
                exit 1
            fi
            shift
            ;;
    esac
done

if [ -z "$TARGET_URL" ]; then
    echo -e "${RED}Error: Target URL is required${NC}"
    echo ""
    show_help
fi

# ─── Setup ───
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
if [ -z "$OUTPUT_DIR" ]; then
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    OUTPUT_DIR="$SCRIPT_DIR/reports/$TIMESTAMP"
fi
mkdir -p "$OUTPUT_DIR"

# Convert localhost to host.docker.internal for macOS/Windows Docker
DOCKER_TARGET="$TARGET_URL"
DOCKER_API_SPEC="$API_SPEC_URL"
if [[ "$TARGET_URL" == *"localhost"* ]] || [[ "$TARGET_URL" == *"127.0.0.1"* ]]; then
    DOCKER_TARGET=$(echo "$TARGET_URL" | sed 's/localhost/host.docker.internal/g' | sed 's/127\.0\.0\.1/host.docker.internal/g')
    echo -e "${YELLOW}⚠  Localhost detected — using host.docker.internal for Docker${NC}"
fi
if [[ "$API_SPEC_URL" == *"localhost"* ]] || [[ "$API_SPEC_URL" == *"127.0.0.1"* ]]; then
    DOCKER_API_SPEC=$(echo "$API_SPEC_URL" | sed 's/localhost/host.docker.internal/g' | sed 's/127\.0\.0\.1/host.docker.internal/g')
fi

# ─── Banner ───
echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║         OWASP ZAP — VAPT Security Scanner          ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${BLUE}Target:${NC}       $TARGET_URL"
[ -n "$API_SPEC_URL" ] && echo -e "  ${BLUE}API Spec:${NC}     $API_SPEC_URL"
echo -e "  ${BLUE}Scan Type:${NC}    $([ "$FULL_SCAN" = true ] && echo 'Full Active Scan' || echo 'Baseline (Passive)')"
[ "$AJAX_SPIDER" = true ] && echo -e "  ${BLUE}AJAX Spider:${NC}  Enabled"
[ -n "$AUTH_TOKEN" ] && echo -e "  ${BLUE}Auth:${NC}         Bearer token provided"
echo -e "  ${BLUE}Max Duration:${NC} ${MAX_MINUTES} minutes"
echo -e "  ${BLUE}Output:${NC}       $OUTPUT_DIR"
echo ""

# ─── Check Docker ───
if ! command -v docker &> /dev/null; then
    echo -e "${RED}✗ Docker is not installed. Please install Docker first.${NC}"
    echo "  https://docs.docker.com/get-docker/"
    exit 1
fi

if ! docker info &> /dev/null 2>&1; then
    echo -e "${RED}✗ Docker daemon is not running. Please start Docker.${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Docker is available${NC}"

# ─── Pull ZAP Image ───
echo -e "\n${BLUE}▶ Pulling OWASP ZAP Docker image...${NC}"
docker pull zaproxy/zap-stable -q 2>/dev/null || true
echo -e "${GREEN}✓ ZAP image ready${NC}"

# ─── Check Target Reachability ───
echo -e "\n${BLUE}▶ Checking target reachability...${NC}"
HTTP_CODE=$(curl -skf -o /dev/null -w "%{http_code}" --max-time 10 "$TARGET_URL" 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "000" ]; then
    echo -e "${RED}✗ Cannot reach $TARGET_URL${NC}"
    echo -e "  Make sure the target is running and accessible."
    exit 1
fi
echo -e "${GREEN}✓ Target is reachable (HTTP $HTTP_CODE)${NC}"

# ─── Build ZAP Options ───
ZAP_COMMON_OPTS="-v $OUTPUT_DIR:/zap/wrk/:rw"

# Build auth config file if token provided
if [ -n "$AUTH_TOKEN" ]; then
    cat > "$OUTPUT_DIR/zap-auth.conf" << AUTHEOF
replacer.full_list(0).description=auth_header
replacer.full_list(0).enabled=true
replacer.full_list(0).matchtype=REQ_HEADER
replacer.full_list(0).matchstr=Authorization
replacer.full_list(0).regex=false
replacer.full_list(0).replacement=Bearer ${AUTH_TOKEN}
AUTHEOF
    echo -e "${GREEN}✓ Auth configuration created${NC}"
fi

# ─── Scan Counter ───
SCAN_COUNT=0
TOTAL_PASS=0
TOTAL_WARN=0
TOTAL_FAIL=0

# ─── Function: Run a scan ───
run_scan() {
    local SCAN_NAME="$1"
    local SCAN_CMD="$2"
    local REPORT_HTML="$3"
    local REPORT_JSON="$4"

    SCAN_COUNT=$((SCAN_COUNT + 1))
    echo -e "\n${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}▶ Scan $SCAN_COUNT: $SCAN_NAME${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    local START_TIME=$(date +%s)

    # Run ZAP
    local CMD="docker run --rm $ZAP_COMMON_OPTS zaproxy/zap-stable $SCAN_CMD -r $REPORT_HTML -J $REPORT_JSON -I"
    echo -e "  ${YELLOW}Running...${NC} (this may take a few minutes)"

    local OUTPUT
    OUTPUT=$(eval "$CMD" 2>&1) || true

    local END_TIME=$(date +%s)
    local DURATION=$(( END_TIME - START_TIME ))

    # Parse results
    local PASS=$(echo "$OUTPUT" | grep -o 'PASS: [0-9]*' | tail -1 | sed 's/PASS: //')
    local WARN=$(echo "$OUTPUT" | grep -o 'WARN-NEW: [0-9]*' | tail -1 | sed 's/WARN-NEW: //')
    local FAIL=$(echo "$OUTPUT" | grep -o 'FAIL-NEW: [0-9]*' | tail -1 | sed 's/FAIL-NEW: //')

    PASS=${PASS:-0}
    WARN=${WARN:-0}
    FAIL=${FAIL:-0}

    TOTAL_PASS=$((TOTAL_PASS + PASS))
    TOTAL_WARN=$((TOTAL_WARN + WARN))
    TOTAL_FAIL=$((TOTAL_FAIL + FAIL))

    echo ""
    echo -e "  ${GREEN}✓ PASS: $PASS${NC}  |  ${YELLOW}⚠ WARN: $WARN${NC}  |  ${RED}✗ FAIL: $FAIL${NC}  |  ⏱  ${DURATION}s"

    # Show warnings/failures
    if [ "$WARN" -gt 0 ] || [ "$FAIL" -gt 0 ]; then
        echo ""
        echo "$OUTPUT" | grep -E "^WARN-NEW:|^FAIL-NEW:" | while IFS= read -r line; do
            if [[ "$line" == FAIL* ]]; then
                echo -e "    ${RED}$line${NC}"
            else
                echo -e "    ${YELLOW}$line${NC}"
            fi
        done
        echo "$OUTPUT" | grep -E "^\t" | while IFS= read -r line; do
            echo -e "    ${YELLOW}$line${NC}"
        done
    fi

    # Verify report files
    if [ -f "$OUTPUT_DIR/$REPORT_HTML" ]; then
        echo -e "  ${GREEN}✓ Report: $REPORT_HTML${NC}"
    else
        echo -e "  ${RED}✗ Report not generated${NC}"
    fi
}

# ─── Scan 1: Baseline Scan ───
BASELINE_CMD="zap-baseline.py -t $DOCKER_TARGET -m $MAX_MINUTES"
if [ "$AJAX_SPIDER" = true ]; then
    BASELINE_CMD="$BASELINE_CMD -j"
fi
if [ -n "$AUTH_TOKEN" ]; then
    BASELINE_CMD="$BASELINE_CMD -z '-config /zap/wrk/zap-auth.conf'"
fi
run_scan "Baseline Scan (Passive)" "$BASELINE_CMD" "baseline-report.html" "baseline-report.json"

# ─── Scan 2: API Scan (if OpenAPI spec provided) ───
if [ -n "$API_SPEC_URL" ]; then
    API_CMD="zap-api-scan.py -t $DOCKER_API_SPEC -f openapi"
    if [ -n "$AUTH_TOKEN" ]; then
        API_CMD="$API_CMD -z '-config /zap/wrk/zap-auth.conf'"
    fi
    run_scan "API Active Scan (OpenAPI)" "$API_CMD" "api-scan-report.html" "api-scan-report.json"
fi

# ─── Scan 3: Full Active Scan (if requested) ───
if [ "$FULL_SCAN" = true ]; then
    FULL_CMD="zap-full-scan.py -t $DOCKER_TARGET -m $MAX_MINUTES"
    if [ "$AJAX_SPIDER" = true ]; then
        FULL_CMD="$FULL_CMD -j"
    fi
    if [ -n "$AUTH_TOKEN" ]; then
        FULL_CMD="$FULL_CMD -z '-config /zap/wrk/zap-auth.conf'"
    fi
    run_scan "Full Active Scan" "$FULL_CMD" "full-scan-report.html" "full-scan-report.json"
fi

# ─── Summary ───
echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║                  SCAN COMPLETE                      ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════╝${NC}"
echo ""

# Determine grade
GRADE="A"
GRADE_COLOR="$GREEN"
if [ "$TOTAL_FAIL" -gt 0 ]; then
    GRADE="F"
    GRADE_COLOR="$RED"
elif [ "$TOTAL_WARN" -gt 5 ]; then
    GRADE="C"
    GRADE_COLOR="$YELLOW"
elif [ "$TOTAL_WARN" -gt 2 ]; then
    GRADE="B"
    GRADE_COLOR="$YELLOW"
fi

echo -e "  ${GRADE_COLOR}Security Grade: $GRADE${NC}"
echo ""
echo -e "  ${GREEN}✓ Passed:${NC}   $TOTAL_PASS"
echo -e "  ${YELLOW}⚠ Warnings:${NC} $TOTAL_WARN"
echo -e "  ${RED}✗ Failures:${NC} $TOTAL_FAIL"
echo ""
echo -e "  ${BLUE}Reports saved to:${NC}"
echo "    $OUTPUT_DIR/"
ls -1 "$OUTPUT_DIR"/*.html 2>/dev/null | while read f; do
    echo -e "    ${GREEN}→${NC} $(basename "$f")"
done
echo ""
echo -e "  ${BLUE}Open consolidated report:${NC}"
echo "    open $OUTPUT_DIR/baseline-report.html"
echo ""

# ─── Generate Summary JSON ───
cat > "$OUTPUT_DIR/summary.json" << EOF
{
  "scan_date": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "target": "$TARGET_URL",
  "api_spec": "$API_SPEC_URL",
  "scanner": "OWASP ZAP 2.17.0",
  "scan_type": "$([ "$FULL_SCAN" = true ] && echo 'full' || echo 'baseline')",
  "grade": "$GRADE",
  "total_pass": $TOTAL_PASS,
  "total_warn": $TOTAL_WARN,
  "total_fail": $TOTAL_FAIL,
  "scans_performed": $SCAN_COUNT
}
EOF
echo -e "  ${GREEN}✓ Summary: summary.json${NC}"
echo ""

#!/usr/bin/env bash
###############################################################################
# Kafka Cluster VAPT (Vulnerability Assessment & Penetration Testing) Scanner
#
# Open-source tools used:
#   - nmap          : Network/port scanning & service detection
#   - openssl       : TLS/SSL certificate & cipher analysis
#   - kcat(kafkacat): Kafka connectivity & auth testing
#   - kafka CLI     : Native Kafka config & ACL inspection
#   - jq            : JSON processing
#
# Usage:
#   ./run-kafka-vapt.sh --bootstrap <host:port> [options]
#
# Options:
#   --bootstrap <host:port>   Kafka bootstrap server (required)
#   --brokers <h1:p,h2:p>    Comma-separated broker list (auto-detected if omitted)
#   --zookeeper <host:port>   ZooKeeper address (optional, for legacy checks)
#   --ssl                     Enable SSL/TLS scanning
#   --sasl-mechanism <mech>   SASL mechanism (PLAIN, SCRAM-SHA-256, SCRAM-SHA-512)
#   --sasl-username <user>    SASL username
#   --sasl-password <pass>    SASL password
#   --client-props <file>     Path to client.properties for authenticated access
#   --kafka-home <path>       Path to Kafka installation (for CLI tools)
#   --output <dir>            Output directory for reports (default: ./reports)
#   --format <html|json|both> Report format (default: both)
#   --ksqldb <host:port>      ksqlDB server address (default: auto-detect on bootstrap host:8088)
#   --docker                  Run scans inside Docker container
#   --help                    Show this help
###############################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECKS_DIR="${SCRIPT_DIR}/checks"
TEMPLATES_DIR="${SCRIPT_DIR}/templates"

# Defaults
BOOTSTRAP=""
BROKERS=""
ZOOKEEPER=""
SSL_ENABLED=false
SASL_MECHANISM=""
SASL_USERNAME=""
SASL_PASSWORD=""
CLIENT_PROPS=""
KAFKA_HOME=""
KSQLDB_URL=""
OUTPUT_DIR="${SCRIPT_DIR}/reports"
REPORT_FORMAT="both"
USE_DOCKER=false
SCAN_ID="kafka-vapt-$(date +%Y%m%d-%H%M%S)"
RESULTS_FILE=""
SCAN_START=""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[PASS]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_fail()  { echo -e "${RED}[FAIL]${NC}  $*"; }
log_head()  { echo -e "\n${CYAN}══════════════════════════════════════════════════════════════${NC}"; echo -e "${CYAN}  $*${NC}"; echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}\n"; }

usage() {
    head -n 30 "$0" | grep '^#' | sed 's/^#//' | sed 's/^ //'
    exit 0
}

###############################################################################
# Argument parsing
###############################################################################
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --bootstrap)    BOOTSTRAP="$2"; shift 2 ;;
            --brokers)      BROKERS="$2"; shift 2 ;;
            --zookeeper)    ZOOKEEPER="$2"; shift 2 ;;
            --ssl)          SSL_ENABLED=true; shift ;;
            --sasl-mechanism) SASL_MECHANISM="$2"; shift 2 ;;
            --sasl-username)  SASL_USERNAME="$2"; shift 2 ;;
            --sasl-password)  SASL_PASSWORD="$2"; shift 2 ;;
            --client-props)   CLIENT_PROPS="$2"; shift 2 ;;
            --kafka-home)     KAFKA_HOME="$2"; shift 2 ;;
            --ksqldb)         KSQLDB_URL="$2"; shift 2 ;;
            --output)       OUTPUT_DIR="$2"; shift 2 ;;
            --format)       REPORT_FORMAT="$2"; shift 2 ;;
            --docker)       USE_DOCKER=true; shift ;;
            --help|-h)      usage ;;
            *) echo "Unknown option: $1"; usage ;;
        esac
    done

    if [[ -z "$BOOTSTRAP" ]]; then
        echo "Error: --bootstrap is required"
        usage
    fi
}

###############################################################################
# Prerequisite checks
###############################################################################
check_prerequisites() {
    log_head "Checking Prerequisites"

    local missing=()
    for tool in nmap openssl jq curl; do
        if command -v "$tool" &>/dev/null; then
            log_ok "$tool found: $(command -v "$tool")"
        else
            missing+=("$tool")
            log_warn "$tool not found"
        fi
    done

    # kcat / kafkacat
    if command -v kcat &>/dev/null; then
        log_ok "kcat found: $(command -v kcat)"
    elif command -v kafkacat &>/dev/null; then
        log_ok "kafkacat found: $(command -v kafkacat)"
    else
        missing+=("kcat")
        log_warn "kcat/kafkacat not found (some checks will be skipped)"
    fi

    # Kafka CLI tools
    if [[ -n "$KAFKA_HOME" ]] && [[ -d "$KAFKA_HOME/bin" ]]; then
        log_ok "Kafka CLI tools found at $KAFKA_HOME/bin"
    elif command -v kafka-configs.sh &>/dev/null || command -v kafka-configs &>/dev/null; then
        log_ok "Kafka CLI tools found in PATH"
    else
        log_warn "Kafka CLI tools not found (config/ACL checks will be limited)"
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_warn "Missing tools: ${missing[*]}"
        log_info "Install with: brew install ${missing[*]}  (macOS)"
        log_info "         or: apt-get install ${missing[*]}  (Debian/Ubuntu)"
        log_info "Continuing with available tools..."
    fi
}

###############################################################################
# Initialize results JSON
###############################################################################
init_results() {
    mkdir -p "$OUTPUT_DIR"
    RESULTS_FILE="${OUTPUT_DIR}/${SCAN_ID}-results.json"
    SCAN_START="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    cat > "$RESULTS_FILE" <<EOF
{
  "scan_id": "${SCAN_ID}",
  "scan_start": "${SCAN_START}",
  "scan_end": "",
  "target": {
    "bootstrap": "${BOOTSTRAP}",
    "brokers": "${BROKERS}",
    "zookeeper": "${ZOOKEEPER}",
    "ssl_enabled": ${SSL_ENABLED}
  },
  "summary": {
    "total": 0,
    "pass": 0,
    "fail": 0,
    "warn": 0,
    "info": 0,
    "critical": 0,
    "high": 0,
    "medium": 0,
    "low": 0,
    "grade": ""
  },
  "categories": [],
  "findings": []
}
EOF
    log_info "Results file: $RESULTS_FILE"
}

###############################################################################
# Add finding to results
###############################################################################
add_finding() {
    local id="$1"
    local category="$2"
    local title="$3"
    local severity="$4"   # CRITICAL, HIGH, MEDIUM, LOW, INFO
    local status="$5"     # PASS, FAIL, WARN, INFO
    local description="$6"
    local recommendation="${7:-}"
    local details="${8:-}"

    # Escape strings for JSON
    description=$(echo "$description" | jq -Rs '.')
    recommendation=$(echo "$recommendation" | jq -Rs '.')
    details=$(echo "$details" | jq -Rs '.')
    title=$(echo "$title" | jq -Rs '.')

    local finding
    finding=$(cat <<EOF
{
  "id": "${id}",
  "category": "${category}",
  "title": ${title},
  "severity": "${severity}",
  "status": "${status}",
  "description": ${description},
  "recommendation": ${recommendation},
  "details": ${details},
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
)

    # Append finding
    local tmp
    tmp=$(mktemp)
    jq --argjson finding "$finding" '.findings += [$finding]' "$RESULTS_FILE" > "$tmp" && mv "$tmp" "$RESULTS_FILE"

    # Update counters
    tmp=$(mktemp)
    local status_lower
    status_lower=$(echo "$status" | tr '[:upper:]' '[:lower:]')
    local severity_lower
    severity_lower=$(echo "$severity" | tr '[:upper:]' '[:lower:]')

    jq ".summary.total += 1 | .summary.${status_lower} += 1 | .summary.${severity_lower} += 1" "$RESULTS_FILE" > "$tmp" && mv "$tmp" "$RESULTS_FILE"

    # Log to console
    case "$status" in
        PASS) log_ok "[$id] $title" ;;
        FAIL) log_fail "[$id] $title" ;;
        WARN) log_warn "[$id] $title" ;;
        INFO) log_info "[$id] $title" ;;
    esac
}

###############################################################################
# Helper: get kcat command
###############################################################################
get_kcat_cmd() {
    if command -v kcat &>/dev/null; then
        echo "kcat"
    elif command -v kafkacat &>/dev/null; then
        echo "kafkacat"
    else
        echo ""
    fi
}

###############################################################################
# Helper: get Kafka CLI command
###############################################################################
get_kafka_cmd() {
    local cmd="$1"
    if [[ -n "$KAFKA_HOME" ]] && [[ -f "$KAFKA_HOME/bin/${cmd}.sh" ]]; then
        echo "$KAFKA_HOME/bin/${cmd}.sh"
    elif command -v "${cmd}.sh" &>/dev/null; then
        echo "${cmd}.sh"
    elif command -v "$cmd" &>/dev/null; then
        echo "$cmd"
    else
        echo ""
    fi
}

###############################################################################
# Helper: build kcat args
###############################################################################
build_kcat_args() {
    local args="-b $BOOTSTRAP"
    if [[ "$SSL_ENABLED" == true ]]; then
        args="$args -X security.protocol=SSL"
    fi
    if [[ -n "$SASL_MECHANISM" ]]; then
        local protocol="SASL_PLAINTEXT"
        [[ "$SSL_ENABLED" == true ]] && protocol="SASL_SSL"
        args="$args -X security.protocol=$protocol"
        args="$args -X sasl.mechanism=$SASL_MECHANISM"
        args="$args -X sasl.username=$SASL_USERNAME"
        args="$args -X sasl.password=$SASL_PASSWORD"
    fi
    echo "$args"
}

###############################################################################
# Helper: build Kafka CLI command props
###############################################################################
build_kafka_cli_props() {
    local props_file
    props_file=$(mktemp /tmp/kafka-vapt-props-XXXXXX.properties)

    if [[ -n "$CLIENT_PROPS" ]] && [[ -f "$CLIENT_PROPS" ]]; then
        cp "$CLIENT_PROPS" "$props_file"
    else
        if [[ "$SSL_ENABLED" == true ]] && [[ -n "$SASL_MECHANISM" ]]; then
            echo "security.protocol=SASL_SSL" >> "$props_file"
        elif [[ "$SSL_ENABLED" == true ]]; then
            echo "security.protocol=SSL" >> "$props_file"
        elif [[ -n "$SASL_MECHANISM" ]]; then
            echo "security.protocol=SASL_PLAINTEXT" >> "$props_file"
        fi
        if [[ -n "$SASL_MECHANISM" ]]; then
            echo "sasl.mechanism=$SASL_MECHANISM" >> "$props_file"
            echo "sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username=\"$SASL_USERNAME\" password=\"$SASL_PASSWORD\";" >> "$props_file"
        fi
    fi
    echo "$props_file"
}

###############################################################################
# CATEGORY 1: Network Security Checks
###############################################################################
run_network_checks() {
    log_head "Category 1: Network Security"

    local host port
    host=$(echo "$BOOTSTRAP" | cut -d: -f1)
    port=$(echo "$BOOTSTRAP" | cut -d: -f2)

    # NET-001: Port scan for Kafka services
    if command -v nmap &>/dev/null; then
        log_info "Running nmap scan on $host..."
        local nmap_output
        nmap_output=$(nmap -sV -p "$port" --open "$host" 2>&1) || true

        if echo "$nmap_output" | grep -q "open"; then
            add_finding "NET-001" "Network" "Kafka port $port is open and accessible" "INFO" "INFO" \
                "Port $port on $host is open and running a Kafka-compatible service." \
                "Ensure Kafka ports are only accessible from trusted networks." \
                "$nmap_output"
        else
            add_finding "NET-001" "Network" "Kafka port $port is not accessible" "HIGH" "FAIL" \
                "Cannot reach Kafka on $host:$port." \
                "Verify the broker is running and network connectivity is correct." \
                "$nmap_output"
            return 1
        fi

        # NET-002: Check for other common Kafka-related open ports
        log_info "Scanning common Kafka-related ports..."
        local common_ports="9092,9093,9094,2181,2182,2183,8083,8088,8081,3030,9021"
        local all_ports_output
        all_ports_output=$(nmap -sV -p "$common_ports" "$host" 2>&1) || true

        local open_count
        open_count=$(echo "$all_ports_output" | grep -c "open" || true)

        if [[ "$open_count" -gt 3 ]]; then
            add_finding "NET-002" "Network" "Multiple Kafka-related ports exposed ($open_count)" "MEDIUM" "WARN" \
                "Found $open_count open Kafka-related ports. Excessive port exposure increases attack surface." \
                "Close unnecessary ports. Use firewall rules to restrict access." \
                "$all_ports_output"
        else
            add_finding "NET-002" "Network" "Minimal Kafka ports exposed ($open_count)" "LOW" "PASS" \
                "Only $open_count Kafka-related ports are open." \
                "" \
                "$all_ports_output"
        fi

        # NET-003: Check for ZooKeeper exposure
        local zk_port="${ZOOKEEPER:-$host:2181}"
        local zk_host zk_p
        zk_host=$(echo "$zk_port" | cut -d: -f1)
        zk_p=$(echo "$zk_port" | cut -d: -f2)

        local zk_scan
        zk_scan=$(nmap -sV -p "$zk_p" "$zk_host" 2>&1) || true
        if echo "$zk_scan" | grep -q "open"; then
            add_finding "NET-003" "Network" "ZooKeeper port $zk_p is exposed" "HIGH" "WARN" \
                "ZooKeeper is accessible on port $zk_p. If not using KRaft mode, ZooKeeper should be protected." \
                "Migrate to KRaft mode or restrict ZooKeeper access with network policies and SASL authentication." \
                "$zk_scan"
        else
            add_finding "NET-003" "Network" "ZooKeeper port $zk_p is not exposed" "LOW" "PASS" \
                "ZooKeeper port is not externally accessible (possibly using KRaft mode)." "" ""
        fi
    else
        add_finding "NET-001" "Network" "Nmap not available - network scan skipped" "INFO" "INFO" \
            "Install nmap to enable network security scanning." \
            "brew install nmap (macOS) or apt-get install nmap (Linux)" ""
    fi

    # NET-004: DNS resolution check
    if host "$host" &>/dev/null; then
        local dns_output
        dns_output=$(host "$host" 2>&1)
        add_finding "NET-004" "Network" "DNS resolves for $host" "INFO" "INFO" \
            "Host $host resolves correctly." "" "$dns_output"
    fi
}

###############################################################################
# CATEGORY 2: TLS/SSL Security
###############################################################################
run_tls_checks() {
    log_head "Category 2: TLS/SSL Security"

    local host port
    host=$(echo "$BOOTSTRAP" | cut -d: -f1)
    port=$(echo "$BOOTSTRAP" | cut -d: -f2)

    # TLS-001: Check if TLS is enabled
    if command -v openssl &>/dev/null; then
        local tls_output
        tls_output=$(echo | timeout 10 openssl s_client -connect "$host:$port" -servername "$host" 2>&1) || true

        if echo "$tls_output" | grep -q "BEGIN CERTIFICATE"; then
            add_finding "TLS-001" "TLS/SSL" "TLS is enabled on Kafka broker" "LOW" "PASS" \
                "Kafka broker at $host:$port has TLS enabled." "" ""

            # TLS-002: Check certificate expiry
            local cert_dates
            cert_dates=$(echo | timeout 10 openssl s_client -connect "$host:$port" -servername "$host" 2>/dev/null | openssl x509 -noout -dates 2>&1) || true

            if echo "$cert_dates" | grep -q "notAfter"; then
                local expiry
                expiry=$(echo "$cert_dates" | grep "notAfter" | cut -d= -f2)
                local expiry_epoch
                expiry_epoch=$(date -j -f "%b %d %H:%M:%S %Y %Z" "$expiry" +%s 2>/dev/null || date -d "$expiry" +%s 2>/dev/null || echo "0")
                local now_epoch
                now_epoch=$(date +%s)
                local days_left=$(( (expiry_epoch - now_epoch) / 86400 ))

                if [[ "$days_left" -lt 0 ]]; then
                    add_finding "TLS-002" "TLS/SSL" "Certificate EXPIRED" "CRITICAL" "FAIL" \
                        "The TLS certificate expired $((days_left * -1)) days ago." \
                        "Immediately renew the certificate." "$cert_dates"
                elif [[ "$days_left" -lt 30 ]]; then
                    add_finding "TLS-002" "TLS/SSL" "Certificate expires in $days_left days" "HIGH" "WARN" \
                        "Certificate will expire on $expiry ($days_left days remaining)." \
                        "Renew the certificate before expiry." "$cert_dates"
                elif [[ "$days_left" -lt 90 ]]; then
                    add_finding "TLS-002" "TLS/SSL" "Certificate expires in $days_left days" "MEDIUM" "WARN" \
                        "Certificate will expire on $expiry ($days_left days remaining)." \
                        "Plan certificate renewal." "$cert_dates"
                else
                    add_finding "TLS-002" "TLS/SSL" "Certificate valid for $days_left days" "LOW" "PASS" \
                        "Certificate expires on $expiry ($days_left days remaining)." "" "$cert_dates"
                fi
            fi

            # TLS-003: Check for weak ciphers
            local weak_ciphers
            weak_ciphers=$(echo | timeout 10 openssl s_client -connect "$host:$port" -cipher 'NULL:eNULL:aNULL:RC4:DES:3DES:MD5' 2>&1) || true

            if echo "$weak_ciphers" | grep -q "Cipher is"; then
                local cipher
                cipher=$(echo "$weak_ciphers" | grep "Cipher is" | awk '{print $NF}')
                if [[ "$cipher" != "0000" ]] && [[ "$cipher" != "(NONE)" ]]; then
                    add_finding "TLS-003" "TLS/SSL" "Weak ciphers accepted" "HIGH" "FAIL" \
                        "Broker accepts weak cipher: $cipher" \
                        "Configure ssl.cipher.suites to only allow strong ciphers (AES-256-GCM, CHACHA20)." \
                        "$weak_ciphers"
                else
                    add_finding "TLS-003" "TLS/SSL" "Weak ciphers rejected" "LOW" "PASS" \
                        "Broker correctly rejects weak cipher suites." "" ""
                fi
            else
                add_finding "TLS-003" "TLS/SSL" "Weak ciphers rejected" "LOW" "PASS" \
                    "Broker does not accept weak cipher suites." "" ""
            fi

            # TLS-004: Check TLS protocol version
            for proto in tls1 tls1_1; do
                local proto_test
                proto_test=$(echo | timeout 10 openssl s_client -connect "$host:$port" -"$proto" 2>&1) || true
                if echo "$proto_test" | grep -q "BEGIN CERTIFICATE"; then
                    local proto_name
                    proto_name=$(echo "$proto" | sed 's/tls1$/TLSv1.0/' | sed 's/tls1_1/TLSv1.1/')
                    add_finding "TLS-004-${proto}" "TLS/SSL" "Deprecated $proto_name supported" "HIGH" "FAIL" \
                        "Broker accepts deprecated $proto_name connections." \
                        "Disable TLSv1.0 and TLSv1.1. Set ssl.enabled.protocols=TLSv1.2,TLSv1.3" ""
                fi
            done

            # TLS-005: Check TLS 1.2+ support
            local tls12_test
            tls12_test=$(echo | timeout 10 openssl s_client -connect "$host:$port" -tls1_2 2>&1) || true
            if echo "$tls12_test" | grep -q "BEGIN CERTIFICATE"; then
                add_finding "TLS-005" "TLS/SSL" "TLSv1.2 supported" "LOW" "PASS" \
                    "Broker supports TLSv1.2." "" ""
            fi

            local tls13_test
            tls13_test=$(echo | timeout 10 openssl s_client -connect "$host:$port" -tls1_3 2>&1) || true
            if echo "$tls13_test" | grep -q "BEGIN CERTIFICATE"; then
                add_finding "TLS-005-v13" "TLS/SSL" "TLSv1.3 supported" "LOW" "PASS" \
                    "Broker supports TLSv1.3." "" ""
            fi

            # TLS-006: Check certificate chain
            local chain_output
            chain_output=$(echo | timeout 10 openssl s_client -connect "$host:$port" -servername "$host" -showcerts 2>&1) || true
            local chain_depth
            chain_depth=$(echo "$chain_output" | grep -c "BEGIN CERTIFICATE" || true)

            if [[ "$chain_depth" -lt 2 ]]; then
                add_finding "TLS-006" "TLS/SSL" "Self-signed or incomplete certificate chain" "MEDIUM" "WARN" \
                    "Certificate chain depth is $chain_depth. May be self-signed." \
                    "Use certificates signed by a trusted CA with complete chain." ""
            else
                add_finding "TLS-006" "TLS/SSL" "Certificate chain depth: $chain_depth" "LOW" "PASS" \
                    "Certificate chain appears complete." "" ""
            fi

        else
            add_finding "TLS-001" "TLS/SSL" "TLS is NOT enabled on Kafka broker" "CRITICAL" "FAIL" \
                "Kafka broker at $host:$port does not have TLS enabled. All traffic is in plaintext." \
                "Enable TLS by configuring ssl.keystore.location, ssl.keystore.password, ssl.truststore.location, and setting listeners to use SSL or SASL_SSL." \
                "$tls_output"
        fi
    else
        add_finding "TLS-001" "TLS/SSL" "OpenSSL not available - TLS scan skipped" "INFO" "INFO" \
            "Install openssl to enable TLS scanning." "" ""
    fi
}

###############################################################################
# CATEGORY 3: Authentication & Authorization
###############################################################################
run_auth_checks() {
    log_head "Category 3: Authentication & Authorization"

    local host port
    host=$(echo "$BOOTSTRAP" | cut -d: -f1)
    port=$(echo "$BOOTSTRAP" | cut -d: -f2)
    local kcat_cmd
    kcat_cmd=$(get_kcat_cmd)

    # AUTH-001: Test unauthenticated access
    if [[ -n "$kcat_cmd" ]]; then
        log_info "Testing unauthenticated access..."
        local unauth_output
        unauth_output=$($kcat_cmd -b "$host:$port" -L -t __consumer_offsets -J 2>&1 | head -50) || true

        if echo "$unauth_output" | grep -q '"brokers"'; then
            add_finding "AUTH-001" "Authentication" "Unauthenticated access allowed" "CRITICAL" "FAIL" \
                "Kafka broker allows unauthenticated connections and metadata retrieval." \
                "Enable SASL authentication. Configure listeners with SASL_PLAINTEXT or SASL_SSL protocol." \
                "$unauth_output"
        else
            add_finding "AUTH-001" "Authentication" "Unauthenticated access blocked" "LOW" "PASS" \
                "Kafka broker requires authentication for connections." "" ""
        fi

        # AUTH-002: Test if PLAINTEXT listener exists
        local plaintext_test
        plaintext_test=$($kcat_cmd -b "$host:$port" -X security.protocol=PLAINTEXT -L -J 2>&1 | head -50) || true
        if echo "$plaintext_test" | grep -q '"brokers"'; then
            add_finding "AUTH-002" "Authentication" "PLAINTEXT listener active" "HIGH" "WARN" \
                "A PLAINTEXT (non-encrypted, non-authenticated) listener is available." \
                "Remove PLAINTEXT listeners. Use SASL_SSL for all client connections." ""
        else
            add_finding "AUTH-002" "Authentication" "No PLAINTEXT listener detected" "LOW" "PASS" \
                "PLAINTEXT listener is not accessible." "" ""
        fi
    else
        add_finding "AUTH-001" "Authentication" "kcat not available - auth test limited" "INFO" "INFO" \
            "Install kcat to enable authentication testing." "" ""
    fi

    # AUTH-003: Check ACLs via Kafka CLI
    local kafka_acls
    kafka_acls=$(get_kafka_cmd "kafka-acls")
    if [[ -n "$kafka_acls" ]]; then
        local props_file
        props_file=$(build_kafka_cli_props)
        log_info "Checking ACL configuration..."
        local acl_output
        acl_output=$("$kafka_acls" --bootstrap-server "$BOOTSTRAP" --command-config "$props_file" --list 2>&1) || true
        rm -f "$props_file"

        if echo "$acl_output" | grep -qi "no.*acl"; then
            add_finding "AUTH-003" "Authorization" "No ACLs configured" "HIGH" "FAIL" \
                "No ACLs are configured on the cluster. If authorizer is enabled, all access defaults to allow/deny based on allow.everyone.if.no.acl.found." \
                "Configure topic-level and consumer group ACLs for all applications." \
                "$acl_output"
        elif echo "$acl_output" | grep -qi "User:\*"; then
            add_finding "AUTH-003" "Authorization" "Wildcard ACL detected (User:*)" "HIGH" "WARN" \
                "A wildcard ACL granting access to all users was found." \
                "Replace wildcard ACLs with specific user/group permissions." \
                "$acl_output"
        elif echo "$acl_output" | grep -qi "AclEntry"; then
            local acl_count
            acl_count=$(echo "$acl_output" | grep -c "AclEntry" || true)
            add_finding "AUTH-003" "Authorization" "ACLs configured ($acl_count entries)" "LOW" "PASS" \
                "Found $acl_count ACL entries." "" "$acl_output"
        else
            add_finding "AUTH-003" "Authorization" "ACL check inconclusive" "MEDIUM" "WARN" \
                "Could not determine ACL status. Ensure authorizer is enabled." \
                "Set authorizer.class.name=kafka.security.authorizer.AclAuthorizer in broker config." \
                "$acl_output"
        fi
    fi

    # AUTH-004: Check for inter-broker authentication
    local kafka_configs
    kafka_configs=$(get_kafka_cmd "kafka-configs")
    if [[ -n "$kafka_configs" ]]; then
        local props_file
        props_file=$(build_kafka_cli_props)
        log_info "Checking broker security configuration..."
        local broker_config
        broker_config=$("$kafka_configs" --bootstrap-server "$BOOTSTRAP" --command-config "$props_file" --entity-type brokers --entity-default --describe 2>&1) || true
        rm -f "$props_file"

        if echo "$broker_config" | grep -qi "inter.broker.listener.name\|security.inter.broker.protocol"; then
            if echo "$broker_config" | grep -qi "SASL_SSL\|SASL_PLAINTEXT"; then
                add_finding "AUTH-004" "Authentication" "Inter-broker authentication enabled" "LOW" "PASS" \
                    "Inter-broker communication uses SASL authentication." "" "$broker_config"
            else
                add_finding "AUTH-004" "Authentication" "Inter-broker auth may not use SASL" "MEDIUM" "WARN" \
                    "Inter-broker security protocol may not include SASL authentication." \
                    "Set security.inter.broker.protocol=SASL_SSL for inter-broker authentication." \
                    "$broker_config"
            fi
        fi
    fi
}

###############################################################################
# CATEGORY 4: Kafka Configuration Security
###############################################################################
run_config_checks() {
    log_head "Category 4: Kafka Configuration Security"

    local kafka_configs
    kafka_configs=$(get_kafka_cmd "kafka-configs")
    local kcat_cmd
    kcat_cmd=$(get_kcat_cmd)

    if [[ -n "$kafka_configs" ]]; then
        local props_file
        props_file=$(build_kafka_cli_props)

        # CFG-001: Check for auto.create.topics.enable
        log_info "Checking broker configurations..."
        local all_config
        all_config=$("$kafka_configs" --bootstrap-server "$BOOTSTRAP" --command-config "$props_file" --entity-type brokers --entity-default --describe --all 2>&1) || true

        if echo "$all_config" | grep -q "auto.create.topics.enable=true"; then
            add_finding "CFG-001" "Configuration" "auto.create.topics.enable is true" "MEDIUM" "WARN" \
                "Topics are automatically created when producers/consumers reference non-existent topics." \
                "Set auto.create.topics.enable=false to prevent unauthorized topic creation." ""
        elif echo "$all_config" | grep -q "auto.create.topics.enable=false"; then
            add_finding "CFG-001" "Configuration" "auto.create.topics.enable is false" "LOW" "PASS" \
                "Auto topic creation is disabled." "" ""
        fi

        # CFG-002: Check delete.topic.enable
        if echo "$all_config" | grep -q "delete.topic.enable=true"; then
            add_finding "CFG-002" "Configuration" "Topic deletion is enabled" "MEDIUM" "WARN" \
                "Topics can be deleted. Ensure ACLs restrict who can delete topics." \
                "If topic deletion is not needed, set delete.topic.enable=false." ""
        fi

        # CFG-003: Check for message size limits
        local max_msg
        max_msg=$(echo "$all_config" | grep "message.max.bytes" | head -1 | cut -d= -f2 | tr -d ' ' || echo "")
        if [[ -n "$max_msg" ]]; then
            if [[ "$max_msg" -gt 10485760 ]]; then
                add_finding "CFG-003" "Configuration" "Large max message size: $(( max_msg / 1048576 ))MB" "MEDIUM" "WARN" \
                    "message.max.bytes=$max_msg ($(( max_msg / 1048576 ))MB). Large messages can cause broker instability." \
                    "Consider reducing to 1MB default or use chunking patterns." ""
            else
                add_finding "CFG-003" "Configuration" "Max message size within limits" "LOW" "PASS" \
                    "message.max.bytes=$max_msg" "" ""
            fi
        fi

        # CFG-004: Check log retention
        local retention
        retention=$(echo "$all_config" | grep "log.retention.hours\|log.retention.ms\|log.retention.minutes" | head -1 || echo "")
        if [[ -n "$retention" ]]; then
            add_finding "CFG-004" "Configuration" "Log retention configured: $retention" "INFO" "INFO" \
                "Log retention policy: $retention" \
                "Ensure retention aligns with data compliance requirements." ""
        fi

        # CFG-005: Check for advertised listeners mismatch
        local advertised
        advertised=$(echo "$all_config" | grep "advertised.listeners" | head -1 || echo "")
        if echo "$advertised" | grep -qi "0.0.0.0\|PLAINTEXT://0.0.0.0"; then
            add_finding "CFG-005" "Configuration" "Advertised listeners use 0.0.0.0" "HIGH" "FAIL" \
                "Advertised listeners should not use 0.0.0.0 as it can cause client connection issues and security concerns." \
                "Set advertised.listeners to specific hostnames or IPs." "$advertised"
        fi

        # CFG-006: Check authorizer configuration
        if echo "$all_config" | grep -qi "authorizer.class.name"; then
            local auth_class
            auth_class=$(echo "$all_config" | grep "authorizer.class.name" | head -1 | cut -d= -f2 || echo "")
            if [[ -n "$auth_class" ]] && [[ "$auth_class" != " " ]]; then
                add_finding "CFG-006" "Configuration" "Authorizer enabled: $auth_class" "LOW" "PASS" \
                    "ACL authorizer is configured." "" ""
            else
                add_finding "CFG-006" "Configuration" "No authorizer configured" "HIGH" "FAIL" \
                    "No ACL authorizer is configured. All authenticated users have unrestricted access." \
                    "Set authorizer.class.name=kafka.security.authorizer.AclAuthorizer (or org.apache.kafka.metadata.authorizer.StandardAuthorizer for KRaft)." ""
            fi
        else
            add_finding "CFG-006" "Configuration" "Authorizer not detected in config" "HIGH" "WARN" \
                "Could not confirm authorizer configuration." \
                "Ensure authorizer.class.name is set in broker configuration." "$all_config"
        fi

        rm -f "$props_file"
    fi

    # CFG-007: Check cluster metadata via kcat
    if [[ -n "$kcat_cmd" ]]; then
        local kcat_args
        kcat_args=$(build_kcat_args)
        local metadata
        metadata=$($kcat_cmd $kcat_args -L -J 2>&1) || true

        if echo "$metadata" | jq -e '.brokers' &>/dev/null; then
            local broker_count
            broker_count=$(echo "$metadata" | jq '.brokers | length')
            local topic_count
            topic_count=$(echo "$metadata" | jq '.topics | length')

            add_finding "CFG-007" "Configuration" "Cluster has $broker_count brokers, $topic_count topics" "INFO" "INFO" \
                "Cluster metadata: $broker_count broker(s), $topic_count topic(s)." "" ""

            # CFG-008: Check for single broker (no HA)
            if [[ "$broker_count" -lt 2 ]]; then
                add_finding "CFG-008" "Configuration" "Single broker - no high availability" "HIGH" "WARN" \
                    "Only $broker_count broker found. Single broker setup has no fault tolerance." \
                    "Deploy at least 3 brokers for production high availability." ""
            elif [[ "$broker_count" -lt 3 ]]; then
                add_finding "CFG-008" "Configuration" "Only $broker_count brokers - limited HA" "MEDIUM" "WARN" \
                    "2 broker setup provides limited fault tolerance." \
                    "Deploy at least 3 brokers for production." ""
            else
                add_finding "CFG-008" "Configuration" "Cluster has $broker_count brokers" "LOW" "PASS" \
                    "Sufficient brokers for high availability." "" ""
            fi

            # CFG-009: Check for internal topics exposure
            local internal_topics
            internal_topics=$(echo "$metadata" | jq -r '.topics[].topic' 2>/dev/null | grep -E '^__' || true)
            if [[ -n "$internal_topics" ]]; then
                local internal_count
                internal_count=$(echo "$internal_topics" | wc -l | tr -d ' ')
                add_finding "CFG-009" "Configuration" "Internal topics visible ($internal_count)" "MEDIUM" "WARN" \
                    "Internal/system topics are accessible: $internal_topics" \
                    "Restrict access to internal topics (__consumer_offsets, __transaction_state, etc.) via ACLs." ""
            fi

            # CFG-010: Check replication factors
            local under_replicated
            under_replicated=$(echo "$metadata" | jq '[.topics[] | select(.partitions[].replicas | length < 2)] | length' 2>/dev/null || echo "0")
            if [[ "$under_replicated" -gt 0 ]]; then
                add_finding "CFG-010" "Configuration" "$under_replicated topics with replication factor < 2" "HIGH" "WARN" \
                    "Topics with replication factor 1 have no data redundancy." \
                    "Set min.insync.replicas=2 and use replication factor >= 3 for critical topics." ""
            else
                add_finding "CFG-010" "Configuration" "All topics have adequate replication" "LOW" "PASS" \
                    "All topics have replication factor >= 2." "" ""
            fi
        fi
    fi
}

###############################################################################
# CATEGORY 5: Data Security
###############################################################################
run_data_checks() {
    log_head "Category 5: Data Security"

    local kcat_cmd
    kcat_cmd=$(get_kcat_cmd)

    if [[ -n "$kcat_cmd" ]]; then
        local kcat_args
        kcat_args=$(build_kcat_args)

        # DATA-001: Check if sensitive topics are readable
        log_info "Checking topic access controls..."
        local metadata
        metadata=$($kcat_cmd $kcat_args -L -J 2>&1) || true

        if echo "$metadata" | jq -e '.topics' &>/dev/null; then
            local topics
            topics=$(echo "$metadata" | jq -r '.topics[].topic' 2>/dev/null | grep -v '^__' || true)

            # DATA-002: Check for topics with sensitive-looking names
            local sensitive_topics
            sensitive_topics=$(echo "$topics" | grep -iE 'password|secret|key|token|credential|pii|ssn|credit.card|payment' || true)
            if [[ -n "$sensitive_topics" ]]; then
                add_finding "DATA-002" "Data Security" "Topics with sensitive names detected" "HIGH" "WARN" \
                    "Topics with potentially sensitive names found: $sensitive_topics" \
                    "Ensure these topics have strict ACLs and encryption. Consider topic naming conventions." ""
            else
                add_finding "DATA-002" "Data Security" "No obviously sensitive topic names" "LOW" "PASS" \
                    "No topics with obviously sensitive names detected." "" ""
            fi

            # DATA-003: Try reading from a random topic (data exposure test)
            local first_topic
            first_topic=$(echo "$topics" | head -1)
            if [[ -n "$first_topic" ]]; then
                local read_test
                read_test=$($kcat_cmd $kcat_args -C -t "$first_topic" -c 1 -e -o end 2>&1 | head -5) || true
                if [[ -n "$read_test" ]] && ! echo "$read_test" | grep -qi "error\|denied\|unauthorized"; then
                    add_finding "DATA-003" "Data Security" "Topic data readable: $first_topic" "MEDIUM" "INFO" \
                        "Successfully read from topic '$first_topic' with current credentials." \
                        "Ensure read access is restricted via ACLs to authorized consumers only." ""
                fi
            fi
        fi
    fi

    # DATA-004: Encryption at rest check (informational)
    add_finding "DATA-004" "Data Security" "Encryption at rest - manual verification needed" "MEDIUM" "INFO" \
        "Kafka does not natively support encryption at rest. This must be verified at the storage/OS level." \
        "Use disk encryption (LUKS, BitLocker) or cloud-managed encrypted storage for Kafka log directories." ""
}

###############################################################################
# CATEGORY 6: Operational Security
###############################################################################
run_ops_checks() {
    log_head "Category 6: Operational Security"

    local kcat_cmd
    kcat_cmd=$(get_kcat_cmd)

    # OPS-001: Check JMX port exposure
    if command -v nmap &>/dev/null; then
        local host
        host=$(echo "$BOOTSTRAP" | cut -d: -f1)
        local jmx_scan
        jmx_scan=$(nmap -sV -p 9999,1099,7199 "$host" 2>&1) || true
        if echo "$jmx_scan" | grep -q "open"; then
            add_finding "OPS-001" "Operations" "JMX port exposed" "HIGH" "FAIL" \
                "JMX management ports are accessible. Unauthenticated JMX allows remote code execution." \
                "Enable JMX authentication and SSL, or restrict JMX to localhost only." \
                "$jmx_scan"
        else
            add_finding "OPS-001" "Operations" "JMX ports not externally exposed" "LOW" "PASS" \
                "Common JMX ports (9999, 1099, 7199) are not accessible." "" ""
        fi
    fi

    # OPS-002: Consumer group check
    local kafka_groups
    kafka_groups=$(get_kafka_cmd "kafka-consumer-groups")
    if [[ -n "$kafka_groups" ]]; then
        local props_file
        props_file=$(build_kafka_cli_props)
        local groups_output
        groups_output=$("$kafka_groups" --bootstrap-server "$BOOTSTRAP" --command-config "$props_file" --list 2>&1) || true
        rm -f "$props_file"

        if [[ -n "$groups_output" ]]; then
            local group_count
            group_count=$(echo "$groups_output" | grep -c '\S' || true)
            add_finding "OPS-002" "Operations" "$group_count consumer groups active" "INFO" "INFO" \
                "Found $group_count consumer group(s)." \
                "Regularly audit consumer groups to ensure only authorized consumers are connected." \
                "$groups_output"
        fi
    fi

    # OPS-003: Check Kafka Connect exposure
    if command -v nmap &>/dev/null; then
        local host
        host=$(echo "$BOOTSTRAP" | cut -d: -f1)
        local connect_scan
        connect_scan=$(nmap -sV -p 8083 "$host" 2>&1) || true
        if echo "$connect_scan" | grep -q "open"; then
            add_finding "OPS-003" "Operations" "Kafka Connect REST API exposed" "HIGH" "WARN" \
                "Kafka Connect REST API on port 8083 is accessible. This can be used to deploy arbitrary connectors." \
                "Restrict Kafka Connect REST API access. Enable authentication for Connect." \
                "$connect_scan"
        else
            add_finding "OPS-003" "Operations" "Kafka Connect not externally exposed" "LOW" "PASS" \
                "Kafka Connect REST API port 8083 is not accessible." "" ""
        fi
    fi

    # OPS-004: Schema Registry exposure
    if command -v nmap &>/dev/null; then
        local host
        host=$(echo "$BOOTSTRAP" | cut -d: -f1)
        local sr_scan
        sr_scan=$(nmap -sV -p 8081 "$host" 2>&1) || true
        if echo "$sr_scan" | grep -q "open"; then
            add_finding "OPS-004" "Operations" "Schema Registry exposed" "MEDIUM" "WARN" \
                "Schema Registry on port 8081 is accessible." \
                "Enable authentication for Schema Registry and restrict network access." \
                "$sr_scan"
        fi
    fi
}

###############################################################################
# CATEGORY 7: ksqlDB Security
###############################################################################
run_ksqldb_checks() {
    log_head "Category 7: ksqlDB Security"

    local host
    host=$(echo "$BOOTSTRAP" | cut -d: -f1)

    # Auto-detect ksqlDB URL if not provided
    if [[ -z "$KSQLDB_URL" ]]; then
        KSQLDB_URL="http://${host}:8088"
    fi

    local ksqldb_host ksqldb_port ksqldb_scheme
    ksqldb_scheme=$(echo "$KSQLDB_URL" | sed -E 's|^([a-z]+)://.*|\1|' || echo "http")
    ksqldb_host=$(echo "$KSQLDB_URL" | sed -E 's|^https?://||' | cut -d: -f1)
    ksqldb_port=$(echo "$KSQLDB_URL" | sed -E 's|^https?://||' | cut -d: -f2 | tr -d '/')
    [[ -z "$ksqldb_port" || "$ksqldb_port" == "$ksqldb_host" ]] && ksqldb_port="8088"

    log_info "Scanning ksqlDB at ${KSQLDB_URL}..."

    # ──────────────────────────────────────────────────────────────────────────
    # KSQL-001: ksqlDB port exposure / reachability
    # ──────────────────────────────────────────────────────────────────────────
    local ksql_reachable=false
    if command -v nmap &>/dev/null; then
        local ksql_port_scan
        ksql_port_scan=$(nmap -sV -p "$ksqldb_port" "$ksqldb_host" 2>&1) || true
        if echo "$ksql_port_scan" | grep -q "open"; then
            add_finding "KSQL-001" "ksqlDB" "ksqlDB port $ksqldb_port is open" "HIGH" "WARN" \
                "ksqlDB REST API port $ksqldb_port is exposed on $ksqldb_host. The ksqlDB REST API allows arbitrary query execution including CREATE, DROP, INSERT, and SELECT." \
                "Restrict ksqlDB port access to trusted networks only. Use firewall rules or network policies to block external access." \
                "$ksql_port_scan"
            ksql_reachable=true
        else
            add_finding "KSQL-001" "ksqlDB" "ksqlDB port $ksqldb_port is not exposed" "LOW" "PASS" \
                "ksqlDB REST API port $ksqldb_port is not accessible on $ksqldb_host." "" "$ksql_port_scan"
        fi
    else
        # Fallback: use nc or curl to test
        if nc -z "$ksqldb_host" "$ksqldb_port" 2>/dev/null; then
            add_finding "KSQL-001" "ksqlDB" "ksqlDB port $ksqldb_port is reachable" "HIGH" "WARN" \
                "ksqlDB REST API port $ksqldb_port is reachable on $ksqldb_host." \
                "Restrict ksqlDB port access to trusted networks only." ""
            ksql_reachable=true
        else
            add_finding "KSQL-001" "ksqlDB" "ksqlDB port $ksqldb_port is not reachable" "LOW" "PASS" \
                "ksqlDB REST API port $ksqldb_port is not reachable." "" ""
        fi
    fi

    # If ksqlDB is not reachable, skip remaining ksqlDB checks
    if [[ "$ksql_reachable" == false ]]; then
        log_info "ksqlDB not reachable, skipping remaining ksqlDB checks"
        return 0
    fi

    # ──────────────────────────────────────────────────────────────────────────
    # KSQL-002: Unauthenticated ksqlDB REST API access
    # ──────────────────────────────────────────────────────────────────────────
    if command -v curl &>/dev/null; then
        log_info "Testing unauthenticated ksqlDB access..."
        local ksql_info
        ksql_info=$(curl -s --max-time 10 "${KSQLDB_URL}/info" 2>&1) || true

        if echo "$ksql_info" | jq -e '.KsqlServerInfo' &>/dev/null 2>&1; then
            local ksql_version ksql_cluster_id ksql_service_id
            ksql_version=$(echo "$ksql_info" | jq -r '.KsqlServerInfo.version // "unknown"')
            ksql_cluster_id=$(echo "$ksql_info" | jq -r '.KsqlServerInfo.kafkaClusterId // "unknown"')
            ksql_service_id=$(echo "$ksql_info" | jq -r '.KsqlServerInfo.ksqlServiceId // "unknown"')

            add_finding "KSQL-002" "ksqlDB" "Unauthenticated ksqlDB access allowed" "CRITICAL" "FAIL" \
                "ksqlDB REST API at ${KSQLDB_URL} is accessible without authentication. Version: ${ksql_version}, Service ID: ${ksql_service_id}, Kafka Cluster: ${ksql_cluster_id}. An attacker can execute arbitrary queries, create/drop streams and tables, and access Kafka topic data." \
                "Enable ksqlDB authentication by configuring authentication.method=BASIC and setting up credentials. For production, use ksql.authentication.plugin.class with a custom auth plugin or deploy behind an authenticating reverse proxy." \
                "$ksql_info"
        elif echo "$ksql_info" | grep -qi "401\|unauthorized\|forbidden\|authentication"; then
            add_finding "KSQL-002" "ksqlDB" "ksqlDB requires authentication" "LOW" "PASS" \
                "ksqlDB REST API requires authentication." "" ""
        else
            add_finding "KSQL-002" "ksqlDB" "ksqlDB info endpoint check inconclusive" "MEDIUM" "INFO" \
                "Could not determine ksqlDB authentication status. Response: $(echo "$ksql_info" | head -c 200)" \
                "Manually verify ksqlDB authentication configuration." "$ksql_info"
        fi

        # ──────────────────────────────────────────────────────────────────────
        # KSQL-003: ksqlDB TLS/HTTPS check
        # ──────────────────────────────────────────────────────────────────────
        if [[ "$ksqldb_scheme" == "https" ]]; then
            # Verify TLS is actually working
            if command -v openssl &>/dev/null; then
                local ksql_tls
                ksql_tls=$(echo | timeout 10 openssl s_client -connect "${ksqldb_host}:${ksqldb_port}" -servername "$ksqldb_host" 2>&1) || true
                if echo "$ksql_tls" | grep -q "BEGIN CERTIFICATE"; then
                    add_finding "KSQL-003" "ksqlDB" "ksqlDB uses HTTPS/TLS" "LOW" "PASS" \
                        "ksqlDB is configured with TLS encryption." "" ""

                    # Check cert expiry
                    local ksql_cert_dates
                    ksql_cert_dates=$(echo | timeout 10 openssl s_client -connect "${ksqldb_host}:${ksqldb_port}" -servername "$ksqldb_host" 2>/dev/null | openssl x509 -noout -dates 2>&1) || true
                    if echo "$ksql_cert_dates" | grep -q "notAfter"; then
                        local ksql_expiry
                        ksql_expiry=$(echo "$ksql_cert_dates" | grep "notAfter" | cut -d= -f2)
                        local ksql_expiry_epoch
                        ksql_expiry_epoch=$(date -j -f "%b %d %H:%M:%S %Y %Z" "$ksql_expiry" +%s 2>/dev/null || date -d "$ksql_expiry" +%s 2>/dev/null || echo "0")
                        local now_epoch
                        now_epoch=$(date +%s)
                        local ksql_days_left=$(( (ksql_expiry_epoch - now_epoch) / 86400 ))

                        if [[ "$ksql_days_left" -lt 30 ]]; then
                            add_finding "KSQL-003b" "ksqlDB" "ksqlDB TLS certificate expires in $ksql_days_left days" "HIGH" "WARN" \
                                "ksqlDB TLS certificate will expire on $ksql_expiry ($ksql_days_left days remaining)." \
                                "Renew the ksqlDB TLS certificate." "$ksql_cert_dates"
                        fi
                    fi
                else
                    add_finding "KSQL-003" "ksqlDB" "ksqlDB HTTPS configured but TLS handshake failed" "HIGH" "FAIL" \
                        "ksqlDB URL uses HTTPS but TLS handshake failed." \
                        "Verify ksqlDB TLS configuration: ssl.keystore.location, ssl.keystore.password." "$ksql_tls"
                fi
            fi
        else
            add_finding "KSQL-003" "ksqlDB" "ksqlDB uses HTTP (no TLS)" "HIGH" "FAIL" \
                "ksqlDB REST API is accessible over plain HTTP at ${KSQLDB_URL}. All queries, data, and credentials are transmitted in cleartext." \
                "Configure ksqlDB to use HTTPS by setting listeners=https://0.0.0.0:8088 and configuring ssl.keystore.location, ssl.keystore.password, ssl.key.password." ""
        fi

        # ──────────────────────────────────────────────────────────────────────
        # KSQL-004: Arbitrary query execution test
        # ──────────────────────────────────────────────────────────────────────
        log_info "Testing ksqlDB query execution..."
        local ksql_query_resp
        ksql_query_resp=$(curl -s --max-time 15 \
            -H "Content-Type: application/vnd.ksql.v1+json" \
            -X POST "${KSQLDB_URL}/ksql" \
            -d '{"ksql": "SHOW STREAMS;", "streamsProperties": {}}' 2>&1) || true

        if echo "$ksql_query_resp" | jq -e '.[0].streams' &>/dev/null 2>&1; then
            local stream_count
            stream_count=$(echo "$ksql_query_resp" | jq '.[0].streams | length' 2>/dev/null || echo "0")
            add_finding "KSQL-004" "ksqlDB" "ksqlDB allows arbitrary SHOW STREAMS ($stream_count streams)" "CRITICAL" "FAIL" \
                "Unauthenticated execution of SHOW STREAMS succeeded and returned $stream_count stream(s). This means anyone with network access can execute DDL/DML statements, read data, and modify the ksqlDB topology." \
                "Enable authentication immediately. Restrict network access to the ksqlDB port." \
                "$(echo "$ksql_query_resp" | head -c 500)"
        elif echo "$ksql_query_resp" | grep -qi "401\|unauthorized\|forbidden"; then
            add_finding "KSQL-004" "ksqlDB" "ksqlDB blocks unauthenticated queries" "LOW" "PASS" \
                "Query execution requires authentication." "" ""
        elif [[ -n "$ksql_query_resp" ]]; then
            add_finding "KSQL-004" "ksqlDB" "ksqlDB query execution check inconclusive" "MEDIUM" "INFO" \
                "Could not conclusively determine if queries are executable without auth." \
                "Manually verify ksqlDB authentication is enforced." \
                "$(echo "$ksql_query_resp" | head -c 300)"
        fi

        # ──────────────────────────────────────────────────────────────────────
        # KSQL-005: SHOW TABLES check (data exposure)
        # ──────────────────────────────────────────────────────────────────────
        local ksql_tables_resp
        ksql_tables_resp=$(curl -s --max-time 15 \
            -H "Content-Type: application/vnd.ksql.v1+json" \
            -X POST "${KSQLDB_URL}/ksql" \
            -d '{"ksql": "SHOW TABLES;", "streamsProperties": {}}' 2>&1) || true

        if echo "$ksql_tables_resp" | jq -e '.[0].tables' &>/dev/null 2>&1; then
            local table_count
            table_count=$(echo "$ksql_tables_resp" | jq '.[0].tables | length' 2>/dev/null || echo "0")
            if [[ "$table_count" -gt 0 ]]; then
                add_finding "KSQL-005" "ksqlDB" "ksqlDB exposes $table_count materialized table(s)" "HIGH" "WARN" \
                    "SHOW TABLES returned $table_count table(s). Materialized tables may contain aggregated sensitive data accessible via pull queries." \
                    "Restrict access to ksqlDB tables via authentication and network controls." \
                    "$(echo "$ksql_tables_resp" | head -c 500)"
            else
                add_finding "KSQL-005" "ksqlDB" "No ksqlDB materialized tables found" "LOW" "PASS" \
                    "SHOW TABLES returned 0 tables." "" ""
            fi
        fi

        # ──────────────────────────────────────────────────────────────────────
        # KSQL-006: SHOW QUERIES check (running persistent queries)
        # ──────────────────────────────────────────────────────────────────────
        local ksql_queries_resp
        ksql_queries_resp=$(curl -s --max-time 15 \
            -H "Content-Type: application/vnd.ksql.v1+json" \
            -X POST "${KSQLDB_URL}/ksql" \
            -d '{"ksql": "SHOW QUERIES;", "streamsProperties": {}}' 2>&1) || true

        if echo "$ksql_queries_resp" | jq -e '.[0].queries' &>/dev/null 2>&1; then
            local query_count
            query_count=$(echo "$ksql_queries_resp" | jq '.[0].queries | length' 2>/dev/null || echo "0")
            if [[ "$query_count" -gt 0 ]]; then
                add_finding "KSQL-006" "ksqlDB" "$query_count persistent ksqlDB queries running" "MEDIUM" "INFO" \
                    "Found $query_count running persistent queries. Persistent queries continuously process data from Kafka topics." \
                    "Audit persistent queries regularly. Ensure TERMINATE QUERY is restricted via ACLs." \
                    "$(echo "$ksql_queries_resp" | head -c 500)"
            else
                add_finding "KSQL-006" "ksqlDB" "No persistent ksqlDB queries running" "LOW" "INFO" \
                    "No persistent queries detected." "" ""
            fi
        fi

        # ──────────────────────────────────────────────────────────────────────
        # KSQL-007: SHOW TOPICS via ksqlDB (Kafka topic enumeration)
        # ──────────────────────────────────────────────────────────────────────
        local ksql_topics_resp
        ksql_topics_resp=$(curl -s --max-time 15 \
            -H "Content-Type: application/vnd.ksql.v1+json" \
            -X POST "${KSQLDB_URL}/ksql" \
            -d '{"ksql": "SHOW TOPICS;", "streamsProperties": {}}' 2>&1) || true

        if echo "$ksql_topics_resp" | jq -e '.[0].topics' &>/dev/null 2>&1; then
            local topic_count
            topic_count=$(echo "$ksql_topics_resp" | jq '.[0].topics | length' 2>/dev/null || echo "0")
            add_finding "KSQL-007" "ksqlDB" "ksqlDB exposes $topic_count Kafka topics" "HIGH" "WARN" \
                "SHOW TOPICS via ksqlDB returned $topic_count topic(s). ksqlDB provides an easy enumeration path to discover all Kafka topics without direct broker access." \
                "Restrict ksqlDB access. Topic-level ACLs on the Kafka broker do not prevent enumeration via ksqlDB SHOW TOPICS." \
                "$(echo "$ksql_topics_resp" | head -c 500)"
        fi

        # ──────────────────────────────────────────────────────────────────────
        # KSQL-008: DESCRIBE EXTENDED on streams (schema exposure)
        # ──────────────────────────────────────────────────────────────────────
        if echo "$ksql_query_resp" | jq -e '.[0].streams[0].name' &>/dev/null 2>&1; then
            local first_stream
            first_stream=$(echo "$ksql_query_resp" | jq -r '.[0].streams[0].name' 2>/dev/null)
            if [[ -n "$first_stream" ]] && [[ "$first_stream" != "null" ]]; then
                local describe_resp
                describe_resp=$(curl -s --max-time 15 \
                    -H "Content-Type: application/vnd.ksql.v1+json" \
                    -X POST "${KSQLDB_URL}/ksql" \
                    -d "{\"ksql\": \"DESCRIBE ${first_stream} EXTENDED;\", \"streamsProperties\": {}}" 2>&1) || true

                if echo "$describe_resp" | jq -e '.[0].sourceDescription' &>/dev/null 2>&1; then
                    local fields_info
                    fields_info=$(echo "$describe_resp" | jq -r '.[0].sourceDescription.fields[].name' 2>/dev/null | tr '\n' ', ' || echo "")
                    local topic_name
                    topic_name=$(echo "$describe_resp" | jq -r '.[0].sourceDescription.topic // "unknown"' 2>/dev/null)

                    add_finding "KSQL-008" "ksqlDB" "ksqlDB stream schema exposed: $first_stream" "MEDIUM" "WARN" \
                        "DESCRIBE EXTENDED on stream '${first_stream}' reveals schema details including field names (${fields_info}) and underlying Kafka topic (${topic_name}). This aids reconnaissance." \
                        "Enable ksqlDB authentication to prevent unauthorized schema discovery." \
                        "$(echo "$describe_resp" | head -c 500)"
                fi
            fi
        fi

        # ──────────────────────────────────────────────────────────────────────
        # KSQL-009: ksqlDB command topic access
        # ──────────────────────────────────────────────────────────────────────
        local kcat_cmd
        kcat_cmd=$(get_kcat_cmd)
        if [[ -n "$kcat_cmd" ]]; then
            log_info "Checking ksqlDB command topic access..."
            local kcat_args
            kcat_args=$(build_kcat_args)

            # ksqlDB stores its metadata in _confluent-ksql-<service_id>command_topic
            local ksql_cmd_topics
            ksql_cmd_topics=$($kcat_cmd $kcat_args -L -J 2>&1 | jq -r '.topics[].topic' 2>/dev/null | grep -i "ksql.*command" || true)

            if [[ -n "$ksql_cmd_topics" ]]; then
                add_finding "KSQL-009" "ksqlDB" "ksqlDB command topic accessible" "HIGH" "WARN" \
                    "ksqlDB command topic(s) detected: $ksql_cmd_topics. The command topic stores all ksqlDB DDL/DML statements including CREATE STREAM/TABLE definitions. Reading it reveals the complete ksqlDB topology." \
                    "Restrict access to ksqlDB command topics via Kafka ACLs. Set ksql.service.id to a unique value and protect the corresponding _confluent-ksql-<id>command_topic." ""
            else
                add_finding "KSQL-009" "ksqlDB" "No ksqlDB command topics detected" "LOW" "PASS" \
                    "No ksqlDB command topics found in topic listing." "" ""
            fi
        fi

        # ──────────────────────────────────────────────────────────────────────
        # KSQL-010: ksqlDB processing log topic exposure
        # ──────────────────────────────────────────────────────────────────────
        if [[ -n "$kcat_cmd" ]]; then
            local kcat_args
            kcat_args=$(build_kcat_args)
            local ksql_log_topics
            ksql_log_topics=$($kcat_cmd $kcat_args -L -J 2>&1 | jq -r '.topics[].topic' 2>/dev/null | grep -iE "ksql.*processing.*log|KSQL_PROCESSING_LOG" || true)

            if [[ -n "$ksql_log_topics" ]]; then
                add_finding "KSQL-010" "ksqlDB" "ksqlDB processing log topic exposed" "MEDIUM" "WARN" \
                    "ksqlDB processing log topic(s) detected: $ksql_log_topics. Processing logs may contain row-level data from failed records, including sensitive field values." \
                    "Restrict ACL access to processing log topics. Consider setting ksql.logging.processing.rows.include=false to prevent data leakage in logs." ""
            else
                add_finding "KSQL-010" "ksqlDB" "No ksqlDB processing log topics exposed" "LOW" "PASS" \
                    "No ksqlDB processing log topics found." "" ""
            fi
        fi

        # ──────────────────────────────────────────────────────────────────────
        # KSQL-011: ksqlDB healthcheck endpoint
        # ──────────────────────────────────────────────────────────────────────
        local ksql_health
        ksql_health=$(curl -s --max-time 10 "${KSQLDB_URL}/healthcheck" 2>&1) || true
        if echo "$ksql_health" | jq -e '.isHealthy' &>/dev/null 2>&1; then
            local is_healthy
            is_healthy=$(echo "$ksql_health" | jq -r '.isHealthy' 2>/dev/null)
            add_finding "KSQL-011" "ksqlDB" "ksqlDB healthcheck endpoint exposed (healthy=$is_healthy)" "MEDIUM" "WARN" \
                "The /healthcheck endpoint is publicly accessible and reveals server health status. This aids attacker reconnaissance." \
                "Restrict healthcheck endpoint access to monitoring systems only via network policies or reverse proxy rules." \
                "$ksql_health"
        fi

        # ──────────────────────────────────────────────────────────────────────
        # KSQL-012: ksqlDB server status/cluster status endpoint
        # ──────────────────────────────────────────────────────────────────────
        local ksql_cluster_status
        ksql_cluster_status=$(curl -s --max-time 10 "${KSQLDB_URL}/clusterStatus" 2>&1) || true
        if echo "$ksql_cluster_status" | jq -e '.clusterStatus' &>/dev/null 2>&1; then
            local node_count
            node_count=$(echo "$ksql_cluster_status" | jq '.clusterStatus | length' 2>/dev/null || echo "0")
            add_finding "KSQL-012" "ksqlDB" "ksqlDB cluster status exposed ($node_count nodes)" "MEDIUM" "WARN" \
                "The /clusterStatus endpoint reveals the ksqlDB cluster topology including $node_count node(s), their hostnames, ports, and liveness status." \
                "Restrict /clusterStatus endpoint access. Deploy ksqlDB behind an authenticating reverse proxy." \
                "$(echo "$ksql_cluster_status" | head -c 500)"
        fi

    else
        add_finding "KSQL-002" "ksqlDB" "curl not available - ksqlDB checks limited" "INFO" "INFO" \
            "Install curl to enable ksqlDB REST API security checks." "" ""
    fi
}

###############################################################################
# Generate HTML Report
###############################################################################
generate_html_report() {
    log_head "Generating Reports"

    # Finalize JSON
    local tmp
    tmp=$(mktemp)
    local scan_end
    scan_end="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    jq ".scan_end = \"$scan_end\"" "$RESULTS_FILE" > "$tmp" && mv "$tmp" "$RESULTS_FILE"

    # Calculate grade
    local fail_count warn_count critical_count
    fail_count=$(jq '.summary.fail' "$RESULTS_FILE")
    warn_count=$(jq '.summary.warn' "$RESULTS_FILE")
    critical_count=$(jq '.summary.critical' "$RESULTS_FILE")

    local grade="A"
    if [[ "$critical_count" -gt 0 ]]; then
        grade="F"
    elif [[ "$fail_count" -gt 3 ]]; then
        grade="F"
    elif [[ "$fail_count" -gt 1 ]]; then
        grade="D"
    elif [[ "$fail_count" -gt 0 ]]; then
        grade="C"
    elif [[ "$warn_count" -gt 5 ]]; then
        grade="C"
    elif [[ "$warn_count" -gt 2 ]]; then
        grade="B"
    elif [[ "$warn_count" -gt 0 ]]; then
        grade="B+"
    fi

    tmp=$(mktemp)
    jq ".summary.grade = \"$grade\"" "$RESULTS_FILE" > "$tmp" && mv "$tmp" "$RESULTS_FILE"

    # Build HTML report
    if [[ "$REPORT_FORMAT" == "html" ]] || [[ "$REPORT_FORMAT" == "both" ]]; then
        local html_file="${OUTPUT_DIR}/${SCAN_ID}-report.html"
        generate_html_file "$html_file"
        log_ok "HTML report: $html_file"
    fi

    if [[ "$REPORT_FORMAT" == "json" ]] || [[ "$REPORT_FORMAT" == "both" ]]; then
        log_ok "JSON report: $RESULTS_FILE"
    fi
}

generate_html_file() {
    local html_file="$1"
    local total pass fail warn info grade
    total=$(jq '.summary.total' "$RESULTS_FILE")
    pass=$(jq '.summary.pass' "$RESULTS_FILE")
    fail=$(jq '.summary.fail' "$RESULTS_FILE")
    warn=$(jq '.summary.warn' "$RESULTS_FILE")
    info=$(jq '.summary.info' "$RESULTS_FILE")
    grade=$(jq -r '.summary.grade' "$RESULTS_FILE")
    local critical high medium low
    critical=$(jq '.summary.critical' "$RESULTS_FILE")
    high=$(jq '.summary.high' "$RESULTS_FILE")
    medium=$(jq '.summary.medium' "$RESULTS_FILE")
    low=$(jq '.summary.low' "$RESULTS_FILE")

    local grade_color="#4CAF50"
    case "$grade" in
        F) grade_color="#f44336" ;;
        D) grade_color="#ff5722" ;;
        C) grade_color="#ff9800" ;;
        B|B+) grade_color="#2196F3" ;;
        A) grade_color="#4CAF50" ;;
    esac

    cat > "$html_file" <<'HTMLEOF'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Kafka VAPT Report</title>
<style>
:root {
  --bg: #0f172a; --surface: #1e293b; --surface2: #334155;
  --text: #f1f5f9; --text-muted: #94a3b8;
  --pass: #22c55e; --fail: #ef4444; --warn: #f59e0b; --info: #3b82f6;
  --critical: #dc2626; --high: #f97316; --medium: #eab308; --low: #06b6d4;
}
* { margin: 0; padding: 0; box-sizing: border-box; }
body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; background: var(--bg); color: var(--text); line-height: 1.6; padding: 20px; }
.container { max-width: 1200px; margin: 0 auto; }
.header { text-align: center; padding: 40px 20px; margin-bottom: 30px; background: linear-gradient(135deg, #1e293b 0%, #0f172a 100%); border-radius: 16px; border: 1px solid var(--surface2); }
.header h1 { font-size: 2em; margin-bottom: 10px; }
.header .subtitle { color: var(--text-muted); font-size: 1.1em; }
.grade-badge { display: inline-flex; align-items: center; justify-content: center; width: 80px; height: 80px; border-radius: 50%; font-size: 2em; font-weight: 700; margin: 20px 0; }
.meta-info { display: flex; justify-content: center; gap: 30px; margin-top: 15px; color: var(--text-muted); font-size: 0.9em; flex-wrap: wrap; }
.stats { display: grid; grid-template-columns: repeat(auto-fit, minmax(150px, 1fr)); gap: 15px; margin-bottom: 30px; }
.stat-card { background: var(--surface); border-radius: 12px; padding: 20px; text-align: center; border: 1px solid var(--surface2); }
.stat-card .number { font-size: 2em; font-weight: 700; }
.stat-card .label { color: var(--text-muted); font-size: 0.85em; text-transform: uppercase; letter-spacing: 1px; }
.category { background: var(--surface); border-radius: 12px; margin-bottom: 20px; border: 1px solid var(--surface2); overflow: hidden; }
.category-header { padding: 15px 20px; background: var(--surface2); font-size: 1.2em; font-weight: 600; cursor: pointer; display: flex; justify-content: space-between; align-items: center; }
.category-header:hover { background: #3d4f66; }
.category-body { padding: 0; }
.finding { padding: 15px 20px; border-bottom: 1px solid var(--surface2); display: grid; grid-template-columns: 90px 1fr auto; gap: 15px; align-items: start; }
.finding:last-child { border-bottom: none; }
.finding-status { display: inline-flex; align-items: center; gap: 5px; padding: 4px 10px; border-radius: 6px; font-size: 0.8em; font-weight: 600; text-transform: uppercase; }
.finding-status.pass { background: rgba(34,197,94,0.15); color: var(--pass); }
.finding-status.fail { background: rgba(239,68,68,0.15); color: var(--fail); }
.finding-status.warn { background: rgba(245,158,11,0.15); color: var(--warn); }
.finding-status.info { background: rgba(59,130,246,0.15); color: var(--info); }
.severity-badge { padding: 2px 8px; border-radius: 4px; font-size: 0.75em; font-weight: 600; }
.severity-badge.critical { background: rgba(220,38,38,0.2); color: var(--critical); }
.severity-badge.high { background: rgba(249,115,22,0.2); color: var(--high); }
.severity-badge.medium { background: rgba(234,179,8,0.2); color: var(--medium); }
.severity-badge.low { background: rgba(6,182,212,0.2); color: var(--low); }
.finding-content h4 { margin-bottom: 5px; }
.finding-content p { color: var(--text-muted); font-size: 0.9em; margin-bottom: 3px; }
.finding-content .recommendation { color: var(--info); font-size: 0.85em; margin-top: 5px; }
details.finding-details { margin-top: 8px; }
details.finding-details summary { color: var(--text-muted); font-size: 0.85em; cursor: pointer; }
details.finding-details pre { background: var(--bg); padding: 10px; border-radius: 6px; margin-top: 5px; font-size: 0.8em; overflow-x: auto; max-height: 200px; overflow-y: auto; white-space: pre-wrap; word-break: break-all; }
.footer { text-align: center; padding: 30px; color: var(--text-muted); font-size: 0.85em; }
@media print { body { background: white; color: black; } .category-header { background: #eee; } }
</style>
</head>
<body>
<div class="container">
HTMLEOF

    # Header
    cat >> "$html_file" <<EOF
<div class="header">
  <h1>Kafka Cluster VAPT Report</h1>
  <p class="subtitle">Vulnerability Assessment & Penetration Testing</p>
  <div class="grade-badge" style="background: ${grade_color}22; color: ${grade_color}; border: 3px solid ${grade_color};">
    ${grade}
  </div>
  <div class="meta-info">
    <span>Scan ID: ${SCAN_ID}</span>
    <span>Target: ${BOOTSTRAP}</span>
    <span>Date: $(date '+%Y-%m-%d %H:%M:%S')</span>
  </div>
</div>
EOF

    # Stats
    cat >> "$html_file" <<EOF
<div class="stats">
  <div class="stat-card"><div class="number" style="color: var(--text);">${total}</div><div class="label">Total Checks</div></div>
  <div class="stat-card"><div class="number" style="color: var(--pass);">${pass}</div><div class="label">Passed</div></div>
  <div class="stat-card"><div class="number" style="color: var(--fail);">${fail}</div><div class="label">Failed</div></div>
  <div class="stat-card"><div class="number" style="color: var(--warn);">${warn}</div><div class="label">Warnings</div></div>
  <div class="stat-card"><div class="number" style="color: var(--critical);">${critical}</div><div class="label">Critical</div></div>
  <div class="stat-card"><div class="number" style="color: var(--high);">${high}</div><div class="label">High</div></div>
  <div class="stat-card"><div class="number" style="color: var(--medium);">${medium}</div><div class="label">Medium</div></div>
  <div class="stat-card"><div class="number" style="color: var(--low);">${low}</div><div class="label">Low</div></div>
</div>
EOF

    # Findings by category
    local categories
    categories=$(jq -r '[.findings[].category] | unique | .[]' "$RESULTS_FILE")

    while IFS= read -r category; do
        [[ -z "$category" ]] && continue
        local cat_findings
        cat_findings=$(jq "[.findings[] | select(.category == \"$category\")]" "$RESULTS_FILE")
        local cat_count
        cat_count=$(echo "$cat_findings" | jq 'length')
        local cat_fails
        cat_fails=$(echo "$cat_findings" | jq '[.[] | select(.status == "FAIL")] | length')
        local cat_warns
        cat_warns=$(echo "$cat_findings" | jq '[.[] | select(.status == "WARN")] | length')

        local cat_badge=""
        if [[ "$cat_fails" -gt 0 ]]; then
            cat_badge="<span style='color: var(--fail); font-size: 0.8em;'>${cat_fails} FAIL</span>"
        fi
        if [[ "$cat_warns" -gt 0 ]]; then
            cat_badge="${cat_badge} <span style='color: var(--warn); font-size: 0.8em;'>${cat_warns} WARN</span>"
        fi

        cat >> "$html_file" <<EOF
<div class="category">
  <div class="category-header">
    <span>${category} (${cat_count} checks)</span>
    <span>${cat_badge}</span>
  </div>
  <div class="category-body">
EOF

        # Each finding
        echo "$cat_findings" | jq -c '.[]' | while IFS= read -r finding; do
            local f_id f_title f_severity f_status f_desc f_rec f_details
            f_id=$(echo "$finding" | jq -r '.id')
            f_title=$(echo "$finding" | jq -r '.title')
            f_severity=$(echo "$finding" | jq -r '.severity')
            f_status=$(echo "$finding" | jq -r '.status')
            f_desc=$(echo "$finding" | jq -r '.description')
            f_rec=$(echo "$finding" | jq -r '.recommendation')
            f_details=$(echo "$finding" | jq -r '.details')

            local status_lower
            status_lower=$(echo "$f_status" | tr '[:upper:]' '[:lower:]')
            local severity_lower
            severity_lower=$(echo "$f_severity" | tr '[:upper:]' '[:lower:]')

            cat >> "$html_file" <<EOF
    <div class="finding">
      <div><span class="finding-status ${status_lower}">${f_status}</span></div>
      <div class="finding-content">
        <h4>[${f_id}] ${f_title} <span class="severity-badge ${severity_lower}">${f_severity}</span></h4>
        <p>${f_desc}</p>
EOF
            if [[ -n "$f_rec" ]] && [[ "$f_rec" != "null" ]] && [[ "$f_rec" != "" ]]; then
                echo "        <p class=\"recommendation\">Recommendation: ${f_rec}</p>" >> "$html_file"
            fi
            if [[ -n "$f_details" ]] && [[ "$f_details" != "null" ]] && [[ "$f_details" != "" ]] && [[ ${#f_details} -gt 2 ]]; then
                cat >> "$html_file" <<EOF
        <details class="finding-details">
          <summary>Show details</summary>
          <pre>${f_details}</pre>
        </details>
EOF
            fi
            cat >> "$html_file" <<EOF
      </div>
    </div>
EOF
        done

        echo "  </div></div>" >> "$html_file"
    done <<< "$categories"

    # Footer
    cat >> "$html_file" <<EOF
<div class="footer">
  <p>Generated by Kafka VAPT Scanner | Open Source Security Toolkit</p>
  <p>Tools: nmap, openssl, kcat, kafka CLI, curl, jq</p>
  <p>Scan completed: $(date '+%Y-%m-%d %H:%M:%S %Z')</p>
</div>
</div>
<script>
document.querySelectorAll('.category-header').forEach(h => {
  h.addEventListener('click', () => {
    const body = h.nextElementSibling;
    body.style.display = body.style.display === 'none' ? '' : 'none';
  });
});
</script>
</body>
</html>
EOF
}

###############################################################################
# Print Summary
###############################################################################
print_summary() {
    local total pass fail warn grade
    total=$(jq '.summary.total' "$RESULTS_FILE")
    pass=$(jq '.summary.pass' "$RESULTS_FILE")
    fail=$(jq '.summary.fail' "$RESULTS_FILE")
    warn=$(jq '.summary.warn' "$RESULTS_FILE")
    grade=$(jq -r '.summary.grade' "$RESULTS_FILE")

    log_head "VAPT Scan Summary"
    echo ""
    echo -e "  Grade:    ${CYAN}${grade}${NC}"
    echo -e "  Total:    $total checks"
    echo -e "  ${GREEN}Passed:   $pass${NC}"
    echo -e "  ${RED}Failed:   $fail${NC}"
    echo -e "  ${YELLOW}Warnings: $warn${NC}"
    echo ""
    echo -e "  Reports saved to: ${BLUE}${OUTPUT_DIR}/${NC}"
    echo ""
}

###############################################################################
# Docker execution mode
###############################################################################
run_in_docker() {
    log_info "Running scans inside Docker container..."

    local docker_image="kafka-vapt-scanner"
    local dockerfile="${SCRIPT_DIR}/Dockerfile"

    if ! docker image inspect "$docker_image" &>/dev/null; then
        log_info "Building Docker image..."
        docker build -t "$docker_image" -f "$dockerfile" "$SCRIPT_DIR"
    fi

    # Re-run this script inside Docker, without --docker flag
    local args=()
    args+=("--bootstrap" "$BOOTSTRAP")
    [[ -n "$BROKERS" ]]         && args+=("--brokers" "$BROKERS")
    [[ -n "$ZOOKEEPER" ]]       && args+=("--zookeeper" "$ZOOKEEPER")
    [[ "$SSL_ENABLED" == true ]] && args+=("--ssl")
    [[ -n "$SASL_MECHANISM" ]]  && args+=("--sasl-mechanism" "$SASL_MECHANISM")
    [[ -n "$SASL_USERNAME" ]]   && args+=("--sasl-username" "$SASL_USERNAME")
    [[ -n "$SASL_PASSWORD" ]]   && args+=("--sasl-password" "$SASL_PASSWORD")
    [[ -n "$KSQLDB_URL" ]]     && args+=("--ksqldb" "$KSQLDB_URL")
    args+=("--output" "/reports")
    args+=("--format" "$REPORT_FORMAT")

    # Map localhost to host.docker.internal
    local docker_bootstrap
    docker_bootstrap=$(echo "$BOOTSTRAP" | sed 's/localhost/host.docker.internal/g' | sed 's/127\.0\.0\.1/host.docker.internal/g')
    args[1]="$docker_bootstrap"

    docker run --rm \
        --add-host=host.docker.internal:host-gateway \
        -v "$OUTPUT_DIR:/reports" \
        "$docker_image" \
        /app/run-kafka-vapt.sh "${args[@]}"

    exit $?
}

###############################################################################
# Main
###############################################################################
main() {
    echo -e "${CYAN}"
    echo "  ╔═══════════════════════════════════════════════════╗"
    echo "  ║     Kafka Cluster VAPT Scanner                   ║"
    echo "  ║     Vulnerability Assessment & Penetration Test   ║"
    echo "  ╚═══════════════════════════════════════════════════╝"
    echo -e "${NC}"

    parse_args "$@"

    if [[ "$USE_DOCKER" == true ]]; then
        run_in_docker
    fi

    check_prerequisites
    init_results

    # Run all check categories
    run_network_checks  || true
    run_tls_checks      || true
    run_auth_checks     || true
    run_config_checks   || true
    run_data_checks     || true
    run_ops_checks      || true
    run_ksqldb_checks   || true

    # Generate reports
    generate_html_report
    print_summary
}

main "$@"

#!/usr/bin/env bash
###############################################################################
#
#  Tantor E2E — Deploy Kafka Cluster via Tantor API
#
#  Reads Terraform outputs and drives Tantor's API to:
#    1. Register Kafka nodes as hosts
#    2. Create a 3-node KRaft cluster
#    3. Deploy the cluster
#    4. Verify everything is running
#
#  Usage:
#    cd terraform/ && ./scripts/deploy-kafka.sh
#
###############################################################################

set -euo pipefail

# ─── Colors ───
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TF_DIR="$(dirname "$SCRIPT_DIR")"

log_step()  { echo -e "\n${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; echo -e "${BLUE}▶ $1${NC}"; echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }
log_ok()    { echo -e "  ${GREEN}✓${NC} $1"; }
log_warn()  { echo -e "  ${YELLOW}⚠${NC} $1"; }
log_fail()  { echo -e "  ${RED}✗${NC} $1"; }

START_TIME=$(date +%s)

# ═══════════════════════════════════════════════════════
# Step 1: Extract Terraform Outputs
# ═══════════════════════════════════════════════════════

log_step "Step 1/10: Reading Terraform Outputs"

cd "$TF_DIR"

TANTOR_URL=$(terraform output -raw tantor_url)
SSH_USER=$(terraform output -raw ssh_user)
OS_VARIANT=$(terraform output -raw os_variant)
PRIVATE_KEY_PEM=$(terraform output -raw private_key_pem)

# Parse Kafka private IPs as array
KAFKA_IPS_JSON=$(terraform output -json kafka_private_ips)
KAFKA_COUNT=$(echo "$KAFKA_IPS_JSON" | jq 'length')
KAFKA_IPS=()
for i in $(seq 0 $((KAFKA_COUNT - 1))); do
  KAFKA_IPS+=("$(echo "$KAFKA_IPS_JSON" | jq -r ".[$i]")")
done

log_ok "Tantor URL:   $TANTOR_URL"
log_ok "OS Variant:   $OS_VARIANT"
log_ok "SSH User:     $SSH_USER"
log_ok "Kafka Nodes:  ${KAFKA_IPS[*]}"

# ═══════════════════════════════════════════════════════
# Step 2: Wait for Tantor API Health
# ═══════════════════════════════════════════════════════

log_step "Step 2/10: Waiting for Tantor API"

MAX_WAIT=900  # 15 minutes (native install takes time)
ELAPSED=0
INTERVAL=15

while [ $ELAPSED -lt $MAX_WAIT ]; do
  HEALTH=$(curl -sf "${TANTOR_URL}/api/health" 2>/dev/null || echo "")
  if echo "$HEALTH" | jq -e '.status == "ok"' >/dev/null 2>&1; then
    log_ok "Tantor API is healthy: $HEALTH"
    break
  fi
  echo -e "  Waiting... (${ELAPSED}s / ${MAX_WAIT}s)"
  sleep $INTERVAL
  ELAPSED=$((ELAPSED + INTERVAL))
done

if [ $ELAPSED -ge $MAX_WAIT ]; then
  log_fail "Tantor API did not become healthy within ${MAX_WAIT}s"
  echo "  Check cloud-init logs: ssh -i tantor-key.pem ${SSH_USER}@<ip> 'cat /var/log/tantor-cloud-init.log'"
  exit 1
fi

# ═══════════════════════════════════════════════════════
# Step 3: Login
# ═══════════════════════════════════════════════════════

log_step "Step 3/10: Authenticating"

LOGIN_RESPONSE=$(curl -sf -X POST "${TANTOR_URL}/api/auth/login" \
  -H "Content-Type: application/json" \
  -d '{"username":"admin","password":"admin"}')

TOKEN=$(echo "$LOGIN_RESPONSE" | jq -r '.access_token')

if [ -z "$TOKEN" ] || [ "$TOKEN" = "null" ]; then
  log_fail "Login failed: $LOGIN_RESPONSE"
  exit 1
fi

log_ok "Authenticated as admin"
AUTH="Authorization: Bearer ${TOKEN}"

# ═══════════════════════════════════════════════════════
# Step 4: Register Kafka Hosts
# ═══════════════════════════════════════════════════════

log_step "Step 4/10: Registering Kafka Hosts"

HOST_IDS=()
for i in "${!KAFKA_IPS[@]}"; do
  IP="${KAFKA_IPS[$i]}"
  NODE_NUM=$((i + 1))

  PAYLOAD=$(jq -n \
    --arg hostname "kafka-${NODE_NUM}" \
    --arg ip "$IP" \
    --arg username "$SSH_USER" \
    --arg credential "$PRIVATE_KEY_PEM" \
    '{
      hostname: $hostname,
      ip_address: $ip,
      ssh_port: 22,
      username: $username,
      auth_type: "key",
      credential: $credential
    }')

  RESPONSE=$(curl -sf -X POST "${TANTOR_URL}/api/hosts" \
    -H "Content-Type: application/json" \
    -H "$AUTH" \
    -d "$PAYLOAD")

  HOST_ID=$(echo "$RESPONSE" | jq -r '.id')

  if [ -z "$HOST_ID" ] || [ "$HOST_ID" = "null" ]; then
    log_fail "Failed to register kafka-${NODE_NUM} ($IP): $RESPONSE"
    exit 1
  fi

  HOST_IDS+=("$HOST_ID")
  log_ok "Registered kafka-${NODE_NUM} ($IP) → host_id: ${HOST_ID:0:8}..."
done

# ═══════════════════════════════════════════════════════
# Step 5: Test SSH Connectivity
# ═══════════════════════════════════════════════════════

log_step "Step 5/10: Testing SSH Connectivity"

for i in "${!HOST_IDS[@]}"; do
  HOST_ID="${HOST_IDS[$i]}"
  NODE_NUM=$((i + 1))
  SUCCESS=false

  for attempt in $(seq 1 5); do
    RESULT=$(curl -sf -X POST "${TANTOR_URL}/api/hosts/${HOST_ID}/test" \
      -H "$AUTH" 2>/dev/null || echo '{"success":false}')

    if echo "$RESULT" | jq -e '.success == true' >/dev/null 2>&1; then
      OS_INFO=$(echo "$RESULT" | jq -r '.os_info // "unknown"')
      log_ok "kafka-${NODE_NUM}: SSH OK — $OS_INFO"
      SUCCESS=true
      break
    fi

    echo -e "  kafka-${NODE_NUM}: attempt $attempt/5 failed, retrying in 20s..."
    sleep 20
  done

  if [ "$SUCCESS" != "true" ]; then
    log_fail "kafka-${NODE_NUM}: SSH test failed after 5 attempts"
    echo "  Last response: $RESULT"
    exit 1
  fi
done

# ═══════════════════════════════════════════════════════
# Step 6: Create KRaft Cluster
# ═══════════════════════════════════════════════════════

log_step "Step 6/10: Creating KRaft Cluster"

# Build services array
SERVICES="[]"
for i in "${!HOST_IDS[@]}"; do
  SERVICES=$(echo "$SERVICES" | jq \
    --arg host_id "${HOST_IDS[$i]}" \
    --argjson node_id "$((i + 1))" \
    '. + [{host_id: $host_id, role: "broker_controller", node_id: $node_id}]')
done

CLUSTER_PAYLOAD=$(jq -n \
  --argjson services "$SERVICES" \
  '{
    name: "e2e-test-cluster",
    kafka_version: "3.7.0",
    mode: "kraft",
    services: $services,
    config: {
      replication_factor: 3,
      num_partitions: 3,
      log_dirs: "/var/lib/kafka/data",
      listener_port: 9092,
      controller_port: 9093,
      heap_size: "1G"
    }
  }')

CLUSTER_RESPONSE=$(curl -sf -X POST "${TANTOR_URL}/api/clusters" \
  -H "Content-Type: application/json" \
  -H "$AUTH" \
  -d "$CLUSTER_PAYLOAD")

CLUSTER_ID=$(echo "$CLUSTER_RESPONSE" | jq -r '.id')

if [ -z "$CLUSTER_ID" ] || [ "$CLUSTER_ID" = "null" ]; then
  log_fail "Failed to create cluster: $CLUSTER_RESPONSE"
  exit 1
fi

log_ok "Cluster created: $CLUSTER_ID"
log_ok "Name: e2e-test-cluster | Mode: KRaft | Nodes: ${#HOST_IDS[@]}"

# ═══════════════════════════════════════════════════════
# Step 7: Deploy Cluster
# ═══════════════════════════════════════════════════════

log_step "Step 7/10: Deploying Cluster"

DEPLOY_RESPONSE=$(curl -sf -X POST "${TANTOR_URL}/api/clusters/${CLUSTER_ID}/deploy" \
  -H "$AUTH")

TASK_ID=$(echo "$DEPLOY_RESPONSE" | jq -r '.task_id')

if [ -z "$TASK_ID" ] || [ "$TASK_ID" = "null" ]; then
  log_fail "Failed to start deployment: $DEPLOY_RESPONSE"
  exit 1
fi

log_ok "Deployment started: task_id=${TASK_ID:0:8}..."

# ═══════════════════════════════════════════════════════
# Step 8: Poll Deployment Status
# ═══════════════════════════════════════════════════════

log_step "Step 8/10: Monitoring Deployment"

DEPLOY_MAX_WAIT=1200  # 20 minutes
DEPLOY_ELAPSED=0
DEPLOY_INTERVAL=15

while [ $DEPLOY_ELAPSED -lt $DEPLOY_MAX_WAIT ]; do
  STATUS_RESPONSE=$(curl -sf "${TANTOR_URL}/api/clusters/${CLUSTER_ID}/deploy/${TASK_ID}" \
    -H "$AUTH" 2>/dev/null || echo '{"status":"unknown"}')

  STATUS=$(echo "$STATUS_RESPONSE" | jq -r '.status')

  case "$STATUS" in
    completed)
      log_ok "Deployment completed successfully!"
      break
      ;;
    running)
      echo -e "  Deploying... (${DEPLOY_ELAPSED}s / ${DEPLOY_MAX_WAIT}s)"
      ;;
    error|completed_with_errors)
      log_fail "Deployment failed with status: $STATUS"
      echo "$STATUS_RESPONSE" | jq '.logs[-5:]' 2>/dev/null || echo "$STATUS_RESPONSE"
      exit 1
      ;;
    *)
      echo -e "  Status: $STATUS (${DEPLOY_ELAPSED}s)"
      ;;
  esac

  sleep $DEPLOY_INTERVAL
  DEPLOY_ELAPSED=$((DEPLOY_ELAPSED + DEPLOY_INTERVAL))
done

if [ $DEPLOY_ELAPSED -ge $DEPLOY_MAX_WAIT ]; then
  log_fail "Deployment timed out after ${DEPLOY_MAX_WAIT}s"
  exit 1
fi

# ═══════════════════════════════════════════════════════
# Step 9: Verify Cluster Status
# ═══════════════════════════════════════════════════════

log_step "Step 9/10: Verifying Cluster Status"

sleep 10  # Let services stabilize

CLUSTER_STATUS=$(curl -sf "${TANTOR_URL}/api/clusters/${CLUSTER_ID}/status" \
  -H "$AUTH" 2>/dev/null || echo '{}')

echo "$CLUSTER_STATUS" | jq '.' 2>/dev/null || echo "$CLUSTER_STATUS"

# Check if cluster state is healthy
CLUSTER_STATE=$(curl -sf "${TANTOR_URL}/api/clusters/${CLUSTER_ID}" \
  -H "$AUTH" 2>/dev/null | jq -r '.cluster.state // .state // "unknown"')

log_ok "Cluster state: $CLUSTER_STATE"

# ═══════════════════════════════════════════════════════
# Step 10: Print Results
# ═══════════════════════════════════════════════════════

END_TIME=$(date +%s)
DURATION=$(( END_TIME - START_TIME ))

log_step "Step 10/10: E2E Test Results"

echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║            TANTOR E2E TEST — ${OS_VARIANT^^}               ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${BLUE}OS Variant:${NC}     $OS_VARIANT"
echo -e "  ${BLUE}Tantor URL:${NC}     $TANTOR_URL"
echo -e "  ${BLUE}Cluster ID:${NC}     $CLUSTER_ID"
echo -e "  ${BLUE}Cluster State:${NC}  $CLUSTER_STATE"
echo -e "  ${BLUE}Kafka Nodes:${NC}    ${KAFKA_IPS[*]}"
echo -e "  ${BLUE}Duration:${NC}       ${DURATION}s"
echo ""

if [ "$CLUSTER_STATE" = "running" ] || [ "$CLUSTER_STATE" = "deployed" ]; then
  echo -e "  ${GREEN}╔══════════════╗${NC}"
  echo -e "  ${GREEN}║    PASS      ║${NC}"
  echo -e "  ${GREEN}╚══════════════╝${NC}"
  echo ""
  echo -e "  ${GREEN}✓ Tantor deployed a 3-node Kafka KRaft cluster on ${OS_VARIANT^^} successfully${NC}"
  echo ""
  echo -e "  ${BLUE}Login:${NC}  Open ${TANTOR_URL} → admin / admin"
  echo ""
  exit 0
else
  echo -e "  ${RED}╔══════════════╗${NC}"
  echo -e "  ${RED}║    FAIL      ║${NC}"
  echo -e "  ${RED}╚══════════════╝${NC}"
  echo ""
  echo -e "  ${RED}✗ Cluster state is '$CLUSTER_STATE' — expected 'running' or 'deployed'${NC}"
  echo ""
  exit 1
fi

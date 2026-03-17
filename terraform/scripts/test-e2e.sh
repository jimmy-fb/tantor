#!/usr/bin/env bash
###############################################################################
#
#  Tantor E2E — Master Test Runner
#
#  Runs the full end-to-end test for both Ubuntu and RHEL:
#    1. Provisions AWS infrastructure via Terraform
#    2. Installs Tantor natively on the EC2 instance
#    3. Uses Tantor API to deploy a 3-node Kafka KRaft cluster
#    4. Verifies everything is running
#    5. Tears down infrastructure
#
#  Usage:
#    cd terraform/ && ./scripts/test-e2e.sh              # Run both
#    cd terraform/ && ./scripts/test-e2e.sh ubuntu       # Run Ubuntu only
#    cd terraform/ && ./scripts/test-e2e.sh rhel         # Run RHEL only
#    cd terraform/ && ./scripts/test-e2e.sh --no-destroy # Keep infra running
#
###############################################################################

set -euo pipefail

# ─── Colors ───
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TF_DIR="$(dirname "$SCRIPT_DIR")"

# ─── Parse arguments ───
RUN_UBUNTU=true
RUN_RHEL=true
DESTROY=true

for arg in "$@"; do
  case $arg in
    ubuntu)     RUN_RHEL=false ;;
    rhel)       RUN_UBUNTU=false ;;
    --no-destroy) DESTROY=false ;;
    --help|-h)
      echo "Usage: $0 [ubuntu|rhel] [--no-destroy]"
      echo ""
      echo "  ubuntu         Run Ubuntu test only"
      echo "  rhel           Run RHEL test only"
      echo "  --no-destroy   Keep infrastructure after test (for debugging)"
      echo ""
      exit 0
      ;;
  esac
done

# ─── Banner ───
echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║        TANTOR — AWS E2E Test Suite                  ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${BLUE}Tests:${NC}    $([ "$RUN_UBUNTU" = true ] && echo 'Ubuntu')$([ "$RUN_UBUNTU" = true ] && [ "$RUN_RHEL" = true ] && echo ', ')$([ "$RUN_RHEL" = true ] && echo 'RHEL')"
echo -e "  ${BLUE}Teardown:${NC} $([ "$DESTROY" = true ] && echo 'Yes (auto-destroy after test)' || echo 'No (infra kept alive)')"
echo ""

# ─── Preflight checks ───
echo -e "${BLUE}▶ Preflight Checks${NC}"

if ! command -v terraform &>/dev/null; then
  echo -e "  ${RED}✗ Terraform not found. Install: https://developer.hashicorp.com/terraform/install${NC}"
  exit 1
fi
echo -e "  ${GREEN}✓${NC} Terraform $(terraform version -json 2>/dev/null | jq -r '.terraform_version' 2>/dev/null || terraform version | head -1)"

if ! command -v aws &>/dev/null; then
  echo -e "  ${RED}✗ AWS CLI not found. Install: https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html${NC}"
  exit 1
fi
echo -e "  ${GREEN}✓${NC} AWS CLI configured"

if ! aws sts get-caller-identity &>/dev/null; then
  echo -e "  ${RED}✗ AWS credentials not configured. Run: aws configure${NC}"
  exit 1
fi
AWS_ACCOUNT=$(aws sts get-caller-identity --query Account --output text 2>/dev/null)
echo -e "  ${GREEN}✓${NC} AWS Account: $AWS_ACCOUNT"

if ! command -v jq &>/dev/null; then
  echo -e "  ${RED}✗ jq not found. Install: brew install jq (macOS) or apt install jq${NC}"
  exit 1
fi
echo -e "  ${GREEN}✓${NC} jq available"

# ─── Initialize Terraform ───
cd "$TF_DIR"
echo -e "\n${BLUE}▶ Initializing Terraform${NC}"
terraform init -input=false -no-color 2>&1 | tail -3

# ─── Results tracking ───
UBUNTU_RESULT="SKIP"
RHEL_RESULT="SKIP"
UBUNTU_DURATION=0
RHEL_DURATION=0

# ─── Run variant function ───
run_variant() {
  local os_variant=$1
  local variant_start=$(date +%s)

  echo ""
  echo -e "${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}║  E2E Test: ${os_variant^^}                                    ║${NC}"
  echo -e "${CYAN}╚══════════════════════════════════════════════════════╝${NC}"

  # Create/select workspace
  terraform workspace new "$os_variant" 2>/dev/null || terraform workspace select "$os_variant"
  echo -e "  ${GREEN}✓${NC} Workspace: $os_variant"

  # Apply infrastructure
  echo -e "\n${BLUE}▶ Provisioning AWS Infrastructure ($os_variant)${NC}"
  echo "  This creates: 1 Tantor server + 3 Kafka nodes (4 EC2 instances)"
  echo ""

  if ! terraform apply -auto-approve -input=false -var="os_variant=${os_variant}" 2>&1 | \
    grep -E "^(aws_|Apply|Plan|Outputs|  tantor_|  kafka_|  ssh_|  os_)" | head -30; then
    echo -e "  ${RED}✗ Terraform apply failed${NC}"
    if [ "$DESTROY" = true ]; then
      echo -e "  ${YELLOW}Cleaning up...${NC}"
      terraform destroy -auto-approve -input=false -var="os_variant=${os_variant}" 2>/dev/null || true
    fi
    return 1
  fi

  echo ""
  echo -e "  ${GREEN}✓${NC} Infrastructure provisioned"
  echo -e "  ${BLUE}Tantor URL:${NC} $(terraform output -raw tantor_url 2>/dev/null)"
  echo ""

  # Save SSH key for debugging
  terraform output -raw private_key_pem > "${TF_DIR}/tantor-key.pem" 2>/dev/null
  chmod 600 "${TF_DIR}/tantor-key.pem"

  # Run deployment script
  echo -e "${BLUE}▶ Running Kafka Deployment via Tantor API${NC}"
  echo ""

  local deploy_result=0
  "${SCRIPT_DIR}/deploy-kafka.sh" || deploy_result=$?

  local variant_end=$(date +%s)
  local variant_duration=$(( variant_end - variant_start ))

  # Store results
  if [ "$os_variant" = "ubuntu" ]; then
    UBUNTU_DURATION=$variant_duration
    if [ $deploy_result -eq 0 ]; then UBUNTU_RESULT="PASS"; else UBUNTU_RESULT="FAIL"; fi
  else
    RHEL_DURATION=$variant_duration
    if [ $deploy_result -eq 0 ]; then RHEL_RESULT="PASS"; else RHEL_RESULT="FAIL"; fi
  fi

  # Teardown
  if [ "$DESTROY" = true ]; then
    echo -e "\n${BLUE}▶ Destroying Infrastructure ($os_variant)${NC}"
    terraform destroy -auto-approve -input=false -var="os_variant=${os_variant}" 2>&1 | \
      grep -E "^(Destroy|aws_)" | head -10
    echo -e "  ${GREEN}✓${NC} Infrastructure destroyed"

    terraform workspace select default 2>/dev/null
    terraform workspace delete "$os_variant" 2>/dev/null || true
  else
    echo -e "\n${YELLOW}⚠ Infrastructure kept alive (--no-destroy)${NC}"
    echo -e "  Tantor: $(terraform output -raw tantor_url 2>/dev/null)"
    echo -e "  SSH:    $(terraform output -raw ssh_tantor 2>/dev/null)"
    echo -e "  Destroy later: terraform workspace select $os_variant && terraform destroy"
  fi

  return $deploy_result
}

# ─── Run tests ───
OVERALL_START=$(date +%s)

if [ "$RUN_UBUNTU" = true ]; then
  run_variant "ubuntu" || true
fi

if [ "$RUN_RHEL" = true ]; then
  run_variant "rhel" || true
fi

OVERALL_END=$(date +%s)
OVERALL_DURATION=$(( OVERALL_END - OVERALL_START ))

# ─── Clean up key file ───
rm -f "${TF_DIR}/tantor-key.pem"

# ─── Final Summary ───
echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║            E2E TEST RESULTS                         ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════╝${NC}"
echo ""

print_result() {
  local os=$1 result=$2 duration=$3
  local color="$NC"
  case "$result" in
    PASS) color="$GREEN" ;;
    FAIL) color="$RED" ;;
    SKIP) color="$YELLOW" ;;
  esac

  local duration_str="—"
  if [ "$duration" -gt 0 ]; then
    local mins=$((duration / 60))
    local secs=$((duration % 60))
    duration_str="${mins}m ${secs}s"
  fi

  printf "  %-10s ${color}%-6s${NC}  %s\n" "$os" "$result" "$duration_str"
}

echo -e "  ${BOLD}OS          Result  Duration${NC}"
echo -e "  ─────────────────────────────"
[ "$RUN_UBUNTU" = true ] && print_result "Ubuntu" "$UBUNTU_RESULT" "$UBUNTU_DURATION"
[ "$RUN_RHEL" = true ]   && print_result "RHEL" "$RHEL_RESULT" "$RHEL_DURATION"
echo -e "  ─────────────────────────────"
printf "  %-10s         %dm %ds\n" "Total" "$((OVERALL_DURATION / 60))" "$((OVERALL_DURATION % 60))"
echo ""

# ─── Exit code ───
FAILURES=0
[ "$UBUNTU_RESULT" = "FAIL" ] && FAILURES=$((FAILURES + 1))
[ "$RHEL_RESULT" = "FAIL" ] && FAILURES=$((FAILURES + 1))

if [ $FAILURES -eq 0 ]; then
  echo -e "  ${GREEN}All tests passed!${NC}"
else
  echo -e "  ${RED}${FAILURES} test(s) failed${NC}"
fi
echo ""

exit $FAILURES

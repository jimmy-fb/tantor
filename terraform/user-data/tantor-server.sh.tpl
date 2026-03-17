#!/bin/bash
set -euxo pipefail
exec > /var/log/tantor-cloud-init.log 2>&1

echo "=== Tantor Server Cloud-Init: ${os_variant} ==="
echo "Started at: $(date -u)"

# ─── Install base packages ───
%{ if os_variant == "ubuntu" ~}
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y git curl jq
%{ else ~}
dnf install -y git curl jq
%{ endif ~}

# ─── Clone Tantor repository ───
echo "=== Cloning Tantor repository ==="
%{ if github_token != "" ~}
git clone https://${github_token}@${replace(github_repo, "https://", "")} /tmp/tantor
%{ else ~}
git clone ${github_repo} /tmp/tantor
%{ endif ~}

# ─── Run native installer ───
echo "=== Running Tantor native installer ==="
cd /tmp/tantor
chmod +x installer/install.sh
./installer/install.sh --force

# ─── Download Kafka binary to the repo directory ───
echo "=== Downloading Apache Kafka ${kafka_version} ==="
KAFKA_TARBALL="kafka_2.13-${kafka_version}.tgz"
KAFKA_REPO_DIR="/var/lib/tantor/repo/kafka"
mkdir -p "$KAFKA_REPO_DIR"

# Try primary Apache mirror, fallback to archive
curl -fSL --retry 3 --retry-delay 5 \
  "https://downloads.apache.org/kafka/${kafka_version}/$KAFKA_TARBALL" \
  -o "$KAFKA_REPO_DIR/$KAFKA_TARBALL" 2>/dev/null || \
curl -fSL --retry 3 --retry-delay 5 \
  "https://archive.apache.org/dist/kafka/${kafka_version}/$KAFKA_TARBALL" \
  -o "$KAFKA_REPO_DIR/$KAFKA_TARBALL"

chown -R tantor:tantor /var/lib/tantor/repo
echo "=== Kafka binary downloaded: $(ls -lh $KAFKA_REPO_DIR/$KAFKA_TARBALL) ==="

# ─── Verify services are running ───
echo "=== Verifying Tantor services ==="
systemctl status tantor-backend --no-pager || true
systemctl status nginx --no-pager || true

# Wait for API to become healthy
for i in $(seq 1 30); do
  if curl -sf http://localhost/api/health >/dev/null 2>&1; then
    echo "=== Tantor API is healthy ==="
    break
  fi
  echo "Waiting for API... ($i/30)"
  sleep 2
done

curl -sf http://localhost/api/health || echo "WARNING: API not yet responding"

# ─── Signal completion ───
touch /tmp/cloud-init-done
echo "=== Tantor Server Cloud-Init COMPLETE at $(date -u) ==="

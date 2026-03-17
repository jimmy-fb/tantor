#!/bin/bash
set -euxo pipefail
exec > /var/log/kafka-node-cloud-init.log 2>&1

echo "=== Kafka Node Cloud-Init: ${os_variant} ==="
echo "Started at: $(date -u)"

# ─── Install Java 17 and prerequisites ───
%{ if os_variant == "ubuntu" ~}
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y \
  openjdk-17-jre-headless \
  tar \
  wget \
  curl \
  net-tools \
  iproute2 \
  sudo
%{ else ~}
dnf install -y \
  java-17-openjdk-headless \
  tar \
  wget \
  curl \
  net-tools \
  iproute \
  sudo
%{ endif ~}

# Verify Java
java -version 2>&1 || echo "WARNING: Java not found"

# ─── Create directories for Kafka ───
mkdir -p /opt/kafka
mkdir -p /var/lib/kafka/data
mkdir -p /var/log/kafka

# ─── Ensure SSH user has passwordless sudo ───
# Tantor's Ansible playbook needs sudo for systemd operations
echo "${ssh_user} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/90-tantor
chmod 440 /etc/sudoers.d/90-tantor

# ─── Signal completion ───
touch /tmp/cloud-init-done
echo "=== Kafka Node Cloud-Init COMPLETE at $(date -u) ==="

#!/bin/bash
# install-docker-debian.sh
# Installs Docker CE on Debian using the official Docker apt repository

set -e

echo "==> Removing old Docker versions..."
apt remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true

echo "==> Installing dependencies..."
apt update
apt install -y ca-certificates curl gnupg

echo "==> Adding Docker GPG key..."
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
  gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

echo "==> Adding Docker apt repository..."
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  tee /etc/apt/sources.list.d/docker.list > /dev/null

echo "==> Installing Docker CE..."
apt update
apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

echo "==> Enabling Docker service..."
systemctl enable --now docker

echo "==> Adding current user to docker group (run 'newgrp docker' after)..."
usermod -aG docker "${SUDO_USER:-$USER}"

echo ""
echo "Done. Verify with: docker run hello-world"

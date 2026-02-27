#!/bin/bash
# =============================================================
# Run this on ALL 3 nodes (cp, w1, w2)
# Usage: ssh ubuntu@<IP> 'bash -s' < kube-install-all-nodes.sh
# =============================================================
set -euo pipefail

echo "=== [1/6] Disable swap ==="
sudo swapoff -a
sudo sed -i '/swap/d' /etc/fstab

echo "=== [2/6] Load kernel modules ==="
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
sudo modprobe overlay
sudo modprobe br_netfilter

echo "=== [3/6] Set sysctl params ==="
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sudo sysctl --system

echo "=== [4/6] Install containerd ==="
sudo apt-get update -qq
sudo apt-get install -y -qq containerd apt-transport-https ca-certificates curl gpg

sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml > /dev/null
# Enable systemd cgroup driver (required for kubeadm)
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
sudo systemctl restart containerd
sudo systemctl enable containerd

echo "=== [5/6] Add Kubernetes repo ==="
KUBE_VERSION="1.31"
sudo mkdir -p /etc/apt/keyrings
curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${KUBE_VERSION}/deb/Release.key" \
  | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
https://pkgs.k8s.io/core:/stable:/v${KUBE_VERSION}/deb/ /" \
  | sudo tee /etc/apt/sources.list.d/kubernetes.list

echo "=== [6/6] Install kubeadm, kubelet, kubectl ==="
sudo apt-get update -qq
sudo apt-get install -y -qq kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl

echo ""
echo "=== DONE — prerequisites installed ==="
echo "Versions:"
kubeadm version -o short
kubelet --version
kubectl version --client --short 2>/dev/null || kubectl version --client

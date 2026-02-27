#!/bin/bash
# =============================================================
# Run this ONLY on the control plane (192.168.11.170)
# Usage: ssh ubuntu@192.168.11.170 'bash -s' < kube-init-cp.sh
# =============================================================
set -euo pipefail

CP_IP="192.168.11.170"
POD_CIDR="10.244.0.0/16"    # flannel default

echo "=== [1/3] Init cluster ==="
sudo kubeadm init \
  --apiserver-advertise-address="$CP_IP" \
  --pod-network-cidr="$POD_CIDR" \
  --node-name="k8s-cp"

echo "=== [2/3] Setup kubeconfig ==="
mkdir -p "$HOME/.kube"
sudo cp /etc/kubernetes/admin.conf "$HOME/.kube/config"
sudo chown "$(id -u):$(id -g)" "$HOME/.kube/config"

# Also setup for root
sudo mkdir -p /root/.kube
sudo cp /etc/kubernetes/admin.conf /root/.kube/config

echo "=== [3/3] Install Flannel CNI ==="
kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml

echo ""
echo "=== DONE — control plane ready ==="
echo ""
echo "Save the join command below. Run it on each worker node:"
echo "-----"
kubeadm token create --print-join-command
echo "-----"

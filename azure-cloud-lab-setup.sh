#!/usr/bin/env bash
# ============================================================================
# Azure Cloud Security Lab — Infrastructure Provisioning
# ============================================================================
# Creates: VNet, 2 subnets, 2 NSGs (subnet + NIC level), 1 VM with nginx
#
# Architecture:
#
#   Your PC (internet)
#       │
#       ▼
#   ┌──────────────────────────────────────────────────────────┐
#   │  VNet: cloud-sec-vnet  (10.0.0.0/16)                    │
#   │                                                          │
#   │  ┌─── public-subnet (10.0.1.0/24) ───────────────────┐  │
#   │  │  NSG-subnet (subnet-level = "NACL" equivalent)     │  │
#   │  │                                                     │  │
#   │  │  ┌──────────────────────────────────────────────┐  │  │
#   │  │  │  web-vm  (10.0.1.4)                          │  │  │
#   │  │  │  NSG-nic (NIC-level = "Security Group")      │  │  │
#   │  │  │  ┌─────────────────────────────────────────┐ │  │  │
#   │  │  │  │  Ubuntu 22.04 + nginx + iptables        │ │  │  │
#   │  │  │  │  (Layer 3: OS-level firewall)           │ │  │  │
#   │  │  │  └─────────────────────────────────────────┘ │  │  │
#   │  │  └──────────────────────────────────────────────┘  │  │
#   │  └─────────────────────────────────────────────────────┘  │
#   │                                                          │
#   │  ┌─── private-subnet (10.0.2.0/24) ──────────────────┐  │
#   │  │  (no VM — exists to demonstrate subnet-level NSG)  │  │
#   │  └─────────────────────────────────────────────────────┘  │
#   └──────────────────────────────────────────────────────────┘
#
# Cost: ~$0.01/hour (Standard_B1s = cheapest VM)
# Cleanup: Run azure-cloud-lab-teardown.sh or:
#          az group delete --name cloud-sec-lab --yes --no-wait
# ============================================================================

set -euo pipefail

# ── Configuration ──
RG="cloud-sec-lab"
LOCATION="eastus"                    # Change if needed
VNET="cloud-sec-vnet"
SUBNET_PUB="public-subnet"
SUBNET_PRIV="private-subnet"
NSG_SUBNET="nsg-subnet"             # Attached to subnet (NACL-like)
NSG_NIC="nsg-nic"                   # Attached to NIC (SG-like)
VM_NAME="web-vm"
VM_SIZE="Standard_B1s"              # Cheapest (~$0.01/hr)
VM_IMAGE="Ubuntu2204"
ADMIN_USER="azurelab"

echo "============================================"
echo "  Cloud Security Lab — Azure Provisioning"
echo "============================================"
echo ""
echo "Resource Group: $RG"
echo "Location:       $LOCATION"
echo "VM Size:        $VM_SIZE (~\$0.01/hr)"
echo ""

# ── Step 1: Resource Group ──
echo "[1/9] Creating resource group..."
az group create --name "$RG" --location "$LOCATION" --output none

# ── Step 2: VNet + Subnets ──
echo "[2/9] Creating VNet and subnets..."
az network vnet create \
  --resource-group "$RG" \
  --name "$VNET" \
  --address-prefix 10.0.0.0/16 \
  --subnet-name "$SUBNET_PUB" \
  --subnet-prefix 10.0.1.0/24 \
  --output none

az network vnet subnet create \
  --resource-group "$RG" \
  --vnet-name "$VNET" \
  --name "$SUBNET_PRIV" \
  --address-prefix 10.0.2.0/24 \
  --output none

# ── Step 3: NSG — Subnet level (NACL equivalent) ──
echo "[3/9] Creating subnet-level NSG (NACL equivalent)..."
az network nsg create \
  --resource-group "$RG" \
  --name "$NSG_SUBNET" \
  --output none

# Start OPEN — we'll add/remove rules during exercises
# Allow SSH inbound (so we don't lock ourselves out)
az network nsg rule create \
  --resource-group "$RG" \
  --nsg-name "$NSG_SUBNET" \
  --name AllowSSH \
  --priority 100 \
  --direction Inbound \
  --access Allow \
  --protocol Tcp \
  --destination-port-ranges 22 \
  --source-address-prefixes '*' \
  --output none

# Allow HTTP inbound
az network nsg rule create \
  --resource-group "$RG" \
  --nsg-name "$NSG_SUBNET" \
  --name AllowHTTP \
  --priority 200 \
  --direction Inbound \
  --access Allow \
  --protocol Tcp \
  --destination-port-ranges 80 \
  --source-address-prefixes '*' \
  --output none

# ── Step 4: Attach NSG to subnet ──
echo "[4/9] Attaching NSG to public subnet..."
az network vnet subnet update \
  --resource-group "$RG" \
  --vnet-name "$VNET" \
  --name "$SUBNET_PUB" \
  --network-security-group "$NSG_SUBNET" \
  --output none

# ── Step 5: NSG — NIC level (Security Group equivalent) ──
echo "[5/9] Creating NIC-level NSG (Security Group equivalent)..."
az network nsg create \
  --resource-group "$RG" \
  --name "$NSG_NIC" \
  --output none

# Allow SSH
az network nsg rule create \
  --resource-group "$RG" \
  --nsg-name "$NSG_NIC" \
  --name AllowSSH \
  --priority 100 \
  --direction Inbound \
  --access Allow \
  --protocol Tcp \
  --destination-port-ranges 22 \
  --source-address-prefixes '*' \
  --output none

# Allow HTTP
az network nsg rule create \
  --resource-group "$RG" \
  --nsg-name "$NSG_NIC" \
  --name AllowHTTP \
  --priority 200 \
  --direction Inbound \
  --access Allow \
  --protocol Tcp \
  --destination-port-ranges 80 \
  --source-address-prefixes '*' \
  --output none

# ── Step 6: Public IP ──
echo "[6/9] Creating public IP..."
az network public-ip create \
  --resource-group "$RG" \
  --name "${VM_NAME}-pip" \
  --sku Standard \
  --allocation-method Static \
  --output none

# ── Step 7: NIC with NSG attached ──
echo "[7/9] Creating NIC with NSG attached..."
az network nic create \
  --resource-group "$RG" \
  --name "${VM_NAME}-nic" \
  --vnet-name "$VNET" \
  --subnet "$SUBNET_PUB" \
  --network-security-group "$NSG_NIC" \
  --public-ip-address "${VM_NAME}-pip" \
  --output none

# ── Step 8: VM ──
echo "[8/9] Creating VM (this takes ~60 seconds)..."
az vm create \
  --resource-group "$RG" \
  --name "$VM_NAME" \
  --nics "${VM_NAME}-nic" \
  --image "$VM_IMAGE" \
  --size "$VM_SIZE" \
  --admin-username "$ADMIN_USER" \
  --generate-ssh-keys \
  --custom-data @- <<'CLOUD_INIT' \
  --output none
#!/bin/bash
apt-get update -qq
apt-get install -y -qq nginx conntrack iptables > /dev/null 2>&1
systemctl enable --now nginx
# Create a test page that shows connection info
cat > /var/www/html/index.html <<'HTML'
<pre>
=== Cloud Security Lab ===
Host: web-vm
Service: nginx on port 80

If you see this, ALL THREE layers allowed your traffic:
  1. NSG-subnet (NACL equivalent)
  2. NSG-nic   (Security Group equivalent)
  3. iptables  (OS-level firewall — currently ACCEPT)
</pre>
HTML
CLOUD_INIT

# ── Step 9: Output ──
echo "[9/9] Fetching connection details..."
echo ""

PUBLIC_IP=$(az network public-ip show \
  --resource-group "$RG" \
  --name "${VM_NAME}-pip" \
  --query ipAddress -o tsv)

PRIVATE_IP=$(az network nic show \
  --resource-group "$RG" \
  --name "${VM_NAME}-nic" \
  --query ipConfigurations[0].privateIpAddress -o tsv)

echo "============================================"
echo "  Lab Ready!"
echo "============================================"
echo ""
echo "  Public IP:   $PUBLIC_IP"
echo "  Private IP:  $PRIVATE_IP"
echo "  SSH:         ssh ${ADMIN_USER}@${PUBLIC_IP}"
echo "  HTTP test:   curl http://${PUBLIC_IP}"
echo ""
echo "  NSG (subnet): $NSG_SUBNET  — NACL equivalent"
echo "  NSG (NIC):    $NSG_NIC     — Security Group equivalent"
echo "  iptables:     inside the VM (OS level)"
echo ""
echo "  Two layers of NSGs:"
echo "    Internet → [NSG-subnet] → [NSG-nic] → [iptables] → nginx"
echo ""
echo "============================================"
echo "  Cost: ~\$0.01/hour (Standard_B1s)"
echo "  Teardown: az group delete --name $RG --yes --no-wait"
echo "============================================"

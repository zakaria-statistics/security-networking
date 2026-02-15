#!/usr/bin/env bash
# ============================================================================
# Azure Cloud Security Lab — Infrastructure Teardown
# ============================================================================
# Deletes all resources created by azure-cloud-lab-setup.sh
#
# Two modes:
#   Fast (default): Deletes the entire resource group (all resources at once)
#   Granular (--granular): Deletes resources individually in reverse order
#
# Usage:
#   ./azure-cloud-lab-teardown.sh              # Fast — delete resource group
#   ./azure-cloud-lab-teardown.sh --granular   # Delete resources one by one
# ============================================================================

set -euo pipefail

# ── Configuration (must match setup script) ──
RG="cloud-sec-lab"
VNET="cloud-sec-vnet"
SUBNET_PUB="public-subnet"
NSG_SUBNET="nsg-subnet"
NSG_NIC="nsg-nic"
VM_NAME="web-vm"

echo "============================================"
echo "  Cloud Security Lab — Azure Teardown"
echo "============================================"
echo ""
echo "Resource Group: $RG"
echo ""

# ── Check if resource group exists ──
if ! az group show --name "$RG" &>/dev/null; then
  echo "Resource group '$RG' does not exist. Nothing to tear down."
  exit 0
fi

# ── Fast mode: delete entire resource group ──
if [[ "${1:-}" != "--granular" ]]; then
  echo "Mode: Fast (delete entire resource group)"
  echo ""
  read -rp "Delete resource group '$RG' and ALL its resources? [y/N] " confirm
  if [[ "$confirm" =~ ^[Yy]$ ]]; then
    echo "Deleting resource group '$RG' (runs in background)..."
    az group delete --name "$RG" --yes --no-wait
    echo ""
    echo "Deletion started. Resources will be removed in ~2-5 minutes."
    echo "Monitor: az group show --name $RG --query properties.provisioningState -o tsv"
  else
    echo "Cancelled."
  fi
  exit 0
fi

# ── Granular mode: delete resources in reverse creation order ──
echo "Mode: Granular (delete resources individually)"
echo ""
read -rp "Delete all lab resources in '$RG' one by one? [y/N] " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
  echo "Cancelled."
  exit 0
fi

# Step 1: Delete VM (must go first — holds references to NIC, disk, etc.)
echo "[1/7] Deleting VM '$VM_NAME'..."
az vm delete \
  --resource-group "$RG" \
  --name "$VM_NAME" \
  --yes \
  --output none 2>/dev/null || echo "  (not found, skipping)"

# Step 2: Delete NIC
echo "[2/7] Deleting NIC '${VM_NAME}-nic'..."
az network nic delete \
  --resource-group "$RG" \
  --name "${VM_NAME}-nic" \
  --output none 2>/dev/null || echo "  (not found, skipping)"

# Step 3: Delete Public IP
echo "[3/7] Deleting Public IP '${VM_NAME}-pip'..."
az network public-ip delete \
  --resource-group "$RG" \
  --name "${VM_NAME}-pip" \
  --output none 2>/dev/null || echo "  (not found, skipping)"

# Step 4: Delete OS disk (auto-created with VM)
echo "[4/7] Deleting OS disk..."
DISK_ID=$(az disk list \
  --resource-group "$RG" \
  --query "[?starts_with(name, '${VM_NAME}')].id" -o tsv 2>/dev/null)
if [[ -n "$DISK_ID" ]]; then
  az disk delete --ids "$DISK_ID" --yes --output none
else
  echo "  (not found, skipping)"
fi

# Step 5: Detach NSG from subnet, then delete NSGs
echo "[5/7] Detaching and deleting NSGs..."
az network vnet subnet update \
  --resource-group "$RG" \
  --vnet-name "$VNET" \
  --name "$SUBNET_PUB" \
  --network-security-group "" \
  --output none 2>/dev/null || true

az network nsg delete \
  --resource-group "$RG" \
  --name "$NSG_NIC" \
  --output none 2>/dev/null || echo "  ($NSG_NIC not found, skipping)"

az network nsg delete \
  --resource-group "$RG" \
  --name "$NSG_SUBNET" \
  --output none 2>/dev/null || echo "  ($NSG_SUBNET not found, skipping)"

# Step 6: Delete VNet (deletes subnets with it)
echo "[6/7] Deleting VNet '$VNET'..."
az network vnet delete \
  --resource-group "$RG" \
  --name "$VNET" \
  --output none 2>/dev/null || echo "  (not found, skipping)"

# Step 7: Delete resource group
echo "[7/7] Deleting resource group '$RG'..."
az group delete --name "$RG" --yes --no-wait

echo ""
echo "============================================"
echo "  Teardown complete"
echo "============================================"
echo "Resource group deletion runs in background."
echo "Monitor: az group show --name $RG --query properties.provisioningState -o tsv"
echo "============================================"

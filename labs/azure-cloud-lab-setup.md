# Azure Cloud Security Lab — Manual Setup Guide

> Step-by-step commands to run individually. Set variables once, then run each block at your own pace.

## Table of Contents
1. [Variables](#1-variables) — Set once, reuse in all steps
2. [Resource Group](#2-resource-group)
3. [VNet + Subnets](#3-vnet--subnets)
4. [NSG — Subnet level (NACL)](#4-nsg--subnet-level-nacl)
5. [Attach NSG to Subnet](#5-attach-nsg-to-subnet)
6. [NSG — NIC level (Security Group)](#6-nsg--nic-level-security-group)
7. [Public IP](#7-public-ip)
8. [NIC](#8-nic)
9. [VM](#9-vm)
10. [Verify & Connect](#10-verify--connect)

---

## Architecture

```
Your PC (internet)
    │
    ▼
┌──────────────────────────────────────────────────────────┐
│  VNet: cloud-sec-vnet  (10.0.0.0/16)                    │
│                                                          │
│  ┌─── public-subnet (10.0.1.0/24) ───────────────────┐  │
│  │  NSG-subnet (subnet-level = "NACL" equivalent)     │  │
│  │                                                     │  │
│  │  ┌──────────────────────────────────────────────┐  │  │
│  │  │  web-vm  (10.0.1.4)                          │  │  │
│  │  │  NSG-nic (NIC-level = "Security Group")      │  │  │
│  │  │  ┌─────────────────────────────────────────┐ │  │  │
│  │  │  │  Ubuntu 22.04 + nginx + iptables        │ │  │  │
│  │  │  └─────────────────────────────────────────┘ │  │  │
│  │  └──────────────────────────────────────────────┘  │  │
│  └─────────────────────────────────────────────────────┘  │
│                                                          │
│  ┌─── private-subnet (10.0.2.0/24) ──────────────────┐  │
│  │  (no VM — exists to demonstrate subnet-level NSG)  │  │
│  └─────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────┘
```

---

## 1. Variables

Set these once in your shell session — all steps below reference them.

```bash
RG="cloud-sec-lab"
LOCATION="eastus"
VNET="cloud-sec-vnet"
SUBNET_PUB="public-subnet"
SUBNET_PRIV="private-subnet"
NSG_SUBNET="nsg-subnet"
NSG_NIC="nsg-nic"
VM_NAME="web-vm"
VM_SIZE="Standard_B1s"
VM_IMAGE="Ubuntu2204"
ADMIN_USER="azurelab"
```

---

## 2. Resource Group

```bash
az group create \
  --name "$RG" \
  --location "$LOCATION"
```

**Verify:**
```bash
az group show --name "$RG" --query "{name:name, location:location, state:properties.provisioningState}"
```

---

## 3. VNet + Subnets

Create VNet with the public subnet in one shot:
```bash
az network vnet create \
  --resource-group "$RG" \
  --name "$VNET" \
  --address-prefix 10.0.0.0/16 \
  --subnet-name "$SUBNET_PUB" \
  --subnet-prefix 10.0.1.0/24
```

Add the private subnet:
```bash
az network vnet subnet create \
  --resource-group "$RG" \
  --vnet-name "$VNET" \
  --name "$SUBNET_PRIV" \
  --address-prefix 10.0.2.0/24
```

**Verify:**
```bash
az network vnet subnet list \
  --resource-group "$RG" \
  --vnet-name "$VNET" \
  --output json
```

---

## 4. NSG — Subnet level (NACL)

> This NSG attaches to the **subnet** — traffic to any VM in the subnet hits this first.
> Conceptually equivalent to AWS NACLs (stateless, evaluated before reaching the VM).

Create the NSG:
```bash
az network nsg create \
  --resource-group "$RG" \
  --name "$NSG_SUBNET"
```

Allow SSH inbound:
```bash
az network nsg rule create \
  --resource-group "$RG" \
  --nsg-name "$NSG_SUBNET" \
  --name AllowSSH \
  --priority 100 \
  --direction Inbound \
  --access Allow \
  --protocol Tcp \
  --destination-port-ranges 22 \
  --source-address-prefixes '*'
```

Allow HTTP inbound:
```bash
az network nsg rule create \
  --resource-group "$RG" \
  --nsg-name "$NSG_SUBNET" \
  --name AllowHTTP \
  --priority 200 \
  --direction Inbound \
  --access Allow \
  --protocol Tcp \
  --destination-port-ranges 80 \
  --source-address-prefixes '*'
```

**Verify:**
```bash
az network nsg rule list \
  --resource-group "$RG" \
  --nsg-name "$NSG_SUBNET" \
  --output json
```

---

## 5. Attach NSG to Subnet

```bash
az network vnet subnet update \
  --resource-group "$RG" \
  --vnet-name "$VNET" \
  --name "$SUBNET_PUB" \
  --network-security-group "$NSG_SUBNET"
```

**Verify:**
```bash
az network vnet subnet show \
  --resource-group "$RG" \
  --vnet-name "$VNET" \
  --name "$SUBNET_PUB" \
  --query "networkSecurityGroup.id" \
  --output tsv
```

---

## 6. NSG — NIC level (Security Group)

> This NSG attaches directly to the **VM's NIC** — second layer after the subnet NSG.
> Conceptually equivalent to AWS Security Groups (stateful, per-instance).

Create the NSG:
```bash
az network nsg create \
  --resource-group "$RG" \
  --name "$NSG_NIC"
```

Allow SSH inbound:
```bash
az network nsg rule create \
  --resource-group "$RG" \
  --nsg-name "$NSG_NIC" \
  --name AllowSSH \
  --priority 100 \
  --direction Inbound \
  --access Allow \
  --protocol Tcp \
  --destination-port-ranges 22 \
  --source-address-prefixes '*'
```

Allow HTTP inbound:
```bash
az network nsg rule create \
  --resource-group "$RG" \
  --nsg-name "$NSG_NIC" \
  --name AllowHTTP \
  --priority 200 \
  --direction Inbound \
  --access Allow \
  --protocol Tcp \
  --destination-port-ranges 80 \
  --source-address-prefixes '*'
```

**Verify:**
```bash
az network nsg rule list \
  --resource-group "$RG" \
  --nsg-name "$NSG_NIC" \
  --output table
```

---

## 7. Public IP

```bash
az network public-ip create \
  --resource-group "$RG" \
  --name "${VM_NAME}-pip" \
  --sku Standard \
  --allocation-method Static
```

**Verify:**
```bash
az network public-ip show \
  --resource-group "$RG" \
  --name "${VM_NAME}-pip" \
  --query "{ip:ipAddress, sku:sku.name, allocation:publicIpAllocationMethod}"
```

---

## 8. NIC

Creates the NIC, binds it to the subnet, attaches the NIC-level NSG, and assigns the public IP:

```bash
az network nic create \
  --resource-group "$RG" \
  --name "${VM_NAME}-nic" \
  --vnet-name "$VNET" \
  --subnet "$SUBNET_PUB" \
  --network-security-group "$NSG_NIC" \
  --public-ip-address "${VM_NAME}-pip"
```

**Verify:**
```bash
az network nic show \
  --resource-group "$RG" \
  --name "${VM_NAME}-nic" \
  --query "{privateIp:ipConfigurations[0].privateIpAddress, nsg:networkSecurityGroup.id}" \
  --output json
```

---

## 9. VM

> `--generate-ssh-keys` creates `~/.ssh/id_rsa` if it doesn't exist. The cloud-init script installs nginx and iptables on first boot.

```bash
az vm create \
  --resource-group "$RG" \
  --name "$VM_NAME" \
  --nics "${VM_NAME}-nic" \
  --image "$VM_IMAGE" \
  --size "$VM_SIZE" \
  --admin-username "$ADMIN_USER" \
  --generate-ssh-keys \
  --custom-data @- <<'CLOUD_INIT'
#!/bin/bash
apt-get update -qq
apt-get install -y -qq nginx conntrack iptables > /dev/null 2>&1
systemctl enable --now nginx
cat > /var/www/html/index.html <<'HTML'
<pre>
=== Cloud Security Lab ===
Host: web-vm
Service: nginx on port 80

If you see this, ALL THREE layers allowed your traffic:
  1. NSG-subnet (NACL equivalent)
  2. NSG-nic   (Security Group equivalent)
  3. iptables  (OS-level firewall - currently ACCEPT)
</pre>
HTML
CLOUD_INIT
```

> VM provisioning takes ~60 seconds. Cloud-init (nginx install) takes another ~2 min after that.

**Verify VM is running:**
```bash
az vm show \
  --resource-group "$RG" \
  --name "$VM_NAME" \
  --query "{state:powerState, size:hardwareProfile.vmSize}" \
  --show-details
```

---

## 10. Verify & Connect

Get the public IP:
```bash
PUBLIC_IP=$(az network public-ip show \
  --resource-group "$RG" \
  --name "${VM_NAME}-pip" \
  --query ipAddress -o tsv)
echo $PUBLIC_IP
```

Get the private IP:
```bash
PRIVATE_IP=$(az network nic show \
  --resource-group "$RG" \
  --name "${VM_NAME}-nic" \
  --query ipConfigurations[0].privateIPAddress -o tsv)
echo $PRIVATE_IP
```

Test HTTP (wait ~2 min after VM creation for cloud-init to finish):
```bash
curl http://$PUBLIC_IP
```

SSH into the VM:
```bash
ssh ${ADMIN_USER}@${PUBLIC_IP}
```

---

## Teardown

```bash
az group delete --name "$RG" --yes --no-wait
```

Cost while running: ~$0.01/hour (Standard_B1s)

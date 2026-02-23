# Azure Cloud Security Lab — Architecture Review

> Review of `azure-cloud-lab-setup.md` covering architecture analysis, security gaps, strengths, and improvement suggestions.

## Table of Contents
1. [Architecture Summary](#architecture-summary) - What's deployed
2. [Strengths](#strengths) - What the design does well
3. [Gaps & Missing Components](#gaps--missing-components) - What's absent or weak
4. [Improvement Suggestions](#improvement-suggestions) - Recommended additions
5. [NSG Rule Analysis](#nsg-rule-analysis) - Per-NSG review
6. [Excalidraw Diagram](#excalidraw-diagram) - Visual architecture

---

## Architecture Summary

```
Internet
    │
    ▼
┌──────────────────────────────────────────────────────────────────┐
│  VNet: cloud-sec-vnet  (10.0.0.0/16)                            │
│                                                                  │
│  ┌─── public-subnet (10.0.1.0/24) ──────────────────────────┐  │
│  │  NSG: nsg-public-subnet (subnet-level, stateful)          │  │
│  │    Rules: Allow SSH from MY_IP, Allow HTTP from *          │  │
│  │                                                            │  │
│  │  ┌──────────────────────────────────────────────────────┐ │  │
│  │  │  web-vm  (10.0.1.4)                                  │ │  │
│  │  │  NSG: nsg-web-nic (NIC-level)                        │ │  │
│  │  │  Public IP: yes (Static, Standard SKU)               │ │  │
│  │  │  Services: nginx :80, iptables (OS firewall)         │ │  │
│  │  └──────────────────────┬───────────────────────────────┘ │  │
│  └─────────────────────────┼─────────────────────────────────┘  │
│                            │ east-west (private)                  │
│  ┌─────────────────────────┼── private-subnet (10.0.2.0/24) ──┐ │
│  │  NSG: nsg-private-subnet (subnet-level)                     │ │
│  │    Rules: Allow SSH+3306 from 10.0.1.0/24, Deny Internet   │ │
│  │                         ▼                                   │ │
│  │  ┌──────────────────────────────────────────────────────┐  │ │
│  │  │  db-vm  (10.0.2.4)                                   │  │ │
│  │  │  NSG: nsg-db-nic (NIC-level)                         │  │ │
│  │  │  Public IP: none                                     │  │ │
│  │  │  Services: MySQL :3306                               │  │ │
│  │  └──────────────────────────────────────────────────────┘  │ │
│  └─────────────────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────────────────┘
```

**Key design pattern:** Defense-in-depth with two NSG layers (subnet + NIC) per VM, plus OS-level iptables as a third layer.

---

## Strengths

### 1. Defense-in-Depth NSG Layering
- **Subnet-level NSG** acts as broad policy (like AWS NACL placement but stateful)
- **NIC-level NSG** acts as per-VM policy (like AWS Security Group)
- Both layers must independently allow traffic — blocking at either is sufficient to deny
- Exercises explicitly teach this by removing rules at one layer

### 2. Private Subnet Isolation
- `db-vm` has no public IP — zero internet-facing surface
- Explicit `DenyInternetInbound` rule at priority 4000 makes the block visible (not relying on implicit deny alone)
- SSH to `db-vm` only via jump-host pattern through `web-vm`

### 3. SSH Hardening
- SSH locked to `MY_IP` on the public subnet — not open to the world
- Private subnet SSH only from `10.0.1.0/24` at both subnet and NIC level

### 4. Teaching Design
- Exercises progressively demonstrate layer independence (Ex1: NIC removal, Ex2: east-west, Ex3: iptables)
- Production considerations table explicitly calls out every intentional gap
- AWS comparisons help cross-cloud learners

---

## Gaps & Missing Components

### Critical for Production (High Priority)

| # | Gap | Risk | Recommendation |
|---|-----|------|----------------|
| 1 | **No outbound/egress restrictions** | A compromised VM can freely exfiltrate data or download malware | Add outbound NSG rules: allow DNS (53), HTTPS (443), deny all other egress |
| 2 | **No TLS/HTTPS** | Traffic in cleartext; credentials, sessions interceptable | Add Application Gateway or Azure Front Door with TLS termination |
| 3 | **No NSG flow logs** | Zero visibility into allowed/denied traffic | Enable NSG flow logs → Log Analytics workspace for traffic analysis |
| 4 | **No Azure Bastion** | SSH via public IP exposes port 22 to internet (even if IP-locked) | Replace public SSH with Azure Bastion; remove port 22 NSG rules entirely |
| 5 | **MySQL bind 0.0.0.0 with no auth hardening** | MySQL listens on all interfaces; root auth not configured | Bind to private IP only; create application-specific MySQL user with strong password |

### Medium Priority

| # | Gap | Risk | Recommendation |
|---|-----|------|----------------|
| 6 | **No NAT Gateway for private subnet** | `db-vm` cannot pull updates or patches | Add NAT Gateway on private subnet for controlled outbound-only internet |
| 7 | **No disk encryption with CMK** | Platform-managed keys only; limited control | Use Customer-Managed Keys via Azure Key Vault |
| 8 | **No Microsoft Defender for Cloud** | No vulnerability scanning, threat detection, or compliance checks | Enable at minimum free tier for VM protection |
| 9 | **No resource tags** | Hard to track cost, ownership, environment | Add tags: `Environment=Lab`, `Owner=student`, `Project=cloud-sec` |
| 10 | **iptables default ACCEPT** | OS firewall provides no protection until Exercise 3 | Cloud-init should set default DROP with explicit allows from the start |

### Architecture Gaps

| # | Gap | Impact | Recommendation |
|---|-----|--------|----------------|
| 11 | **No Application Security Group (ASG)** | Rules use raw CIDR blocks; harder to manage at scale | Define ASGs (e.g., `web-asg`, `db-asg`) and reference them in NSG rules |
| 12 | **No Azure Private DNS** | VMs resolve each other by IP only | Add Private DNS zone for `lab.internal` so web-vm can reach `db-vm.lab.internal` |
| 13 | **No availability / redundancy** | Single VM per tier = single point of failure | For production: VM Scale Sets or Availability Zones (fine for lab) |
| 14 | **No monitoring/alerting** | No alerts on SSH brute-force, NSG deny spikes, or VM health | Azure Monitor + Log Analytics + alert rules on key metrics |
| 15 | **No backup** | No recovery path if VMs are compromised or data lost | Azure Backup for VMs, especially db-vm |

---

## Improvement Suggestions

### Quick Wins (Minimal Effort)

1. **Add outbound deny rules** to both subnet NSGs — allow only DNS + HTTPS outbound
2. **Harden cloud-init for db-vm** — create a MySQL user with a password, don't leave root open
3. **Set iptables default DROP in cloud-init** for web-vm (move Exercise 3 content into base config)
4. **Enable NSG flow logs** — single `az` command per NSG, massive visibility gain
5. **Add resource tags** to the resource group

### Medium Effort

6. **Add a NAT Gateway** to the private subnet for controlled outbound
7. **Add an exercise for ASGs** — teach the concept of grouping VMs by role instead of raw CIDRs
8. **Add Azure Private DNS** — teaches DNS resolution patterns in cloud networking

### Would Enhance the Lab Significantly

9. **Add Azure Bastion exercise** — compare Bastion access vs. direct SSH; remove port 22 entirely
10. **Add HTTPS exercise** — self-signed cert on nginx, then discuss Azure-managed certs
11. **Add an "attacker" exercise** — spin up a third VM in a separate VNet to test cross-VNet isolation

---

## NSG Rule Analysis

### nsg-public-subnet (Subnet-level)
| Rule | Priority | Direction | Access | Protocol | Source | Dest Port | Assessment |
|------|----------|-----------|--------|----------|--------|-----------|------------|
| AllowSSH | 100 | Inbound | Allow | TCP | MY_IP | 22 | Good — locked to operator IP |
| AllowHTTP | 200 | Inbound | Allow | TCP | * | 80 | Acceptable for lab; prod needs HTTPS |
| *(no outbound rules)* | — | — | — | — | — | — | **Gap** — all egress allowed |

### nsg-private-subnet (Subnet-level)
| Rule | Priority | Direction | Access | Protocol | Source | Dest Port | Assessment |
|------|----------|-----------|--------|----------|--------|-----------|------------|
| AllowSSHFromPublicSubnet | 100 | Inbound | Allow | TCP | 10.0.1.0/24 | 22 | Good — jump-host only |
| AllowDBFromPublicSubnet | 200 | Inbound | Allow | TCP | 10.0.1.0/24 | 3306 | Good — web-tier only |
| DenyInternetInbound | 4000 | Inbound | Deny | * | Internet | * | Good — explicit deny |
| *(no outbound rules)* | — | — | — | — | — | — | **Gap** — db-vm can reach internet outbound |

### nsg-web-nic (NIC-level)
| Rule | Priority | Direction | Access | Protocol | Source | Dest Port | Assessment |
|------|----------|-----------|--------|----------|--------|-----------|------------|
| AllowSSH | 100 | Inbound | Allow | TCP | MY_IP | 22 | Good — mirrors subnet rule |
| AllowHTTP | 200 | Inbound | Allow | TCP | * | 80 | Good — matches web role |

### nsg-db-nic (NIC-level)
| Rule | Priority | Direction | Access | Protocol | Source | Dest Port | Assessment |
|------|----------|-----------|--------|----------|--------|-----------|------------|
| AllowSSHFromWebSubnet | 100 | Inbound | Allow | TCP | 10.0.1.0/24 | 22 | Good — matches subnet rule |
| AllowDBFromWebSubnet | 200 | Inbound | Allow | TCP | 10.0.1.0/24 | 3306 | Good — matches subnet rule |

**Overall NSG assessment:** Inbound rules are well-designed with proper defense-in-depth. The main gap is the complete absence of outbound/egress rules across all four NSGs.

---

## Excalidraw Diagram

> **Note:** Excalidraw MCP tools were not available in the current agent toolset. The ASCII architecture diagram above captures the full topology. A visual Excalidraw diagram can be created manually at [excalidraw.com](https://excalidraw.com) using the layout described above.

**Suggested diagram elements:**
- VNet boundary box (10.0.0.0/16)
- Two subnet boxes: public (10.0.1.0/24) and private (10.0.2.0/24)
- NSG shield icons at subnet boundaries and NIC level
- web-vm box with public IP indicator
- db-vm box with "no public IP" indicator
- North-south arrow: Internet → web-vm
- East-west arrow: web-vm → db-vm (labeled: SSH:22, MySQL:3306)
- Color coding: green for allowed flows, red for denied flows

---

*Review date: 2026-02-20*

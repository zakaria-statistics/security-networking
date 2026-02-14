# Cloud Security Lab: Security Groups, NACLs, and iptables
> Understand the layered security model — what blocks where and how to debug across layers

## Table of Contents
1. [Overview](#1-overview) - Why three layers and how they interact
2. [The Layered Model](#2-the-layered-model) - SG vs NACL vs iptables mental map
3. [Phase 1: Security Groups Deep Dive](#3-phase-1-security-groups-deep-dive) - Stateful hypervisor-level filtering
4. [Phase 2: NACLs Deep Dive](#4-phase-2-nacls-deep-dive) - Stateless subnet-level filtering
5. [Phase 3: iptables Inside the VM](#5-phase-3-iptables-inside-the-vm) - Last-mile enforcement
6. [Phase 4: The Matrix — What Blocks Where](#6-phase-4-the-matrix---what-blocks-where) - Layered decision table
7. [Phase 5: Debugging Across Layers](#7-phase-5-debugging-across-layers) - "SG allows it but it still fails"
8. [Phase 6: Egress Control](#8-phase-6-egress-control) - Outbound restrictions for compliance
9. [Phase 7: Lab Exercises (Azure)](#9-phase-7-lab-exercises-azure) - Real cloud infra with two NSG layers + iptables
10. [Phase 8: Cloud Provider Mapping](#10-phase-8-cloud-provider-mapping) - AWS vs Azure vs GCP equivalents
11. [Quick Reference](#11-quick-reference) - Decision flowchart and cheat sheet

## Overview

You already know iptables inside the VM. In the cloud, two **additional** layers
sit outside your VM before traffic ever reaches iptables:

```
Internet Traffic
       │
       ▼
┌──────────────────────────────┐
│  Layer 1: NACL (subnet)      │  ← Stateless, applies to ALL instances in subnet
│  Inbound rules + Outbound    │     Both directions evaluated independently
│  rules (numbered, ordered)   │
└──────────┬───────────────────┘
           │
           ▼
┌──────────────────────────────┐
│  Layer 2: Security Group     │  ← Stateful, applies per-instance (per-ENI)
│  (instance / ENI)            │     Return traffic auto-allowed
│  Inbound rules only needed   │
└──────────┬───────────────────┘
           │
           ▼
┌──────────────────────────────┐
│  Layer 3: iptables / nftables│  ← Inside the VM (OS-level)
│  (guest OS)                  │     What you practiced in iptables-lab.md
└──────────────────────────────┘
```

**Key insight:** Traffic must pass ALL three layers. Any one of them saying "no"
means the packet is dropped — even if the other two allow it.

**Prerequisite knowledge:**
- Stateful firewall (ESTABLISHED,RELATED) from iptables-lab.md
- NAT concepts from nat-lab.md
- Packet flow from packet-journey.md

---

## 2. The Layered Model

### Analogy: Building Security

```
NACL        = Building front door     (checks everyone entering/leaving)
              Stateless — guard checks badge on the way IN and again on the way OUT
              Applies to entire floor (subnet)

Security    = Office door             (checks per-office)
Group         Stateful — if you were let in, you can leave without re-checking
              Applies per-instance

iptables    = Desk-level lock         (personal device security)
              Stateful — full conntrack, rate limiting, logging, NAT
              Applies inside one machine
```

### Property Comparison

```
┌────────────────────┬──────────────────┬──────────────────┬──────────────────┐
│ Property           │ NACL             │ Security Group   │ iptables         │
├────────────────────┼──────────────────┼──────────────────┼──────────────────┤
│ Scope              │ Subnet           │ Instance (ENI)   │ OS (guest)       │
│ Stateful?          │ NO               │ YES              │ YES (conntrack)  │
│ Default            │ Allow all        │ Deny all inbound │ Varies (distro)  │
│                    │ (default NACL)   │ Allow all outbound│                 │
│ Rule evaluation    │ Numbered order   │ All rules eval'd │ First match wins │
│                    │ (first match)    │ (union/OR logic) │ (top-down)       │
│ Explicit deny?     │ YES              │ NO (allow-only)  │ YES              │
│ Return traffic     │ Must allow both  │ Auto-allowed     │ ESTABLISHED,     │
│                    │ directions       │                  │ RELATED rule     │
│ Logging            │ VPC Flow Logs    │ VPC Flow Logs    │ LOG target       │
│ Rate limiting      │ NO               │ NO               │ YES (-m recent)  │
│ NAT capable?       │ NO               │ NO               │ YES              │
│ Who manages it?    │ Cloud team/Infra │ DevOps/App team  │ SysAdmin/DevOps  │
└────────────────────┴──────────────────┴──────────────────┴──────────────────┘
```

---

## 3. Phase 1: Security Groups Deep Dive

### What a Security Group IS

A Security Group is a **virtual firewall at the hypervisor level** — it operates
OUTSIDE your VM's network stack. Your OS never sees blocked packets.

```
                    Hypervisor (host machine)
                    ┌───────────────────────────────┐
                    │                               │
  Packet ──────────►│  Security Group evaluation    │
                    │  (allow-list, stateful)       │
                    │         │                     │
                    │         ▼ (if allowed)        │
                    │  ┌─────────────────────┐      │
                    │  │     Your VM          │      │
                    │  │  ┌───────────────┐  │      │
                    │  │  │  iptables     │  │      │
                    │  │  │  (OS-level)   │  │      │
                    │  │  └───────────────┘  │      │
                    │  └─────────────────────┘      │
                    └───────────────────────────────┘
```

### Key Behaviors

**1. Allow-only (no explicit deny)**

```
SG Rule: Allow TCP 22 from 10.0.0.0/24
SG Rule: Allow TCP 80 from 0.0.0.0/0

# There is NO way to say:
# "Allow TCP 80 from everyone EXCEPT 10.0.0.5"
# For that, you need NACLs or iptables
```

**2. Stateful — return traffic is automatic**

```
Inbound rule: Allow TCP 80 from 0.0.0.0/0

Client sends:    SRC=1.2.3.4:54321 DST=10.0.0.5:80     ← allowed by inbound rule
Server responds: SRC=10.0.0.5:80   DST=1.2.3.4:54321   ← auto-allowed (stateful)

# You do NOT need an outbound rule for the response
# Compare with iptables: you need ESTABLISHED,RELATED
# Compare with NACLs: you MUST add an outbound rule for ephemeral ports
```

**3. All rules are evaluated (union/OR)**

```
Rule 1: Allow TCP 22 from 10.0.0.0/24
Rule 2: Allow TCP 22 from 172.16.0.0/16

# Result: TCP 22 allowed from BOTH 10.0.0.0/24 AND 172.16.0.0/16
# There is no ordering — all rules are OR'd together
# This is DIFFERENT from iptables (first-match-wins)
```

**4. Applied per-ENI (network interface)**

```
Instance has 2 ENIs:
  eth0 (public subnet)  → SG-web  (allows 80, 443)
  eth1 (private subnet) → SG-db   (allows 3306 from app-tier only)

# Different SGs on different interfaces of the SAME instance
```

### Typical SG Design Patterns

**Pattern 1: Web tier**
```
SG-web:
  Inbound:
    TCP 80   from 0.0.0.0/0     (HTTP)
    TCP 443  from 0.0.0.0/0     (HTTPS)
    TCP 22   from SG-bastion     (SSH from bastion only)
  Outbound:
    All traffic to 0.0.0.0/0     (default — allow all out)
```

**Pattern 2: App tier (reference another SG)**
```
SG-app:
  Inbound:
    TCP 8080 from SG-web         (only web tier can reach app)
    TCP 22   from SG-bastion
  Outbound:
    All traffic
```

**Pattern 3: DB tier**
```
SG-db:
  Inbound:
    TCP 3306 from SG-app         (only app tier can reach DB)
    TCP 22   from SG-bastion
  Outbound:
    All traffic
```

```
Internet → SG-web → [Web Tier] → SG-app → [App Tier] → SG-db → [DB Tier]

Each tier only accepts traffic from the tier in front of it.
SG-to-SG references mean: "allow from any instance with that SG attached."
```

---

## 4. Phase 2: NACLs Deep Dive

### What a NACL IS

Network Access Control List — a **stateless** firewall at the **subnet** level.

```
┌─────────────────────────────────────────────┐
│  VPC                                         │
│  ┌────────────────────────────────────┐      │
│  │  Subnet (10.0.1.0/24)             │      │
│  │  NACL attached here ◄─────────    │      │
│  │                                    │      │
│  │  ┌──────┐  ┌──────┐  ┌──────┐    │      │
│  │  │ VM-1 │  │ VM-2 │  │ VM-3 │    │      │
│  │  │ SG-a │  │ SG-b │  │ SG-a │    │      │
│  │  └──────┘  └──────┘  └──────┘    │      │
│  └────────────────────────────────────┘      │
│                                              │
│  NACL applies to ALL traffic entering/       │
│  leaving this subnet — regardless of         │
│  which instance or SG                        │
└──────────────────────────────────────────────┘
```

### Key Behaviors

**1. Stateless — you must allow BOTH directions**

```
# Allow inbound HTTP:
Rule 100: ALLOW TCP 80 inbound from 0.0.0.0/0

# But you ALSO need outbound for the response:
Rule 100: ALLOW TCP 1024-65535 outbound to 0.0.0.0/0

# Why 1024-65535? The response goes back on the client's ephemeral port.
# If you forget the outbound rule, the SYN arrives but the SYN-ACK is blocked!

Compare with iptables:
  iptables equivalent = no ESTABLISHED,RELATED rule
  Every packet evaluated independently, no conntrack
```

**2. Numbered rules, first-match-wins**

```
NACL Inbound Rules:
  Rule 100: ALLOW TCP 80 from 0.0.0.0/0
  Rule 200: DENY  TCP 80 from 10.0.0.5/32    ← NEVER REACHED!
  Rule *  : DENY ALL (implicit)

# Rule 100 matches first → traffic allowed
# The deny on 10.0.0.5 never fires

Fix: Put specific denies BEFORE broad allows:
  Rule 50:  DENY  TCP 80 from 10.0.0.5/32    ← checked first
  Rule 100: ALLOW TCP 80 from 0.0.0.0/0      ← everything else
  Rule *  : DENY ALL
```

**3. Explicit deny capability (unlike SGs)**

```
Use case: Block a known bad IP across the entire subnet

NACL Rule 10: DENY ALL from 203.0.113.99/32

This blocks that IP for EVERY instance in the subnet,
regardless of their Security Group rules.

# This is impossible with Security Groups alone (allow-only)
```

### Default NACL vs Custom NACL

```
┌──────────────────┬───────────────────────────────────────────────┐
│                  │ Default NACL          │ Custom NACL            │
├──────────────────┼───────────────────────┼────────────────────────┤
│ Created          │ Auto with VPC         │ You create manually    │
│ Default rules    │ ALLOW ALL in/out      │ DENY ALL in/out        │
│ Subnets          │ All subnets (if not   │ Only subnets you       │
│                  │ assigned custom)      │ explicitly associate   │
│ Risk             │ Wide open (no value   │ Must add allow rules   │
│                  │ as security control)  │ or nothing works       │
└──────────────────┴───────────────────────┴────────────────────────┘

Best practice: Use custom NACLs with explicit rules.
The default NACL allowing everything provides zero security value.
```

---

## 5. Phase 3: iptables Inside the VM

You already know this from iptables-lab.md. Here's what changes in the cloud:

### When to use iptables IN ADDITION to SG/NACL

```
┌─────────────────────────────────────────────────────────────────────┐
│ Use Case                              │ SG/NACL Enough? │ iptables │
├───────────────────────────────────────┼─────────────────┼──────────┤
│ Allow HTTP from internet              │ YES (SG)        │ Optional │
│ Block specific IP                     │ YES (NACL)      │ Optional │
│ Rate-limit SSH brute force            │ NO              │ YES      │
│ Log dropped packets with detail       │ NO (flow logs   │ YES      │
│                                       │  less granular) │          │
│ NAT / port forwarding inside VM       │ NO              │ YES      │
│ Per-process outbound restrictions     │ NO              │ YES      │
│ Complex match (string, time, etc.)    │ NO              │ YES      │
│ Multi-tenant isolation on same VM     │ NO              │ YES      │
│ Defense-in-depth / golden image       │ YES (both)      │ YES      │
└───────────────────────────────────────┴─────────────────┴──────────┘
```

### The "golden image" pattern

Production VMs are often built from a hardened base image:

```
Golden Image Build:
  1. Install OS + packages
  2. Configure iptables (defense-in-depth)
     - Default DROP inbound
     - Allow SSH from management CIDR
     - Allow app port (80/443)
     - Allow ESTABLISHED,RELATED
     - LOG dropped packets
  3. Bake the image (AMI / managed image)
  4. Deploy instances from this image

Why? Even if someone misconfigures the Security Group (allows 0.0.0.0/0 to all ports),
the iptables inside the VM still blocks unauthorized traffic.
```

---

## 6. Phase 4: The Matrix — What Blocks Where

### Scenario table: Where does each layer block?

```
Scenario: Client (internet) → VM in public subnet, port 80

┌────────────────────────────────────────────────────────────────────────┐
│ #  │ NACL          │ Security Group   │ iptables       │ Result       │
├────┼───────────────┼──────────────────┼────────────────┼──────────────┤
│ 1  │ Allow 80 in   │ Allow 80         │ Allow 80       │ WORKS        │
│    │ Allow ephm out│                  │                │              │
├────┼───────────────┼──────────────────┼────────────────┼──────────────┤
│ 2  │ DENY 80       │ Allow 80         │ Allow 80       │ BLOCKED      │
│    │               │                  │                │ (NACL)       │
├────┼───────────────┼──────────────────┼────────────────┼──────────────┤
│ 3  │ Allow 80 in   │ No rule for 80   │ Allow 80       │ BLOCKED      │
│    │ Allow ephm out│                  │                │ (SG)         │
├────┼───────────────┼──────────────────┼────────────────┼──────────────┤
│ 4  │ Allow 80 in   │ Allow 80         │ DROP 80        │ BLOCKED      │
│    │ Allow ephm out│                  │ (or no rule)   │ (iptables)   │
├────┼───────────────┼──────────────────┼────────────────┼──────────────┤
│ 5  │ Allow 80 in   │ Allow 80         │ Allow 80       │ BLOCKED      │
│    │ DENY ephm out │                  │                │ (NACL out!)  │
├────┼───────────────┼──────────────────┼────────────────┼──────────────┤
│ 6  │ Allow ALL     │ Allow ALL        │ default ACCEPT │ WORKS but    │
│    │               │                  │                │ INSECURE     │
└────┴───────────────┴──────────────────┴────────────────┴──────────────┘

Scenario 5 is the sneaky one:
  - Inbound SYN arrives → NACL allows → SG allows → iptables allows → SYN-ACK generated
  - SYN-ACK leaves VM → iptables allows → SG allows (stateful, auto) → NACL BLOCKS
  - NACL is stateless! Outbound ephemeral port rule was missing.
  - SG's stateful nature doesn't help — NACL already dropped it before SG sees it.
```

### Packet flow through all layers

```
Inbound path (client → VM):

Internet
  │
  ▼
┌─────────────┐    ┌─────────────┐    ┌─────────────┐    ┌─────────────┐
│ IGW/NAT GW  │───►│ NACL        │───►│ Security    │───►│ iptables    │──► App
│             │    │ (inbound)   │    │ Group       │    │ INPUT chain │
└─────────────┘    │ stateless   │    │ (inbound)   │    │ stateful    │
                   │ check       │    │ stateful    │    │             │
                   └─────────────┘    └─────────────┘    └─────────────┘

Outbound path (VM → internet):

App
  │
  ▼
┌─────────────┐    ┌─────────────┐    ┌─────────────┐    ┌─────────────┐
│ iptables    │───►│ Security    │───►│ NACL        │───►│ IGW/NAT GW  │──► Internet
│ OUTPUT      │    │ Group       │    │ (outbound)  │    │             │
│ stateful    │    │ (outbound)  │    │ stateless   │    └─────────────┘
└─────────────┘    │ stateful    │    │ check       │
                   └─────────────┘    └─────────────┘
```

---

## 7. Phase 5: Debugging Across Layers

### The debugging workflow

When connectivity fails, check layers **outside-in**:

```
Step 1: Is traffic reaching the subnet?
        → VPC Flow Logs (NACL level)
        → Look for ACCEPT or REJECT at the subnet ENI

Step 2: Is the Security Group allowing it?
        → Check SG inbound rules
        → aws ec2 describe-security-groups --group-ids sg-xxx
        → VPC Flow Logs (accepted at NACL but rejected at SG)

Step 3: Is the OS firewall allowing it?
        → SSH into the VM
        → iptables -L -v -n (check counters)
        → dmesg | grep IPT-DROP (if LOG rules exist)
        → ss -tlnp (is the service even listening?)

Step 4: Is the application responding?
        → curl localhost:PORT (test from inside the VM)
        → systemctl status <service>
```

### Common scenarios and diagnosis

**Scenario A: "SG allows it but it still fails"**

```
Symptoms:
  - SG has rule: Allow TCP 80 from 0.0.0.0/0
  - curl from internet hangs

Diagnosis checklist:
  1. Is NACL blocking it?
     → Check NACL inbound AND outbound rules
     → Common miss: outbound ephemeral ports not allowed

  2. Is iptables blocking it?
     → SSH in, run: iptables -L INPUT -v -n
     → Look for DROP rules or default DROP policy
     → Common: hardened AMI with iptables DROP by default

  3. Is the service listening on the right interface?
     → ss -tlnp | grep :80
     → If bound to 127.0.0.1 — only local access
     → Need 0.0.0.0:80 for external access

  4. Is there a route?
     → ip route show
     → Does the VM have an IGW route for 0.0.0.0/0?
     → Private subnet with no NAT GW = no outbound = no response
```

**Scenario B: "It worked yesterday, now it doesn't"**

```
Check:
  1. SG rules changed?
     → aws ec2 describe-security-groups (or console)
     → CloudTrail: who modified the SG?

  2. NACL changed?
     → aws ec2 describe-network-acls

  3. iptables rules wiped by reboot?
     → VM rebooted and iptables not persistent
     → Or: cloud-init / user-data script overrode rules

  4. Route table changed?
     → Subnet association changed to a different route table
     → NAT Gateway deleted or replaced
```

**Scenario C: "I can reach the VM but responses are slow/dropped"**

```
Check:
  1. MTU issues (common with VPN/tunnels)
     → ping -M do -s 1472 <target>    (test for fragmentation)
     → NACL blocking ICMP type 3 (Destination Unreachable)?
     → Need ICMP "fragmentation needed" for PMTUD to work

  2. Conntrack table full (inside VM)
     → sysctl net.netfilter.nf_conntrack_count
     → sysctl net.netfilter.nf_conntrack_max
     → If count ≈ max → connections dropped silently
     → Fix: increase max or tune timeouts

  3. SG connection tracking limits (AWS-specific)
     → SGs track up to ~65,000 connections per ENI
     → High-traffic instances can hit this limit
```

### VPC Flow Logs — reading the output

```
Flow log format:
  <version> <account> <eni> <srcaddr> <dstaddr> <srcport> <dstport> <protocol> <packets> <bytes> <start> <end> <action> <log-status>

Example:
  2 123456789 eni-abc123 203.0.113.5 10.0.1.10 54321 80 6 5 300 1620000000 1620000060 ACCEPT OK
  2 123456789 eni-abc123 198.51.100.9 10.0.1.10 12345 22 6 3 180 1620000000 1620000060 REJECT OK

Reading it:
  - action=ACCEPT: traffic passed NACL+SG (but might still fail at iptables!)
  - action=REJECT: traffic blocked by NACL or SG
  - To distinguish NACL vs SG rejection: enable flow logs at both subnet and ENI level
```

---

## 8. Phase 6: Egress Control

### Why restrict outbound traffic?

```
Default: VMs can talk to ANYTHING on the internet
  - Data exfiltration risk
  - C2 (command & control) callback
  - Compliance violations (PCI-DSS, HIPAA, SOC2)
  - Cryptominer downloading payloads

Egress control layers:
  1. SG outbound rules    → broad (allow specific CIDRs/ports)
  2. NACL outbound rules  → subnet-wide deny list
  3. iptables OUTPUT      → per-VM, per-process, per-user granularity
  4. NAT Gateway + routes → force all outbound through a chokepoint
```

### Layer-by-layer egress examples

**SG egress restriction:**
```
SG-app:
  Outbound:
    TCP 443 to 0.0.0.0/0            (HTTPS to internet — updates, APIs)
    TCP 3306 to SG-db                (MySQL to DB tier)
    ALL traffic to pl-xxxxxxxx       (S3 prefix list, for AWS services)
    # Implicit deny all else

# Restricts outbound but can't do per-IP blocking
```

**NACL egress restriction:**
```
Outbound:
  Rule 50:  DENY ALL to 198.51.100.0/24     (block known bad range)
  Rule 100: ALLOW TCP 443 to 0.0.0.0/0      (HTTPS out)
  Rule 110: ALLOW TCP 1024-65535 to 0.0.0.0/0 (ephemeral for inbound responses)
  Rule *:   DENY ALL
```

**iptables egress restriction (inside VM):**
```bash
# Only allow outbound DNS, HTTPS, and established traffic
iptables -P OUTPUT DROP
iptables -A OUTPUT -o lo -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT     # DNS
iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT     # DNS over TCP
iptables -A OUTPUT -p tcp --dport 443 -j ACCEPT    # HTTPS
iptables -A OUTPUT -p tcp --dport 80 -j ACCEPT     # HTTP (updates)
iptables -A OUTPUT -j LOG --log-prefix "EGRESS-DROP: "

# Now: no SSH outbound, no arbitrary ports, no data exfiltration
# Any unexpected outbound is logged
```

---

## 9. Phase 7: Lab Exercises (Azure)

> Real Azure infrastructure with two NSG layers + iptables inside the VM.
> Provision with [azure-cloud-lab-setup.sh](azure-cloud-lab-setup.sh).

### Lab Architecture

```
Your PC (internet)
     │
     ▼
┌──────────────────────────────────────────────────────────┐
│  VNet: cloud-sec-vnet  (10.0.0.0/16)                    │
│                                                          │
│  ┌─── public-subnet (10.0.1.0/24) ───────────────────┐  │
│  │  NSG: nsg-subnet  ← Layer 1 (NACL equivalent)     │  │
│  │                                                     │  │
│  │  ┌──────────────────────────────────────────────┐  │  │
│  │  │  web-vm  (10.0.1.4 + public IP)              │  │  │
│  │  │  NSG: nsg-nic  ← Layer 2 (Security Group)    │  │  │
│  │  │  ┌─────────────────────────────────────────┐ │  │  │
│  │  │  │  Ubuntu 22.04 + nginx + iptables        │ │  │  │
│  │  │  │  ← Layer 3 (OS-level firewall)          │ │  │  │
│  │  │  └─────────────────────────────────────────┘ │  │  │
│  │  └──────────────────────────────────────────────┘  │  │
│  └─────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────┘
```

**Convention:** Commands shown with where to run them:
- `local$` = your PC (az CLI commands)
- `vm#`   = inside the Azure VM (SSH session)

### Provisioning

```bash
# Run the setup script — creates everything in ~2 minutes
local$ chmod +x azure-cloud-lab-setup.sh
local$ ./azure-cloud-lab-setup.sh

# Note the output:
#   Public IP:   <PUBLIC_IP>
#   SSH:         ssh azurelab@<PUBLIC_IP>
#   HTTP test:   curl http://<PUBLIC_IP>
```

**Verify all three layers are open:**
```bash
local$ curl http://<PUBLIC_IP>
# Expected: "=== Cloud Security Lab ===" page from nginx
```

**Save the public IP for exercises:**
```bash
local$ export VM_IP=$(az network public-ip show \
  --resource-group cloud-sec-lab \
  --name web-vm-pip \
  --query ipAddress -o tsv)
local$ echo $VM_IP
```

> **Azure NSG key difference from AWS NACLs:**
> Both NSG layers in Azure are **stateful** — return traffic is auto-allowed.
> AWS NACLs are stateless. This changes how you think about outbound rules.

---

### Exercise 1: Inspect the two NSG layers

Understand what's configured before you start modifying.

```bash
# ── Layer 1: Subnet-level NSG (NACL equivalent) ──
local$ az network nsg rule list \
  --resource-group cloud-sec-lab \
  --nsg-name nsg-subnet \
  --output table
# Expected: AllowSSH (100), AllowHTTP (200), + Azure default rules (65xxx)

# ── Layer 2: NIC-level NSG (Security Group equivalent) ──
local$ az network nsg rule list \
  --resource-group cloud-sec-lab \
  --nsg-name nsg-nic \
  --output table
# Expected: AllowSSH (100), AllowHTTP (200), + Azure default rules

# ── Layer 3: iptables inside the VM ──
local$ ssh azurelab@$VM_IP
vm# sudo iptables -L -v -n
# Expected: All chains ACCEPT, no rules (clean slate)
vm# ss -tlnp | grep :80
# Expected: nginx listening on 0.0.0.0:80
```

**Managed → Native resource mapping:**
```
az network nsg rule list (managed view)
  ↓ creates
Azure platform-level packet filter (hypervisor)
  ↓ inspect with
az network nsg rule list --output table
az network watcher show-next-hop (routing check)
```

---

### Exercise 2: Block at NSG-subnet layer (Layer 1)

**Goal:** Prove that blocking HTTP at the subnet NSG stops traffic before it
reaches the NIC NSG or iptables.

```bash
# Add a DENY rule for HTTP at subnet level (higher priority = lower number)
local$ az network nsg rule create \
  --resource-group cloud-sec-lab \
  --nsg-name nsg-subnet \
  --name DenyHTTP \
  --priority 150 \
  --direction Inbound \
  --access Deny \
  --protocol Tcp \
  --destination-port-ranges 80 \
  --source-address-prefixes '*' \
  --output none

# Test from your PC:
local$ curl -s --max-time 5 http://$VM_IP
# TIMEOUT — blocked at subnet NSG, traffic never reaches the VM

# Verify inside the VM — nginx saw nothing:
local$ ssh azurelab@$VM_IP
vm# sudo conntrack -L 2>/dev/null | grep :80
# Empty — no connections made it through
vm# tail -5 /var/log/nginx/access.log
# No new entries — packet was dropped before reaching the VM
```

**Why it works:**
```
Packet path:  Internet → [nsg-subnet: DenyHTTP pri=150] → DROPPED
                          AllowHTTP is pri=200 (lower priority)
                          Azure evaluates lowest number first
                          150 < 200 → Deny wins

This is like AWS NACL rule ordering:
  Rule 150: DENY TCP 80  ← checked first
  Rule 200: ALLOW TCP 80 ← never reached
```

**Restore:**
```bash
local$ az network nsg rule delete \
  --resource-group cloud-sec-lab \
  --nsg-name nsg-subnet \
  --name DenyHTTP

# Verify restored:
local$ curl -s --max-time 5 http://$VM_IP
# Should work again
```

---

### Exercise 3: Block at NSG-nic layer (Layer 2)

**Goal:** Subnet NSG allows HTTP, but NIC NSG blocks it.

```bash
# Remove HTTP allow from NIC NSG
local$ az network nsg rule delete \
  --resource-group cloud-sec-lab \
  --nsg-name nsg-nic \
  --name AllowHTTP

# Test:
local$ curl -s --max-time 5 http://$VM_IP
# TIMEOUT — nsg-subnet allows, but nsg-nic has no rule for 80
# Azure NSG default: deny all inbound (except Azure defaults at 65xxx)
```

**Inspect what happened:**
```bash
# nsg-subnet rules still allow HTTP:
local$ az network nsg rule list \
  --resource-group cloud-sec-lab \
  --nsg-name nsg-subnet \
  --query "[?destinationPortRanges[0]=='80' || destinationPortRange=='80']" \
  --output table
# Shows: AllowHTTP — still present

# nsg-nic has no HTTP rule:
local$ az network nsg rule list \
  --resource-group cloud-sec-lab \
  --nsg-name nsg-nic \
  --query "[?name=='AllowHTTP']" \
  --output table
# Empty — rule is gone

# SSH still works (both NSGs still allow port 22)
local$ ssh azurelab@$VM_IP
vm# sudo conntrack -L 2>/dev/null | grep :80
# Empty — the NIC NSG dropped it before the VM OS saw it
```

**Restore:**
```bash
local$ az network nsg rule create \
  --resource-group cloud-sec-lab \
  --nsg-name nsg-nic \
  --name AllowHTTP \
  --priority 200 \
  --direction Inbound \
  --access Allow \
  --protocol Tcp \
  --destination-port-ranges 80 \
  --source-address-prefixes '*' \
  --output none

local$ curl -s --max-time 5 http://$VM_IP    # Works again
```

---

### Exercise 4: Block at iptables layer (Layer 3)

**Goal:** Both NSGs allow HTTP, but iptables inside the VM blocks it.

```bash
local$ ssh azurelab@$VM_IP

# Add iptables DROP for port 80
vm# sudo iptables -A INPUT -p tcp --dport 80 -j DROP

# Test from your PC (in another terminal):
local$ curl -s --max-time 5 http://$VM_IP
# TIMEOUT — both NSGs said yes, but iptables dropped it

# On the VM — verify the packet reached iptables:
vm# sudo iptables -L INPUT -v -n
# The DROP rule counter should show packets increasing
# This proves the packet passed both NSGs but was dropped at the OS level
```

**Restore:**
```bash
vm# sudo iptables -D INPUT -p tcp --dport 80 -j DROP
local$ curl -s --max-time 5 http://$VM_IP    # Works again
```

---

### Exercise 5: Golden image firewall (defense-in-depth)

**Goal:** Configure iptables as a hardened "golden image" baseline that
protects the VM even if NSG rules are misconfigured.

```bash
local$ ssh azurelab@$VM_IP

# Build the golden image firewall
vm# sudo iptables -F
vm# sudo iptables -A INPUT -i lo -j ACCEPT
vm# sudo iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
vm# sudo iptables -A INPUT -p tcp --dport 22 -j ACCEPT
vm# sudo iptables -A INPUT -p tcp --dport 80 -j ACCEPT
vm# sudo iptables -A INPUT -j LOG --log-prefix "GOLD-DROP: " --log-level 4
vm# sudo iptables -P INPUT DROP

# Verify:
vm# sudo iptables -L INPUT -v -n --line-numbers
```

**Test — all layers aligned:**
```bash
local$ curl -s http://$VM_IP              # Works (80 allowed everywhere)
local$ ssh azurelab@$VM_IP                 # Works (22 allowed everywhere)
local$ nc -zv -w3 $VM_IP 3306             # BLOCKED
```

**Now simulate an NSG misconfiguration — open ALL ports at NIC level:**
```bash
local$ az network nsg rule create \
  --resource-group cloud-sec-lab \
  --nsg-name nsg-nic \
  --name DANGEROUS_AllowAll \
  --priority 100 \
  --direction Inbound \
  --access Allow \
  --protocol '*' \
  --destination-port-ranges '*' \
  --source-address-prefixes '*' \
  --output none

# Try to reach a dangerous port:
local$ nc -zv -w3 $VM_IP 3306
# BLOCKED — iptables golden image saved us!

# Check the log inside the VM:
vm# sudo dmesg | grep GOLD-DROP | tail -3
# Shows: GOLD-DROP: ... DPT=3306 — iptables caught it
```

**This is defense-in-depth in action:**
```
Packet to port 3306:
  nsg-subnet: AllowSSH(22), AllowHTTP(80)... no rule for 3306
              BUT Azure default rules at 65000 allow VNet traffic
              → depends on source

  nsg-nic:    DANGEROUS_AllowAll pri=100 → ALLOW ← misconfigured!

  iptables:   no rule for 3306 → LOG → DROP ← golden image saves us!
```

**Restore:**
```bash
local$ az network nsg rule delete \
  --resource-group cloud-sec-lab \
  --nsg-name nsg-nic \
  --name DANGEROUS_AllowAll
```

---

### Exercise 6: Egress control (outbound restrictions)

**Goal:** Restrict what the VM can reach on the internet.

**Layer 1 — NSG outbound rule:**
```bash
# Block ALL outbound from the subnet (except established)
local$ az network nsg rule create \
  --resource-group cloud-sec-lab \
  --nsg-name nsg-subnet \
  --name DenyInternetOutbound \
  --priority 200 \
  --direction Outbound \
  --access Deny \
  --protocol '*' \
  --destination-port-ranges '*' \
  --destination-address-prefixes 'Internet' \
  --output none

# Test inside the VM:
vm# curl -s --max-time 5 https://example.com
# TIMEOUT — VM can't reach the internet

# But internal Azure traffic still works (VNet-to-VNet is allowed by default rules)

# Restore:
local$ az network nsg rule delete \
  --resource-group cloud-sec-lab \
  --nsg-name nsg-subnet \
  --name DenyInternetOutbound
```

**Layer 3 — iptables egress control (more granular):**
```bash
vm# sudo iptables -P OUTPUT DROP
vm# sudo iptables -A OUTPUT -o lo -j ACCEPT
vm# sudo iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
vm# sudo iptables -A OUTPUT -p udp --dport 53 -j ACCEPT     # DNS
vm# sudo iptables -A OUTPUT -p tcp --dport 443 -j ACCEPT    # HTTPS only
vm# sudo iptables -A OUTPUT -j LOG --log-prefix "EGRESS-DROP: "

# Test:
vm# curl -s --max-time 5 https://example.com   # Works (443 allowed)
vm# curl -s --max-time 5 http://example.com    # BLOCKED (80 not allowed)
vm# ping -c 1 8.8.8.8                           # BLOCKED (ICMP not allowed)
vm# sudo dmesg | grep EGRESS-DROP | tail -3     # See what was blocked

# Restore:
vm# sudo iptables -P OUTPUT ACCEPT
vm# sudo iptables -F OUTPUT
vm# sudo iptables -A OUTPUT -o lo -j ACCEPT
```

---

### Exercise 7: Enable and read NSG Flow Logs

**Goal:** See traffic decisions at the NSG layer (like VPC Flow Logs).

```bash
# Create a storage account for flow logs
local$ STORAGE_NAME="cloudseclablogs$(date +%s | tail -c 6)"
local$ az storage account create \
  --resource-group cloud-sec-lab \
  --name "$STORAGE_NAME" \
  --sku Standard_LRS \
  --output none

# Enable flow logs on the NIC-level NSG
local$ az network watcher flow-log create \
  --resource-group cloud-sec-lab \
  --name nsg-nic-flowlog \
  --nsg nsg-nic \
  --storage-account "$STORAGE_NAME" \
  --enabled true \
  --output none

# Generate some traffic (both allowed and blocked):
local$ curl -s http://$VM_IP           # Allowed
local$ nc -zv -w3 $VM_IP 3306         # Blocked

# Wait ~5 minutes for logs to appear, then check:
local$ az network watcher flow-log show \
  --resource-group cloud-sec-lab \
  --name nsg-nic-flowlog \
  --output table
```

**Flow log format (similar to VPC Flow Logs):**
```
Each record shows:
  - rule name that matched
  - source/dest IP and port
  - protocol
  - action: A (Allow) or D (Deny)
  - flow state: B (Begin), C (Continuing), E (End)

Use these logs to answer:
  "Was this traffic blocked by nsg-subnet or nsg-nic?"
  "What traffic is hitting my VM that I don't expect?"
```

---

### Exercise 8: Full debugging walkthrough

**Goal:** Practice the "SG allows it but it still fails" scenario end-to-end.

**Setup the broken state:**
```bash
# Ensure both NSGs allow HTTP
local$ az network nsg rule list --resource-group cloud-sec-lab \
  --nsg-name nsg-subnet --output table | grep HTTP
local$ az network nsg rule list --resource-group cloud-sec-lab \
  --nsg-name nsg-nic --output table | grep HTTP

# But add an iptables block inside the VM
vm# sudo iptables -I INPUT 3 -p tcp --dport 80 -j REJECT --reject-with tcp-reset

# Now test:
local$ curl -s --max-time 5 http://$VM_IP
# "Connection reset by peer" or empty — it fails!
```

**Debug using the workflow from Phase 5:**
```bash
# Step 1: Can we reach the VM?
local$ ping -c 2 $VM_IP
# If ping works, the VM is reachable (routing OK)
# Note: Azure blocks ICMP by default in NSGs, so this might fail too
# Better test: SSH works → VM is reachable
local$ ssh azurelab@$VM_IP "echo reachable"

# Step 2: Are NSGs allowing port 80?
local$ az network nsg rule list --resource-group cloud-sec-lab \
  --nsg-name nsg-subnet --query "[?destinationPortRange=='80']" --output table
local$ az network nsg rule list --resource-group cloud-sec-lab \
  --nsg-name nsg-nic --query "[?destinationPortRange=='80']" --output table
# Both show AllowHTTP — NSGs are fine

# Step 3: Is iptables blocking it?
vm# sudo iptables -L INPUT -v -n --line-numbers
# Line 3 shows: REJECT tcp dpt:80 — FOUND IT!
# The pkts counter is increasing — packets reach the VM but get rejected

# Step 4: Is the service running?
vm# curl -s localhost:80
# "=== Cloud Security Lab ===" — nginx is fine, it's an iptables issue

# Fix:
vm# sudo iptables -D INPUT -p tcp --dport 80 -j REJECT --reject-with tcp-reset
local$ curl -s http://$VM_IP    # Works!
```

---

### Teardown

```bash
# Delete everything in one command (~2 minutes)
local$ az group delete --name cloud-sec-lab --yes --no-wait

# Verify deletion started:
local$ az group show --name cloud-sec-lab --query properties.provisioningState -o tsv
# Should show: Deleting

# Or wait for completion:
local$ az group wait --name cloud-sec-lab --deleted
```

> **Cost reminder:** The lab runs on Standard_B1s (~$0.01/hour).
> Always tear down when done to avoid charges.

---

## 10. Phase 8: Cloud Provider Mapping

### AWS

```
┌──────────────────────┬──────────────────────────────────────────┐
│ Concept              │ AWS Resource                              │
├──────────────────────┼──────────────────────────────────────────┤
│ NACL                 │ VPC → Network ACLs                       │
│ Security Group       │ EC2 → Security Groups                    │
│ iptables             │ Inside the EC2 instance (you manage)     │
│ Logging              │ VPC Flow Logs → CloudWatch / S3          │
│ Audit                │ CloudTrail (who changed the SG/NACL)     │
│ Managed firewall     │ AWS Network Firewall (IDS/IPS + rules)  │
│ WAF                  │ AWS WAF (HTTP-level, Layer 7)            │
│ NAT                  │ NAT Gateway (managed, no iptables)       │
│ IGW                  │ Internet Gateway (1 per VPC)             │
└──────────────────────┴──────────────────────────────────────────┘

# CLI examples:
aws ec2 describe-security-groups --group-ids sg-xxxxxxxx
aws ec2 describe-network-acls --network-acl-ids acl-xxxxxxxx
aws ec2 create-flow-logs --resource-ids vpc-xxx --traffic-type ALL \
    --log-destination-type cloud-watch-logs --log-group-name VPCFlowLogs
```

### Azure

```
┌──────────────────────┬──────────────────────────────────────────┐
│ Concept              │ Azure Resource                            │
├──────────────────────┼──────────────────────────────────────────┤
│ NACL equivalent      │ NSG on Subnet                            │
│ Security Group       │ NSG on NIC (Network Interface)           │
│ iptables             │ Inside the VM (you manage)               │
│ Logging              │ NSG Flow Logs → Storage / Log Analytics  │
│ Audit                │ Activity Log (who changed NSG)           │
│ Managed firewall     │ Azure Firewall (L3-L7, FQDN filtering)  │
│ WAF                  │ Azure WAF (via Application Gateway)      │
│ NAT                  │ NAT Gateway (managed)                    │
└──────────────────────┴──────────────────────────────────────────┘

Note: Azure uses NSGs for BOTH subnet-level and NIC-level.
  - NSG on subnet ≈ NACL (but stateful, unlike AWS NACLs!)
  - NSG on NIC ≈ Security Group
  - Both are stateful in Azure (unlike AWS where NACLs are stateless)

# CLI examples:
az network nsg show --name myNSG --resource-group myRG
az network nsg rule list --nsg-name myNSG --resource-group myRG
az network watcher flow-log create --nsg myNSG --storage-account myStorage
```

### GCP

```
┌──────────────────────┬──────────────────────────────────────────┐
│ Concept              │ GCP Resource                              │
├──────────────────────┼──────────────────────────────────────────┤
│ NACL equivalent      │ VPC Firewall Rules (network-level)       │
│ Security Group       │ VPC Firewall Rules (target tags/SA)      │
│ iptables             │ Inside the VM (you manage)               │
│ Logging              │ VPC Flow Logs → Cloud Logging            │
│ Audit                │ Cloud Audit Logs                         │
│ Managed firewall     │ Cloud Armor (DDoS + WAF)                │
│ Hierarchical         │ Firewall Policies (org/folder level)     │
│ NAT                  │ Cloud NAT (managed)                      │
└──────────────────────┴──────────────────────────────────────────┘

Note: GCP doesn't have separate NACL and SG concepts.
  VPC Firewall Rules serve both purposes:
  - Apply to network (like NACL)
  - Target specific instances via tags or service accounts (like SG)
  - All stateful
  - Priority-based (lowest number = highest priority)

# CLI examples:
gcloud compute firewall-rules list
gcloud compute firewall-rules describe allow-http
gcloud compute firewall-rules create allow-http \
    --network=default --allow=tcp:80 --target-tags=web-server
```

### Cross-provider comparison

```
┌────────────────────┬────────────┬────────────────┬────────────────┐
│                    │ AWS        │ Azure          │ GCP            │
├────────────────────┼────────────┼────────────────┼────────────────┤
│ Subnet firewall    │ NACL       │ NSG (subnet)   │ VPC FW Rules   │
│   Stateful?        │ NO         │ YES            │ YES            │
│                    │            │                │                │
│ Instance firewall  │ SG         │ NSG (NIC)      │ VPC FW Rules   │
│   Stateful?        │ YES        │ YES            │ YES            │
│                    │            │                │                │
│ Explicit deny?     │ NACL only  │ NSG (both)     │ VPC FW Rules   │
│ Rule evaluation    │ NACL: order│ NSG: priority  │ Priority-based │
│                    │ SG: union  │                │                │
│ SG-to-SG ref?     │ YES        │ YES (ASG)      │ Tags/SA-based  │
└────────────────────┴────────────┴────────────────┴────────────────┘
```

---

## 11. Quick Reference

### Debugging decision flowchart

```
Traffic not reaching your service?
  │
  ├─ Can you reach the VM at all?
  │   NO → Check: Route tables, IGW, NAT GW, NACL
  │   YES ↓
  │
  ├─ Can you reach the specific port?
  │   NO → Check: SG inbound rules, NACL inbound rules
  │   YES ↓
  │
  ├─ Does the service respond locally? (curl localhost:PORT)
  │   NO → Check: Service running? Bound to 0.0.0.0? Right port?
  │   YES ↓
  │
  ├─ Does iptables -L -v -n show DROP counters increasing?
  │   YES → iptables is blocking — check your INPUT rules
  │   NO ↓
  │
  ├─ Does the response come back?
  │   NO → Check: NACL outbound (ephemeral ports!), route tables
  │   YES ↓
  │
  └─ It works. The problem is elsewhere (DNS, TLS, app logic).
```

### Layer-by-layer commands

```bash
# ── Layer 1: Check subnet NSG (Azure — NACL equivalent) ──
az network nsg rule list --resource-group cloud-sec-lab \
  --nsg-name nsg-subnet --output table
# AWS equivalent: aws ec2 describe-network-acls

# ── Layer 2: Check NIC NSG (Azure — Security Group equivalent) ──
az network nsg rule list --resource-group cloud-sec-lab \
  --nsg-name nsg-nic --output table
# AWS equivalent: aws ec2 describe-security-groups

# ── Layer 3: Check iptables (inside VM) ──
sudo iptables -L -v -n --line-numbers
sudo iptables -L INPUT -v -n        # focus on INPUT
dmesg | grep GOLD-DROP               # if LOG rules exist

# ── Check service ──
ss -tlnp                            # listening ports
curl -s localhost:80                 # local test

# ── Check NSG Flow Logs (Azure) ──
az network watcher flow-log show --resource-group cloud-sec-lab \
  --name nsg-nic-flowlog --output table
# AWS equivalent: VPC Flow Logs in CloudWatch/S3

# ── Audit: Who changed NSG rules? ──
az monitor activity-log list --resource-group cloud-sec-lab \
  --query "[?operationName.value=='Microsoft.Network/networkSecurityGroups/write']" \
  --output table
```

### Mapping to roadmap checklist

After this lab you can:

| Checklist Item | Where You Practiced |
|----------------|---------------------|
| Understand cloud SG vs VM firewall differences | Phases 1-4 |
| Debug "SG allows it but it still fails" | Phase 5 |
| Build a layered security matrix | Phase 4 |
| Configure egress control | Phase 6 |
| Provision and test real cloud security layers (Azure) | Phase 7 |
| Debug across NSG + iptables layers on Azure | Phase 7 (Ex. 8) |
| Read NSG Flow Logs | Phase 7 (Ex. 7) |
| Map concepts across AWS / Azure / GCP | Phase 8 |

**Next up:** Phase 6 of the roadmap — Containers & Kubernetes (how Docker/K8s manipulate iptables).
See [containers-kube-lab.md](containers-kube-lab.md).
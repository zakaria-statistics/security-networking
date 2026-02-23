# iptables for DevOps & Cloud Engineers
> From packet flow fundamentals to Kubernetes networking - a hands-on guide

## Table of Contents

| Phase | Topic | Focus |
|-------|-------|-------|
| [1](#phase-1--the-mental-model) | Mental Model | How packets flow through the system |
| [2](#phase-2--basic-commands) | Basic Commands | List, add, delete rules |
| [3](#phase-3--stateful-firewall) | Stateful Firewall | Connection tracking (conntrack) |
| [4](#phase-4--nat-mastery) | NAT Mastery | SNAT, DNAT, MASQUERADE |
| [5](#phase-5--debugging-like-an-sre) | Debugging | Troubleshooting traffic issues |
| [6](#phase-6--cloud-context) | Cloud Context | Security Groups vs iptables |
| [7](#phase-7--kubernetes--containers) | Kubernetes | How K8s uses iptables |
| [Labs](#hands-on-labs) | Labs | Practical exercises |

---

## Overview

```
What is iptables?
┌─────────────────────────────────────────────────────────────┐
│  iptables = CLI tool to configure Netfilter (kernel firewall) │
│                                                               │
│  It controls:                                                 │
│    • Which packets get ACCEPTED or DROPPED                   │
│    • Network Address Translation (NAT)                       │
│    • Packet modification (mangle)                            │
└─────────────────────────────────────────────────────────────┘
```

**Why DevOps engineers need iptables:**
- Debug "why can't I reach my service?"
- Secure VMs beyond cloud security groups
- Understand Kubernetes/Docker networking
- Build NAT gateways for private subnets

---

## Phase 1 — The Mental Model

### The 3 Core Concepts

```
┌─────────────────────────────────────────────────────────────┐
│                     TABLES → CHAINS → RULES                  │
├─────────────────────────────────────────────────────────────┤
│                                                               │
│  TABLE: A category of rules (filter, nat, mangle)            │
│    └── CHAIN: A checkpoint where rules are evaluated         │
│          └── RULE: "If packet matches X, do Y"              │
│                                                               │
└─────────────────────────────────────────────────────────────┘
```

### The 3 Main Tables

| Table | Purpose | When to Use |
|-------|---------|-------------|
| **filter** | Accept/drop packets | Firewall rules (most common) |
| **nat** | Rewrite source/dest IP | Port forwarding, masquerading |
| **mangle** | Modify packet headers | QoS, TTL changes (rare) |

### The 5 Chains (Checkpoints)

```
                    INCOMING PACKET
                          │
                          ▼
                   ┌─────────────┐
                   │ PREROUTING  │  ← NAT decisions (DNAT)
                   └──────┬──────┘
                          │
                    Routing Decision
                   /              \
                  /                \
        For this host?         Forward to another host?
                │                        │
                ▼                        ▼
         ┌───────────┐            ┌───────────┐
         │   INPUT   │            │  FORWARD  │
         └─────┬─────┘            └─────┬─────┘
               │                        │
               ▼                        │
        Local Process                   │
               │                        │
               ▼                        │
         ┌───────────┐                  │
         │  OUTPUT   │                  │
         └─────┬─────┘                  │
               │                        │
               └────────────┬───────────┘
                            │
                            ▼
                   ┌─────────────┐
                   │ POSTROUTING │  ← NAT decisions (SNAT)
                   └──────┬──────┘
                          │
                          ▼
                   OUTGOING PACKET
```

### Chain Quick Reference

| Chain | Traffic Type | Example |
|-------|-------------|---------|
| **INPUT** | Packets TO this host | SSH into your server |
| **OUTPUT** | Packets FROM this host | curl to external API |
| **FORWARD** | Packets THROUGH this host | Router/gateway VM |
| **PREROUTING** | Before routing decision | DNAT port forwarding |
| **POSTROUTING** | After routing decision | SNAT/masquerade |

### Targets (Actions)

| Target | What it does |
|--------|-------------|
| **ACCEPT** | Allow the packet |
| **DROP** | Silently discard (no response) |
| **REJECT** | Discard + send error back |
| **LOG** | Write to syslog, continue processing |
| **SNAT/DNAT/MASQUERADE** | NAT operations |

---

## Phase 2 — Basic Commands

### Viewing Rules

```bash
# List all rules in filter table (default)
iptables -L -v -n

# With line numbers (needed for deletion)
iptables -L -v -n --line-numbers

# List specific table
iptables -t nat -L -v -n

# Show all tables at once
iptables-save
```

**Flags explained:**
- `-L` = List rules
- `-v` = Verbose (show counters)
- `-n` = Numeric (don't resolve DNS)
- `-t <table>` = Specify table (filter, nat, mangle)

### Adding Rules

```bash
# Allow SSH (port 22) on INPUT chain
iptables -A INPUT -p tcp --dport 22 -j ACCEPT

# Block specific IP
iptables -A INPUT -s 192.168.1.100 -j DROP

# Allow traffic on specific interface
iptables -A INPUT -i eth0 -p tcp --dport 80 -j ACCEPT
```

**Rule structure:**
```
iptables -A <CHAIN> <MATCH CONDITIONS> -j <TARGET>
         │          │                     │
         │          │                     └── Action (ACCEPT/DROP/etc)
         │          └── What to match (port, IP, protocol)
         └── Append to chain
```

### Common Match Conditions

| Flag | Meaning | Example |
|------|---------|---------|
| `-p` | Protocol | `-p tcp`, `-p udp`, `-p icmp` |
| `-s` | Source IP | `-s 10.0.0.0/8` |
| `-d` | Destination IP | `-d 192.168.1.1` |
| `--dport` | Destination port | `--dport 443` |
| `--sport` | Source port | `--sport 80` |
| `-i` | Input interface | `-i eth0` |
| `-o` | Output interface | `-o eth1` |

### Deleting Rules

```bash
# Delete by line number (get it from --line-numbers)
iptables -D INPUT 3

# Delete by exact match
iptables -D INPUT -p tcp --dport 22 -j ACCEPT

# Flush all rules in a chain
iptables -F INPUT

# Flush entire table
iptables -F
```

### Setting Default Policy

```bash
# Set default to DROP (whitelist approach - more secure)
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT ACCEPT

# CAUTION: Set allow rules BEFORE setting DROP policy!
```

---

## Phase 3 — Stateful Firewall

### Why Stateful Matters

**Stateless problem:**
```
You: Allow incoming SSH (port 22)     ✓
You: Block everything else            ✓
Result: SSH works, but RESPONSES to your outgoing
        connections get blocked!      ✗
```

**Stateful solution:**
```
Track connection states → Allow return traffic automatically
```

### Connection States

| State | Meaning |
|-------|---------|
| **NEW** | First packet of a connection |
| **ESTABLISHED** | Part of an existing connection |
| **RELATED** | Associated with existing connection (FTP data, ICMP errors) |
| **INVALID** | Doesn't match any known connection |

### The Essential Stateful Rule

```bash
# CRITICAL: Allow return traffic for established connections
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
```

This single rule allows responses to:
- Your outbound SSH sessions
- Package manager updates (apt, yum)
- DNS queries
- API calls

### Stateful Firewall Template

```bash
#!/bin/bash
# Secure stateful firewall baseline

# 1. Flush existing rules
iptables -F
iptables -X

# 2. Set default policies (whitelist approach)
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT ACCEPT

# 3. Allow loopback (localhost)
iptables -A INPUT -i lo -j ACCEPT

# 4. Allow established/related connections (THE KEY RULE)
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# 5. Allow specific inbound services
iptables -A INPUT -p tcp --dport 22 -j ACCEPT   # SSH
iptables -A INPUT -p tcp --dport 80 -j ACCEPT   # HTTP
iptables -A INPUT -p tcp --dport 443 -j ACCEPT  # HTTPS

# 6. Drop invalid packets
iptables -A INPUT -m conntrack --ctstate INVALID -j DROP

# 7. Log dropped packets (optional, for debugging)
iptables -A INPUT -j LOG --log-prefix "IPT-DROP: " --log-level 4
```

### Viewing Connection Tracking

```bash
# Install conntrack tools
apt install conntrack   # Debian/Ubuntu
yum install conntrack-tools  # RHEL/CentOS

# View active connections
conntrack -L

# Watch connections in real-time
conntrack -E
```

---

## Phase 4 — NAT Mastery

### NAT Types Explained

```
┌─────────────────────────────────────────────────────────────┐
│                        NAT Types                             │
├─────────────────────────────────────────────────────────────┤
│                                                               │
│  SNAT (Source NAT)                                           │
│  ├── Changes SOURCE IP                                       │
│  ├── Used for: Outbound traffic from private network        │
│  └── Applied at: POSTROUTING                                │
│                                                               │
│  DNAT (Destination NAT)                                      │
│  ├── Changes DESTINATION IP                                  │
│  ├── Used for: Port forwarding, load balancing              │
│  └── Applied at: PREROUTING                                 │
│                                                               │
│  MASQUERADE                                                   │
│  ├── Dynamic SNAT (auto-detects outbound IP)                │
│  └── Used when: Public IP is dynamic (home internet, DHCP)  │
│                                                               │
└─────────────────────────────────────────────────────────────┘
```

### Use Case 1: NAT Gateway (Private Subnet → Internet)

```
┌──────────────┐      ┌──────────────┐      ┌──────────────┐
│ Private VM   │ ───▶ │ NAT Gateway  │ ───▶ │  Internet    │
│ 10.0.1.50    │      │ 10.0.1.1     │      │              │
│              │      │ (public IP)  │      │              │
└──────────────┘      └──────────────┘      └──────────────┘
```

```bash
# On the NAT Gateway VM:

# 1. Enable IP forwarding
echo 1 > /proc/sys/net/ipv4/ip_forward

# Make permanent:
echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf

# 2. Set up MASQUERADE (SNAT with dynamic IP)
iptables -t nat -A POSTROUTING -s 10.0.1.0/24 -o eth0 -j MASQUERADE

# 3. Allow forwarded traffic
iptables -A FORWARD -i eth1 -o eth0 -j ACCEPT
iptables -A FORWARD -i eth0 -o eth1 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
```

**With static public IP (use SNAT instead):**
```bash
iptables -t nat -A POSTROUTING -s 10.0.1.0/24 -o eth0 -j SNAT --to-source 203.0.113.10
```

### Use Case 2: Port Forwarding (DNAT)

```
┌──────────────┐      ┌──────────────┐      ┌──────────────┐
│   Client     │ ───▶ │ Gateway:443  │ ───▶ │ Backend:8443 │
│              │      │ (public)     │      │ (private)    │
└──────────────┘      └──────────────┘      └──────────────┘
```

```bash
# Forward port 443 to internal server 10.0.1.50:8443

# 1. DNAT rule (in PREROUTING - before routing decision)
iptables -t nat -A PREROUTING -p tcp --dport 443 -j DNAT --to-destination 10.0.1.50:8443

# 2. Allow the forwarded traffic
iptables -A FORWARD -p tcp -d 10.0.1.50 --dport 8443 -j ACCEPT

# 3. Allow return traffic (if not already allowed by stateful rule)
iptables -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
```

### NAT Troubleshooting

| Problem | Check |
|---------|-------|
| Outbound works, no response | Is ip_forward enabled? |
| DNAT not working | Is the FORWARD chain allowing it? |
| Works once, then fails | conntrack table full? |
| Random timeouts | NAT/conntrack timeouts too short? |

---

## Phase 5 — Debugging Like an SRE

### The Debugging Workflow

```
1. Is it REACHING the host?        → tcpdump / packet capture
2. Is it ALLOWED by firewall?      → iptables counters / LOG
3. Is it ROUTED correctly?         → ip route / routing table
4. Is the SERVICE listening?       → ss / netstat
5. Is CONNTRACK tracking it?       → conntrack -L
```

### Using Counters

```bash
# View packet/byte counters
iptables -L -v -n

# Reset counters (then reproduce issue)
iptables -Z

# Watch specific chain
watch -n1 'iptables -L INPUT -v -n'
```

Example output:
```
Chain INPUT (policy DROP 0 packets, 0 bytes)
 pkts bytes target     prot opt in     out     source       destination
  150 12000 ACCEPT     all  --  lo     *       0.0.0.0/0    0.0.0.0/0
 2450  180K ACCEPT     all  --  *      *       0.0.0.0/0    0.0.0.0/0    ctstate ESTABLISHED
    5   300 ACCEPT     tcp  --  *      *       0.0.0.0/0    0.0.0.0/0    tcp dpt:22
   12   720 DROP       all  --  *      *       192.168.1.100  0.0.0.0/0
```

### Using LOG Target

```bash
# Add LOG rule BEFORE the DROP (order matters!)
iptables -I INPUT 1 -j LOG --log-prefix "IPT-INPUT: " --log-level 4

# View logs
tail -f /var/log/kern.log | grep IPT-INPUT
# or
journalctl -f | grep IPT

# Remove when done debugging
iptables -D INPUT 1
```

### Packet Capture with tcpdump

```bash
# See if packets arrive
tcpdump -i eth0 port 22 -n

# Save for later analysis
tcpdump -i eth0 -w capture.pcap

# See packets on any interface
tcpdump -i any port 443 -n
```

### Verify Service is Listening

```bash
# What's listening on which ports?
ss -tlnp

# Check specific port
ss -tlnp | grep :22
```

### Common Issues Checklist

| Symptom | Likely Cause | Check |
|---------|--------------|-------|
| Can't SSH after rule change | Locked yourself out | Console access, check rules |
| Works locally, not remotely | Firewall blocking | `iptables -L -v -n` |
| Intermittent drops | conntrack table full | `conntrack -C`, `dmesg` |
| Works then stops | Session timeout | conntrack timeouts |
| NAT not working | ip_forward disabled | `cat /proc/sys/net/ipv4/ip_forward` |

---

## Phase 6 — Cloud Context

### Security Groups vs iptables vs NACLs

```
┌─────────────────────────────────────────────────────────────┐
│                    Cloud Traffic Flow                        │
├─────────────────────────────────────────────────────────────┤
│                                                               │
│  Internet                                                    │
│      │                                                       │
│      ▼                                                       │
│  ┌─────────┐                                                │
│  │  NACL   │  ← Subnet level, STATELESS                     │
│  └────┬────┘    (AWS only)                                  │
│       │                                                      │
│       ▼                                                      │
│  ┌─────────┐                                                │
│  │   SG    │  ← Instance level, STATEFUL                    │
│  └────┬────┘    (hypervisor enforced)                       │
│       │                                                      │
│       ▼                                                      │
│  ┌─────────┐                                                │
│  │iptables │  ← Inside VM, STATEFUL                         │
│  └─────────┘    (OS level)                                  │
│                                                               │
└─────────────────────────────────────────────────────────────┘
```

### Comparison

| Feature | Security Group | NACL | iptables |
|---------|---------------|------|----------|
| Level | Instance | Subnet | OS |
| Stateful | Yes | No | Yes |
| Allow rules only | Yes | No | No |
| Rule limit | ~60/SG | 20/NACL | Unlimited |
| Default | Deny all in | Allow all | Depends |

### When to Use What

| Scenario | Use |
|----------|-----|
| Basic access control | Security Groups |
| Subnet isolation | NACLs (AWS) |
| Complex rules, NAT | iptables |
| Egress filtering | iptables (more granular) |
| Container networking | iptables (automatic) |

### Common Cloud Gotcha

```
"Security Group allows port 80, but I still can't connect!"

Check inside the VM:
1. Is the service running?     → systemctl status nginx
2. Is iptables blocking it?    → iptables -L INPUT -v -n
3. Is it binding to localhost? → ss -tlnp
```

---

## Phase 7 — Kubernetes & Containers

### How Docker Uses iptables

```bash
# Docker creates these automatically:
iptables -t nat -L DOCKER -n
iptables -L DOCKER-USER -n

# Key chains:
# DOCKER      - Container port mappings
# DOCKER-USER - Your custom rules (survives restarts)
```

### How Kubernetes Uses iptables

```
┌─────────────────────────────────────────────────────────────┐
│                   Kubernetes Service Flow                    │
├─────────────────────────────────────────────────────────────┤
│                                                               │
│  Client → ClusterIP (10.96.0.100:80)                        │
│              │                                               │
│              ▼                                               │
│         kube-proxy                                           │
│         (iptables mode)                                      │
│              │                                               │
│              ▼                                               │
│         DNAT to Pod IP                                       │
│         (10.244.1.5:8080)                                   │
│                                                               │
└─────────────────────────────────────────────────────────────┘
```

### Inspecting K8s iptables Rules

```bash
# View kube-proxy created rules
iptables -t nat -L KUBE-SERVICES -n

# Find rules for a specific service
iptables-save | grep <service-name>

# NodePort rules
iptables -t nat -L KUBE-NODEPORTS -n
```

### K8s Chain Structure

```
PREROUTING
    └── KUBE-SERVICES
            ├── KUBE-SVC-XXXX (ClusterIP)
            │       └── KUBE-SEP-XXXX (Pod endpoints)
            └── KUBE-NODEPORTS
                    └── KUBE-SVC-XXXX
```

### Don't Break Your Cluster

```bash
# NEVER flush iptables on a K8s node:
iptables -F  # This breaks cluster networking!

# Instead, to add custom rules use:
# - NetworkPolicies (Kubernetes native)
# - DOCKER-USER chain (for Docker)
# - Custom chains that don't conflict
```

### CNI and iptables

| CNI | iptables Usage |
|-----|---------------|
| Calico | Heavy (network policies via iptables) |
| Flannel | Minimal (basic routing) |
| Cilium | eBPF (bypasses iptables for performance) |

---

## Hands-On Labs

### Lab 1: Basic Stateful Firewall

**Goal:** Secure a VM allowing only SSH and HTTP

```bash
# Save this as firewall-basic.sh and run with sudo

#!/bin/bash
set -e

# Flush existing
iptables -F
iptables -X

# Default policies
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT ACCEPT

# Loopback
iptables -A INPUT -i lo -j ACCEPT

# Established connections
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# SSH and HTTP
iptables -A INPUT -p tcp --dport 22 -j ACCEPT
iptables -A INPUT -p tcp --dport 80 -j ACCEPT

# Show result
iptables -L -v -n
```

**Test:**
```bash
# From another machine:
ssh user@server          # Should work
curl http://server       # Should work
nc -zv server 443        # Should timeout (blocked)
```

---

### Lab 2: NAT Gateway

**Goal:** Allow private subnet to reach internet

**Setup:**
```
Private VM (10.0.1.50) → NAT Gateway (10.0.1.1 / public) → Internet
```

```bash
# On NAT Gateway:

#!/bin/bash
# nat-gateway.sh

# Enable forwarding
sysctl -w net.ipv4.ip_forward=1

# MASQUERADE outbound traffic from private subnet
iptables -t nat -A POSTROUTING -s 10.0.1.0/24 -o eth0 -j MASQUERADE

# Allow forwarding
iptables -A FORWARD -i eth1 -o eth0 -j ACCEPT
iptables -A FORWARD -i eth0 -o eth1 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
```

**Test from private VM:**
```bash
# Set gateway route
ip route add default via 10.0.1.1

# Test
ping 8.8.8.8
curl ifconfig.me  # Should show NAT gateway's public IP
```

---

### Lab 3: Port Forwarding

**Goal:** Forward public:443 → private:8443

```bash
#!/bin/bash
# port-forward.sh

# Enable forwarding
sysctl -w net.ipv4.ip_forward=1

# DNAT incoming 443 to internal server
iptables -t nat -A PREROUTING -p tcp --dport 443 -j DNAT --to-destination 10.0.1.50:8443

# Allow the forwarded traffic
iptables -A FORWARD -p tcp -d 10.0.1.50 --dport 8443 -j ACCEPT
iptables -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
```

---

### Lab 4: Debug Dropped Traffic

**Goal:** Find why traffic is being blocked

```bash
# 1. Add LOG rule at the beginning
iptables -I INPUT 1 -j LOG --log-prefix "DEBUG-INPUT: "

# 2. Reproduce the issue
curl http://server:8080  # from client

# 3. Check logs
journalctl -f | grep DEBUG-INPUT

# 4. Look for the drop
# You'll see: DEBUG-INPUT: IN=eth0 ... DPT=8080 ...
# This tells you port 8080 hit the rules but no ACCEPT matched

# 5. Remove debug rule when done
iptables -D INPUT 1
```

---

### Lab 5: Kubernetes iptables Inspection

**Goal:** Understand how Services work

```bash
# 1. Create a simple service
kubectl create deployment nginx --image=nginx
kubectl expose deployment nginx --port=80

# 2. Get the ClusterIP
kubectl get svc nginx
# Example: 10.96.123.45

# 3. Find the iptables rules (on a node)
iptables-save | grep 10.96.123.45

# You'll see DNAT rules pointing to pod IPs

# 4. Trace the chain
iptables -t nat -L KUBE-SERVICES -n | grep nginx
```

---

## Quick Reference Card

### Essential Commands

```bash
# View rules
iptables -L -v -n --line-numbers
iptables -t nat -L -v -n
iptables-save

# Add rule
iptables -A INPUT -p tcp --dport 22 -j ACCEPT

# Delete rule
iptables -D INPUT 3

# Flush all
iptables -F

# Save/restore
iptables-save > /etc/iptables.rules
iptables-restore < /etc/iptables.rules
```

### Must-Know Rule Patterns

```bash
# Allow established (put this early!)
-A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# Allow specific port
-A INPUT -p tcp --dport 22 -j ACCEPT

# Allow from specific subnet
-A INPUT -s 10.0.0.0/8 -j ACCEPT

# NAT gateway (masquerade)
-t nat -A POSTROUTING -s 10.0.1.0/24 -o eth0 -j MASQUERADE

# Port forward
-t nat -A PREROUTING -p tcp --dport 443 -j DNAT --to-destination 10.0.1.50:8443
```

### Persist Rules (Debian/Ubuntu)

```bash
# Install persistence package
apt install iptables-persistent

# Save current rules
netfilter-persistent save

# Rules saved to:
# /etc/iptables/rules.v4
# /etc/iptables/rules.v6
```

### Persist Rules (RHEL/CentOS)

```bash
# Save
service iptables save

# Or manually
iptables-save > /etc/sysconfig/iptables
```

---

## What's Next?

After mastering iptables:

1. **nftables** - Modern replacement (same concepts, cleaner syntax)
2. **firewalld** - Zone-based management (RHEL/CentOS)
3. **ufw** - Simplified frontend (Ubuntu)
4. **Calico/Cilium** - Kubernetes network policies
5. **eBPF** - Next-gen packet processing (bypasses iptables)

---

## Resources

- [Netfilter documentation](https://www.netfilter.org/documentation/)
- `man iptables` - Comprehensive local documentation
- `iptables -m <match> --help` - Help for specific match modules

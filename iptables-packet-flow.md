# iptables & Netfilter: Deep Dive into Packet Flow
> Understanding how packets traverse the Linux kernel networking stack

## Table of Contents
1. [Core Concepts: The Building Blocks](#1-core-concepts-the-building-blocks) - Hooks, Tables, Chains, Rules, Targets
2. [Execution Order & Packet Flow](#2-execution-order--packet-flow) - Timeline and paths
3. [Packet Flow Diagrams](#3-packet-flow-diagrams) - Visual paths
4. [Connection Tracking (conntrack)](#4-connection-tracking-conntrack) - Stateful inspection
5. [DevOps Use Cases](#5-devops-use-cases) - Real-world scenarios with debug commands
6. [Debugging & Troubleshooting](#6-debugging--troubleshooting) - Trace packets
7. [Ops Hygiene & Safety](#7-ops-hygiene--safety) - Don't lock yourself out
8. [Practice Exercises](#8-practice-exercises) - Hands-on labs

---

## 1. Core Concepts: The Building Blocks

### 1.0 Component Hierarchy

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        NETFILTER/IPTABLES HIERARCHY                         │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   HOOK (kernel level)                                                       │
│     │  Fixed checkpoint in network stack where packets can be intercepted   │
│     │  5 hooks: PREROUTING, INPUT, FORWARD, OUTPUT, POSTROUTING             │
│     │                                                                       │
│     └──▶ TABLE (organizational layer)                                       │
│           │  Groups chains by purpose (filtering, NAT, mangling)            │
│           │  4 tables: raw, mangle, nat, filter                             │
│           │                                                                 │
│           └──▶ CHAIN (rule container)                                       │
│                 │  Ordered list of rules, checked sequentially              │
│                 │  Built-in chains named after hooks + custom chains        │
│                 │                                                           │
│                 └──▶ RULE (matching + action)                               │
│                       │  Match criteria (src IP, port, protocol, etc.)      │
│                       │                                                     │
│                       └──▶ TARGET/ACTION (what to do)                       │
│                             ACCEPT, DROP, REJECT, DNAT, SNAT, LOG, etc.     │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

### 1.1 Hooks (Kernel Checkpoints)

**What:** Fixed interception points hardcoded in the Linux kernel's network stack.

**Think of it as:** Security checkpoints at an airport - you MUST pass through them at specific locations.

```
┌─────────────────────────────────────────────────────────────────┐
│                     NETFILTER HOOKS                             │
│                                                                 │
│   ┌────────────┐    ┌───────┐    ┌─────────┐    ┌───────────┐  │
│   │ PREROUTING │───▶│ INPUT │    │ FORWARD │───▶│POSTROUTING│  │
│   └────────────┘    └───────┘    └─────────┘    └───────────┘  │
│         │               ▲            ▲               ▲         │
│         │               │            │               │         │
│         └───────────────┴────────────┴───────────────┘         │
│                              │                                  │
│                         ┌────────┐                              │
│                         │ OUTPUT │                              │
│                         └────────┘                              │
└─────────────────────────────────────────────────────────────────┘
```

| Hook | When It Fires | Typical Use |
|------|---------------|-------------|
| **PREROUTING** | Immediately after packet arrives on NIC, before routing decision | DNAT, port forwarding |
| **INPUT** | After routing, if destination is this host | Firewall for local services |
| **FORWARD** | After routing, if packet is being routed through | Router/gateway filtering |
| **OUTPUT** | When local process generates a packet | Egress control |
| **POSTROUTING** | Just before packet leaves the NIC | SNAT, masquerade |

**Key property:** You cannot create, delete, or rename hooks - they are part of the kernel.

---

### 1.2 Tables (Functional Grouping)

**What:** Organizational containers that group chains by purpose.

**Think of it as:** Departments at the security checkpoint (customs, immigration, baggage).

| Table | Purpose | When to Use |
|-------|---------|-------------|
| **raw** | Bypass connection tracking | Rarely; high-performance scenarios |
| **mangle** | Modify packet headers (TTL, TOS, marks) | QoS, policy routing |
| **nat** | Network Address Translation | SNAT, DNAT, MASQUERADE, port forwarding |
| **filter** | Accept/Drop/Reject packets | Main firewall rules (most common) |

**Processing order:** When multiple tables have chains at the same hook, they run in this order:
```
raw → mangle → nat → filter
```

---

### 1.3 Chains (Rule Containers)

**What:** Ordered lists of rules. Each chain is attached to a specific table AND hook.

**Think of it as:** The actual checklist that security officers follow.

**Two types of chains:**

```
┌─────────────────────────────────────────────────────────────────┐
│                         CHAIN TYPES                             │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  BUILT-IN CHAINS                    CUSTOM CHAINS               │
│  ─────────────────                  ─────────────               │
│  • Named after hooks                • User-defined              │
│  • Created automatically            • Created with: iptables -N │
│  • Cannot be deleted                • Can be deleted            │
│  • Have a default POLICY            • No policy (must RETURN)   │
│    (ACCEPT or DROP)                                             │
│                                                                 │
│  Examples:                          Examples:                   │
│  • INPUT (filter table)             • MY_SSH_RULES              │
│  • PREROUTING (nat table)           • DOCKER-USER               │
│  • OUTPUT (raw table)               • ts-input (Tailscale)      │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

**Chain flow:**
```
Packet → Built-in chain → [rule 1] → [rule 2] → ... → [jump to custom chain] → [back] → policy
                              ↓           ↓                    ↓
                           no match    no match             RETURN
```

---

### 1.4 Rules (Match + Target)

**What:** Individual instructions within a chain. Each rule has two parts:
1. **Match criteria** - conditions the packet must satisfy
2. **Target/Action** - what to do if matched

**Think of it as:** "IF packet matches X, THEN do Y"

```
┌─────────────────────────────────────────────────────────────────┐
│                          RULE ANATOMY                           │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  iptables -A INPUT -p tcp --dport 22 -s 10.0.0.0/8 -j ACCEPT   │
│            ─────── ────── ────────── ───────────── ──────────  │
│               │      │        │           │            │        │
│               │      │        │           │            └─ TARGET│
│               │      │        │           └─ MATCH: source IP   │
│               │      │        └─ MATCH: destination port        │
│               │      └─ MATCH: protocol                         │
│               └─ CHAIN to append rule to                        │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

**Rule evaluation:**
```
Packet enters chain
      │
      ▼
┌─────────────┐    match?     ┌─────────────┐
│   Rule 1    │──────YES─────▶│   Execute   │──▶ (packet leaves chain if terminal target)
└─────────────┘               │   Target    │
      │ NO                    └─────────────┘
      ▼
┌─────────────┐    match?     ┌─────────────┐
│   Rule 2    │──────YES─────▶│   Execute   │──▶ ...
└─────────────┘               │   Target    │
      │ NO                    └─────────────┘
      ▼
     ...
      │
      ▼
┌─────────────┐
│   Policy    │  (default action if no rule matched)
│ACCEPT/DROP  │
└─────────────┘
```

---

### 1.5 Targets/Actions (What To Do)

**What:** The action to take when a rule matches.

**Two categories:**

| Type | Behavior | Examples |
|------|----------|----------|
| **Terminating** | Packet stops traversing the chain | ACCEPT, DROP, REJECT, DNAT, SNAT |
| **Non-terminating** | Packet continues to next rule | LOG, MARK, RETURN |

**Common targets:**

```
┌─────────────────────────────────────────────────────────────────┐
│                       COMMON TARGETS                            │
├──────────────┬──────────────────────────────────────────────────┤
│   Target     │   Effect                                         │
├──────────────┼──────────────────────────────────────────────────┤
│   ACCEPT     │ Allow packet through (stop processing chain)     │
│   DROP       │ Silently discard packet                          │
│   REJECT     │ Discard + send ICMP error back to sender         │
│   LOG        │ Log to syslog, continue processing               │
│   RETURN     │ Exit current chain, return to calling chain      │
│   DNAT       │ Rewrite destination IP/port (nat table only)     │
│   SNAT       │ Rewrite source IP (nat table only)               │
│   MASQUERADE │ SNAT with dynamic source IP (nat table only)     │
│   REDIRECT   │ Redirect to local port (nat table only)          │
│   MARK       │ Set packet mark for policy routing               │
│   <chain>    │ Jump to custom chain                             │
└──────────────┴──────────────────────────────────────────────────┘
```

---

## 2. Execution Order & Packet Flow

### 2.1 Table-to-Chain Mapping

Not all tables exist at all hooks. Here's what's available:


```
              PREROUTING    INPUT    FORWARD    OUTPUT    POSTROUTING
            ┌────────────┬─────────┬──────────┬─────────┬─────────────┐
   raw      │     ✓      │         │          │    ✓    │             │
   mangle   │     ✓      │    ✓    │    ✓     │    ✓    │      ✓      │
   nat      │     ✓      │    ✓*   │          │    ✓    │      ✓      │
   filter   │            │    ✓    │    ✓     │    ✓    │             │
            └────────────┴─────────┴──────────┴─────────┴─────────────┘
                                                    * nat INPUT added in newer kernels
```

---

### 2.2 Complete Execution Timeline

When a packet arrives, here's the EXACT order of processing:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    PACKET PROCESSING TIMELINE                               │
└─────────────────────────────────────────────────────────────────────────────┘

INCOMING PACKET HITS NIC
         │
         ▼
═══════════════════════════════════════════════════════════════════════════════
 HOOK: PREROUTING
═══════════════════════════════════════════════════════════════════════════════
         │
         ├──▶ [1] raw    table → PREROUTING chain  (conntrack bypass)
         ├──▶ [2] mangle table → PREROUTING chain  (packet modification)
         ├──▶ [3] nat    table → PREROUTING chain  (DNAT happens here!)
         │
         ▼
┌─────────────────────────┐
│    ROUTING DECISION     │  Kernel decides: Is destination IP local or remote?
└────────────┬────────────┘
             │
     ┌───────┴───────┐
     │               │
  LOCAL?          FORWARD?
     │               │
     ▼               ▼
═══════════════  ═══════════════════════════════════════════════════════════════
 HOOK: INPUT      HOOK: FORWARD
═══════════════  ═══════════════════════════════════════════════════════════════
     │               │
     ├──▶ [4a]       ├──▶ [4b] mangle table → FORWARD chain
     │   mangle      ├──▶ [5b] filter table → FORWARD chain  ←─ FIREWALL
     ├──▶ [5a]       │
     │   filter      │
     │   ← FIREWALL  │
     ├──▶ [6a]       │
     │   nat*        │
     │               │
     ▼               │
┌──────────────┐     │
│Local Process │     │
│(nginx, sshd) │     │
└──────┬───────┘     │
       │             │
  (generates         │
   response)         │
       │             │
       ▼             │
═══════════════      │
 HOOK: OUTPUT        │
═══════════════      │
       │             │
       ├──▶ [7] raw    table → OUTPUT chain                    │
       ├──▶ [8] mangle table → OUTPUT chain                    │
       ├──▶ [9] nat    table → OUTPUT chain  (DNAT for local)  │
       ├──▶ [10] filter table → OUTPUT chain  ←─ EGRESS CTRL   │
       │             │
       ▼             │
┌──────────────┐     │
│   ROUTING    │     │
│   DECISION   │     │
└──────┬───────┘     │
       │             │
       └──────┬──────┘
              │
              ▼
═══════════════════════════════════════════════════════════════════════════════
 HOOK: POSTROUTING
═══════════════════════════════════════════════════════════════════════════════
              │
              ├──▶ [11] mangle table → POSTROUTING chain
              ├──▶ [12] nat    table → POSTROUTING chain  (SNAT/MASQUERADE here!)
              │
              ▼
         NIC (packet exits)
```

---

### 2.3 Processing Order Summary

**Per-hook table order:**

| Hook | Tables (in order) |
|------|-------------------|
| PREROUTING | raw → mangle → nat |
| INPUT | mangle → filter → nat* |
| FORWARD | mangle → filter |
| OUTPUT | raw → mangle → nat → filter |
| POSTROUTING | mangle → nat |

**Within each table's chain:**
```
Rule 1 → Rule 2 → Rule 3 → ... → Default Policy
   ↓         ↓         ↓
 match?   match?   match?
```

---

### 2.4 The Three Packet Paths

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         PACKET PATH SUMMARY                                 │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  PATH 1: INCOMING TO LOCAL SERVICE (e.g., SSH to this server)              │
│  ─────────────────────────────────────────────────────────────              │
│  NIC → PREROUTING → [routing: local] → INPUT → Local Process               │
│                                                                             │
│  PATH 2: FORWARDED/ROUTED (e.g., router/NAT gateway)                        │
│  ───────────────────────────────────────────────────                        │
│  NIC → PREROUTING → [routing: not local] → FORWARD → POSTROUTING → NIC     │
│                                                                             │
│  PATH 3: LOCALLY GENERATED (e.g., curl from this server)                    │
│  ──────────────────────────────────────────────────────                     │
│  Local Process → OUTPUT → [routing] → POSTROUTING → NIC                     │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

### 2.5 Why This Order Matters (Practical Examples)

**Example 1: DNAT must happen in PREROUTING**
```
Wrong:  Try to DNAT in INPUT   → Routing already decided, packet goes to local
Right:  DNAT in PREROUTING     → Routing sees NEW destination, forwards correctly
```

**Example 2: SNAT must happen in POSTROUTING**
```
Wrong:  Try to SNAT in OUTPUT  → Routing hasn't finished, may break
Right:  SNAT in POSTROUTING    → After routing, just before leaving NIC
```

**Example 3: Firewall rules go in filter table**
```
Wrong:  DROP in raw table      → Before conntrack, can't use -m conntrack
Right:  DROP in filter table   → After conntrack, can match ESTABLISHED
```

---

## 3. Packet Flow Diagrams

### 3.1 Inbound Packet (Destination: This Host)

**Scenario:** SSH connection to your server

```
    Internet/LAN
         │
         ▼
    ┌─────────┐
    │   NIC   │  eth0 receives frame
    └────┬────┘
         │
         ▼
    ┌─────────────────────────────────────────┐
    │            PREROUTING HOOK              │
    │  ┌─────┐  ┌────────┐  ┌─────┐          │
    │  │ raw │→ │ mangle │→ │ nat │          │
    │  └─────┘  └────────┘  └──┬──┘          │
    │                          │ DNAT?       │
    └──────────────────────────┼─────────────┘
                               │
                               ▼
                    ┌─────────────────────┐
                    │   ROUTING DECISION  │
                    │   Is dst IP local?  │
                    └──────────┬──────────┘
                               │
                          YES (local)
                               │
                               ▼
    ┌─────────────────────────────────────────┐
    │              INPUT HOOK                 │
    │  ┌────────┐  ┌────────┐                │
    │  │ mangle │→ │ filter │ ← FIREWALL     │
    │  └────────┘  └───┬────┘   RULES HERE   │
    │                  │                      │
    │           ACCEPT/DROP/REJECT            │
    └──────────────────┼─────────────────────┘
                       │
                       ▼ (if ACCEPT)
              ┌─────────────────┐
              │  Local Process  │
              │  (sshd, nginx)  │
              └─────────────────┘
```

**Counter check:** Rules in `filter INPUT` will show packet counts
```bash
sudo iptables -L INPUT -v -n
```

---

### 3.2 Outbound Packet (Generated Locally)

**Scenario:** curl from your server, apt update

```
              ┌─────────────────┐
              │  Local Process  │
              │  (curl, apt)    │
              └────────┬────────┘
                       │
                       ▼
    ┌─────────────────────────────────────────┐
    │              OUTPUT HOOK                │
    │  ┌─────┐ ┌────────┐ ┌─────┐ ┌────────┐ │
    │  │ raw │→│ mangle │→│ nat │→│ filter │ │
    │  └─────┘ └────────┘ └─────┘ └───┬────┘ │
    │                                 │      │
    │                          ACCEPT/DROP   │
    └─────────────────────────────────┼──────┘
                                      │
                                      ▼
                    ┌─────────────────────┐
                    │   ROUTING DECISION  │
                    │   Which interface?  │
                    └──────────┬──────────┘
                               │
                               ▼
    ┌─────────────────────────────────────────┐
    │           POSTROUTING HOOK              │
    │  ┌────────┐  ┌─────┐                   │
    │  │ mangle │→ │ nat │ ← SNAT/MASQUERADE │
    │  └────────┘  └──┬──┘                   │
    └─────────────────┼──────────────────────┘
                      │
                      ▼
                 ┌─────────┐
                 │   NIC   │  Packet sent
                 └─────────┘
```

---

### 3.3 Forwarded Packet (Routed Through)

**Scenario:** Host acting as router/NAT gateway

```
    Source Host                                          Destination
    (192.168.1.10)                                       (8.8.8.8)
         │                                                    ▲
         ▼                                                    │
    ┌─────────┐                                          ┌─────────┐
    │   NIC   │  eth1 (internal)                         │   NIC   │  eth0 (external)
    └────┬────┘                                          └────┬────┘
         │                                                    │
         ▼                                                    │
    ┌─────────────────────────────────────────┐               │
    │            PREROUTING HOOK              │               │
    │  ┌─────┐  ┌────────┐  ┌─────┐          │               │
    │  │ raw │→ │ mangle │→ │ nat │ DNAT?    │               │
    │  └─────┘  └────────┘  └─────┘          │               │
    └──────────────────────────┬─────────────┘               │
                               │                              │
                               ▼                              │
                    ┌─────────────────────┐                   │
                    │   ROUTING DECISION  │                   │
                    │   Dst not local     │                   │
                    │   → Forward path    │                   │
                    └──────────┬──────────┘                   │
                               │                              │
                          NO (forward)                        │
                               │                              │
                               ▼                              │
    ┌─────────────────────────────────────────┐               │
    │             FORWARD HOOK                │               │
    │  ┌────────┐  ┌────────┐                │               │
    │  │ mangle │→ │ filter │ ← Router       │               │
    │  └────────┘  └───┬────┘   firewall     │               │
    │                  │                      │               │
    │           ACCEPT/DROP                   │               │
    └──────────────────┼─────────────────────┘               │
                       │                                      │
                       ▼                                      │
    ┌─────────────────────────────────────────┐               │
    │           POSTROUTING HOOK              │               │
    │  ┌────────┐  ┌─────┐                   │               │
    │  │ mangle │→ │ nat │ ← MASQUERADE      │               │
    │  └────────┘  └──┬──┘   (192.168.1.10   │               │
    │                 │       → public IP)   │               │
    └─────────────────┼──────────────────────┘               │
                      │                                       │
                      └───────────────────────────────────────┘
```

**Requirements for forwarding:**
```bash
# Enable IP forwarding
echo 1 > /proc/sys/net/ipv4/ip_forward
# Or permanently in /etc/sysctl.conf:
# net.ipv4.ip_forward = 1
```

---

### 3.4 Complete Flow Diagram (All Paths)

```
                              INCOMING PACKET
                                    │
                                    ▼
                            ┌───────────────┐
                            │      NIC      │
                            └───────┬───────┘
                                    │
                    ┌───────────────▼───────────────┐
                    │         PREROUTING            │
                    │   raw → mangle → nat (DNAT)   │
                    └───────────────┬───────────────┘
                                    │
                            ┌───────▼───────┐
                            │    ROUTING    │
                            │   DECISION    │
                            └───────┬───────┘
                                    │
              ┌─────────────────────┴─────────────────────┐
              │                                           │
       Destination                                 Destination
       is LOCAL                                   is REMOTE
              │                                           │
              ▼                                           ▼
    ┌─────────────────┐                         ┌─────────────────┐
    │      INPUT      │                         │     FORWARD     │
    │ mangle → filter │                         │ mangle → filter │
    └────────┬────────┘                         └────────┬────────┘
             │                                           │
             ▼                                           │
    ┌─────────────────┐                                  │
    │  Local Process  │                                  │
    └────────┬────────┘                                  │
             │                                           │
     (generates reply)                                   │
             │                                           │
             ▼                                           │
    ┌─────────────────┐                                  │
    │     OUTPUT      │                                  │
    │raw→mangle→nat→  │                                  │
    │     filter      │                                  │
    └────────┬────────┘                                  │
             │                                           │
             ▼                                           │
    ┌────────────────┐                                   │
    │    ROUTING     │                                   │
    └────────┬───────┘                                   │
             │                                           │
             └─────────────────────┬─────────────────────┘
                                   │
                    ┌──────────────▼──────────────┐
                    │        POSTROUTING          │
                    │   mangle → nat (SNAT/MASQ)  │
                    └──────────────┬──────────────┘
                                   │
                                   ▼
                            ┌───────────────┐
                            │      NIC      │
                            └───────────────┘
                                   │
                                   ▼
                            OUTGOING PACKET
```

---

## 4. Connection Tracking (conntrack)

### What is conntrack?

conntrack is a kernel subsystem that **tracks the state of network connections**. It allows iptables to make decisions based on connection state, not just individual packets.

### When Does conntrack Run?

**Very early** - before filter rules. By the time packets reach `filter INPUT/FORWARD/OUTPUT`, they already have a known state.

```
Packet arrives
      │
      ▼
┌─────────────────┐
│    conntrack    │  ← Classifies packet state
│    subsystem    │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│  iptables rules │  ← Can match on state
│   -m conntrack  │
│  --ctstate XXX  │
└─────────────────┘
```

### Connection States

| State | Meaning |
|-------|---------|
| **NEW** | First packet of a connection (SYN) |
| **ESTABLISHED** | Part of an already established connection |
| **RELATED** | Related to an existing connection (e.g., FTP data, ICMP error) |
| **INVALID** | Packet doesn't match any known connection |
| **UNTRACKED** | Packet explicitly not tracked (raw table NOTRACK) |

### The Golden Rule

This single rule handles 99% of legitimate return traffic:

```bash
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
```

**Why this works:**
1. You initiate connection (curl, ssh out) → NEW packet goes out
2. Server responds → conntrack marks response as ESTABLISHED
3. This rule accepts all responses without needing per-service rules

### View Connection Tracking Table

```bash
# Install conntrack tools
sudo apt install conntrack

# View all tracked connections
sudo conntrack -L

# Watch connections in real-time
sudo conntrack -E

# Count connections by state
sudo conntrack -L | awk '{print $4}' | sort | uniq -c

# View specific protocol
sudo conntrack -L -p tcp
sudo conntrack -L -p udp
```

### conntrack Flow Example

```
Client (192.168.1.10) → Server (192.168.1.1:22) SSH

Step 1: Client sends SYN
        conntrack: NEW connection
        192.168.1.10:54321 → 192.168.1.1:22

Step 2: Server sends SYN-ACK
        conntrack: ESTABLISHED
        (matches existing entry, reply direction)

Step 3: Client sends ACK
        conntrack: ESTABLISHED
        (connection now fully established)

Step 4: Data exchange
        All packets: ESTABLISHED

Step 5: FIN/ACK sequence
        conntrack: Eventually removes entry (timeout)
```

---

## 5. DevOps Use Cases

### 5.1 Basic Server Firewall

**Scenario:** Protect a web server (nginx + SSH)

```bash
#!/bin/bash
# Basic server firewall

# Flush existing rules
iptables -F
iptables -X

# Default policies
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT ACCEPT

# Allow loopback
iptables -A INPUT -i lo -j ACCEPT

# Allow established connections (THE GOLDEN RULE)
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# Allow SSH (port 22)
iptables -A INPUT -p tcp --dport 22 -j ACCEPT

# Allow HTTP/HTTPS
iptables -A INPUT -p tcp --dport 80 -j ACCEPT
iptables -A INPUT -p tcp --dport 443 -j ACCEPT

# Allow ping (optional)
iptables -A INPUT -p icmp --icmp-type echo-request -j ACCEPT

# Log dropped packets (optional)
iptables -A INPUT -j LOG --log-prefix "IPT-DROP: " --log-level 4

# Save rules
iptables-save > /etc/iptables/rules.v4
```

**Packet path for incoming web request:**
```
Browser → NIC → PREROUTING → Routing (local) → INPUT (filter) → nginx
```

**Debug commands for server firewall:**
```bash
# Check what's listening
ss -tulpen

# View INPUT rules with counters
iptables -L INPUT -n -v --line-numbers

# Watch traffic hitting rules
watch -n1 'iptables -L INPUT -v -n | head -15'

# Test connectivity
tcpdump -ni eth0 port 22
tcpdump -ni eth0 port 80
```

---

### 5.2 NAT Gateway / Router

**Scenario:** Ubuntu box routing traffic for internal network

```bash
#!/bin/bash
# NAT Gateway configuration

# Enable IP forwarding
echo 1 > /proc/sys/net/ipv4/ip_forward

# Flush rules
iptables -F
iptables -t nat -F

# Default policies
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT ACCEPT

# Allow loopback
iptables -A INPUT -i lo -j ACCEPT

# Allow established
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# Allow SSH to gateway itself
iptables -A INPUT -p tcp --dport 22 -j ACCEPT

# Allow forwarding from internal network
# eth1 = internal (192.168.1.0/24)
# eth0 = external (internet)
iptables -A FORWARD -i eth1 -o eth0 -j ACCEPT

# MASQUERADE - rewrite source IP to gateway's public IP
iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
```

**Packet path for internal host accessing internet:**
```
Internal PC (192.168.1.10)
      │
      ▼
Gateway eth1 (192.168.1.1)
      │
      ▼
PREROUTING (no DNAT needed)
      │
      ▼
Routing Decision → not local → FORWARD chain
      │
      ▼
FORWARD (filter) → ACCEPT
      │
      ▼
POSTROUTING (nat) → MASQUERADE
      │ (src IP changed: 192.168.1.10 → gateway's public IP)
      ▼
Gateway eth0 → Internet
```

**Debug commands for NAT gateway:**
```bash
# Check forwarding is enabled (CRITICAL!)
sysctl net.ipv4.ip_forward
cat /proc/sys/net/ipv4/ip_forward

# Enable if needed
sysctl -w net.ipv4.ip_forward=1

# View FORWARD rules
iptables -L FORWARD -n -v

# View NAT POSTROUTING (MASQUERADE)
iptables -t nat -L POSTROUTING -n -v

# Check routing table
ip route

# Ask kernel: which interface for destination?
ip route get 8.8.8.8
ip route get 192.168.1.100

# Watch traffic leaving egress interface
tcpdump -ni eth0 host 8.8.8.8

# Verify conntrack is tracking NAT'd connections
conntrack -L | grep MASQ
```

---

### 5.3 Port Forwarding (DNAT)

**Scenario:** Forward port 8080 on public IP to internal web server

```bash
# Enable forwarding
echo 1 > /proc/sys/net/ipv4/ip_forward

# DNAT: Redirect incoming port 8080 to internal server
iptables -t nat -A PREROUTING -i eth0 -p tcp --dport 8080 \
    -j DNAT --to-destination 192.168.1.100:80

# Allow forwarded traffic
iptables -A FORWARD -p tcp -d 192.168.1.100 --dport 80 -j ACCEPT

# MASQUERADE for return traffic
iptables -t nat -A POSTROUTING -o eth1 -j MASQUERADE
```

**Packet path:**
```
Internet client → Gateway:8080
      │
      ▼
PREROUTING (nat DNAT)
      │ dst rewritten: gateway:8080 → 192.168.1.100:80
      ▼
Routing Decision → not local (now dest is 192.168.1.100) → FORWARD
      │
      ▼
FORWARD (filter) → ACCEPT
      │
      ▼
POSTROUTING (nat) → MASQUERADE (optional, for hairpin NAT)
      │
      ▼
Internal web server (192.168.1.100:80)
```

**Debug commands for port forwarding:**
```bash
# Check PREROUTING DNAT rules
iptables -t nat -L PREROUTING -n -v

# Check FORWARD allows the traffic
iptables -L FORWARD -n -v

# Watch traffic on public interface
tcpdump -ni eth0 port 8080

# Watch traffic on internal interface
tcpdump -ni eth1 host 192.168.1.100 and port 80

# Test from external
curl -v http://<public-ip>:8080

# Check conntrack for DNAT entries
conntrack -L | grep 8080
```

---

### 5.4 Rate Limiting (DDoS Protection)

**Scenario:** Limit SSH connection attempts

```bash
# Rate limit: max 3 new SSH connections per minute per IP
iptables -A INPUT -p tcp --dport 22 -m conntrack --ctstate NEW \
    -m recent --set --name SSH

iptables -A INPUT -p tcp --dport 22 -m conntrack --ctstate NEW \
    -m recent --update --seconds 60 --hitcount 4 --name SSH -j DROP

iptables -A INPUT -p tcp --dport 22 -j ACCEPT
```

**Alternative using hashlimit:**
```bash
iptables -A INPUT -p tcp --dport 22 -m conntrack --ctstate NEW \
    -m hashlimit --hashlimit-above 3/min --hashlimit-burst 3 \
    --hashlimit-mode srcip --hashlimit-name ssh_limit -j DROP
```

**Debug commands for rate limiting:**
```bash
# View recent module tracking
cat /proc/net/xt_recent/SSH

# Check hashlimit
cat /proc/net/ipt_hashlimit/ssh_limit

# Watch SSH attempts being rate-limited
journalctl -f | grep -E "(ssh|IPT)"

# Test: rapid connections (will get blocked)
for i in {1..10}; do ssh -o ConnectTimeout=1 user@host; done
```

---

### 5.5 Kubernetes/Docker Integration

**Scenario:** Understanding Docker's iptables rules

Docker automatically creates rules. Key chains to know:

```bash
# View Docker's NAT rules
iptables -t nat -L -n -v

# Key Docker chains:
# DOCKER - container port mappings
# DOCKER-USER - user-defined rules (insert your rules here!)
# DOCKER-ISOLATION-STAGE-1/2 - network isolation
```

**Docker packet flow for published port:**
```
Client → Host:8080
      │
      ▼
PREROUTING → DOCKER chain
      │ DNAT to container IP:port
      ▼
FORWARD → DOCKER chain → ACCEPT
      │
      ▼
Container (172.17.0.2:80)
```

**Add custom rules for Docker:**
```bash
# Always use DOCKER-USER chain (survives Docker restarts)
iptables -I DOCKER-USER -s 10.0.0.0/8 -j DROP  # Block internal range
```

**Debug commands for Docker:**
```bash
# View all Docker chains
iptables -S | grep -i docker | head -50
iptables -t nat -S | grep -i docker | head -50

# Check DOCKER-USER (your rules go here)
iptables -L DOCKER-USER -n -v

# View Docker network
docker network ls
docker network inspect bridge

# Check container IP
docker inspect <container> | grep IPAddress

# Watch container traffic
tcpdump -ni docker0
```

---

### 5.6 Tailscale Integration

**Scenario:** Understanding Tailscale's iptables rules

Tailscale creates custom chains for its VPN traffic:

```bash
# View Tailscale chains
iptables -L | grep -E "^(Chain|ts-)"
```

**Key Tailscale rules:**
```
ts-input:  Anti-spoofing (100.64.0.0/10 must come from tailscale0)
ts-forward: Controls traffic forwarding through Tailscale
```

**Packet flow for Tailscale:**
```
Tailscale peer → tailscale0 interface
      │
      ▼
PREROUTING
      │
      ▼
INPUT → ts-input chain
      │ Verify: src in 100.64.0.0/10 AND interface = tailscale0
      ▼
Local service (if allowed)
```

**Debug commands for Tailscale:**
```bash
# View Tailscale chains
iptables -L ts-input -n -v --line-numbers
iptables -L ts-forward -n -v --line-numbers

# Check Tailscale interface
ip -br a | grep tailscale
ip route | grep tailscale

# Watch Tailscale traffic
tcpdump -ni tailscale0

# Tailscale status
tailscale status
tailscale netcheck

# If advertising subnet routes
sysctl net.ipv4.ip_forward
iptables -L FORWARD -n -v | grep -E "(ts-|tailscale)"
```

---

## 6. Debugging & Troubleshooting

### Key Debugging Principle

> **DevOps reality:** many "iptables issues" are actually **routing issues**. Always check routing first!

### 6.1 View Rules with Counters

```bash
# Filter table (most common)
sudo iptables -L -v -n --line-numbers

# NAT table
sudo iptables -t nat -L -v -n --line-numbers

# Mangle table
sudo iptables -t mangle -L -v -n --line-numbers

# Raw table
sudo iptables -t raw -L -v -n --line-numbers

# All tables at once
for table in filter nat mangle raw; do
    echo "=== $table ==="
    iptables -t $table -L -v -n
done
```

### 6.2 Check Routing (Often the Real Problem!)

```bash
# View routing table
ip route

# Ask kernel: which interface/gateway for a destination?
ip route get 8.8.8.8
ip route get 192.168.1.100

# Example output interpretation:
# 8.8.8.8 via 10.0.0.1 dev eth0 src 10.0.0.5
#   ↑ dst    ↑ gateway   ↑ interface  ↑ source IP used

# Check if forwarding enabled (needed for FORWARD chain)
sysctl net.ipv4.ip_forward

# View interfaces
ip -br a
ip -br link

# Check ARP table (L2 issues)
ip neigh
arp -n
```

**Routing decision determines INPUT vs FORWARD:**
- If `ip route get <dst>` shows local delivery → INPUT chain
- If `ip route get <dst>` shows forwarding to another interface → FORWARD chain

### 6.3 Trace Packets Through iptables

```bash
# Enable tracing for specific packets
iptables -t raw -A PREROUTING -p tcp --dport 22 -j TRACE
iptables -t raw -A OUTPUT -p tcp --dport 22 -j TRACE

# View trace logs
dmesg | grep TRACE
# Or
cat /var/log/kern.log | grep TRACE

# Disable tracing when done
iptables -t raw -D PREROUTING -p tcp --dport 22 -j TRACE
iptables -t raw -D OUTPUT -p tcp --dport 22 -j TRACE
```

**Trace output explained:**
```
TRACE: raw:PREROUTING:policy:2 IN=eth0 ...
TRACE: mangle:PREROUTING:policy:1 IN=eth0 ...
TRACE: nat:PREROUTING:policy:2 IN=eth0 ...
TRACE: filter:INPUT:rule:3 IN=eth0 ...    ← Matched rule #3!
```

### 6.4 Watch Counters in Real-Time

```bash
# Watch specific chain
watch -n1 'iptables -L INPUT -v -n'

# Compare before/after
iptables -L INPUT -v -n > before.txt
# ... do action ...
iptables -L INPUT -v -n > after.txt
diff before.txt after.txt
```

### 6.5 Log Dropped Packets

```bash
# Add logging before DROP
iptables -A INPUT -j LOG --log-prefix "IPT-INPUT-DROP: " --log-level 4
iptables -A INPUT -j DROP

# View logs
tail -f /var/log/syslog | grep "IPT-INPUT-DROP"

# Or with journald
journalctl -f | grep "IPT-INPUT-DROP"
```

### 6.6 Common Issues

| Symptom | Likely Cause | Check |
|---------|--------------|-------|
| Can't connect to service | INPUT DROP rule | `iptables -L INPUT -n` |
| NAT not working | Missing FORWARD allow | `iptables -L FORWARD -n` |
| DNAT not working | Missing POSTROUTING | `iptables -t nat -L -n` |
| Containers unreachable | DOCKER-USER blocking | `iptables -L DOCKER-USER -n` |
| Forwarding not working | ip_forward disabled | `cat /proc/sys/net/ipv4/ip_forward` |

### 6.7 Emergency Recovery

```bash
# Flush all rules (restore access)
iptables -F
iptables -t nat -F
iptables -t mangle -F
iptables -X

# Set permissive defaults
iptables -P INPUT ACCEPT
iptables -P FORWARD ACCEPT
iptables -P OUTPUT ACCEPT
```

---

## 7. Ops Hygiene & Safety

### Don't Lock Yourself Out!

Before making ANY changes on a remote box:

```bash
# ALWAYS backup first
iptables-save > /root/iptables.backup.$(date +%F_%H%M%S).rules

# Set a cron job to restore rules (insurance policy)
echo "*/5 * * * * root /sbin/iptables-restore < /root/iptables.backup.rules" | sudo tee /etc/cron.d/iptables-restore

# After testing, remove the cron job
rm /etc/cron.d/iptables-restore
```

### Restore from Backup

```bash
# Restore saved rules
iptables-restore < /root/iptables.backup.<timestamp>.rules

# Or restore from persistent file
iptables-restore < /etc/iptables/rules.v4
```

### Check iptables vs nftables Backend

Many modern distros use nftables as the backend:

```bash
# Check which binary you're using
iptables -V

# Example output:
# iptables v1.8.7 (nf_tables)  ← nftables backend
# iptables v1.8.7 (legacy)     ← legacy iptables

# Check alternatives
update-alternatives --display iptables 2>/dev/null || true

# View nftables directly (if using nf_tables backend)
nft list ruleset
```

### Safe Testing Pattern

```bash
# 1. Backup current rules
iptables-save > /tmp/before.rules

# 2. Add your rule
iptables -A INPUT -p tcp --dport 8080 -j ACCEPT

# 3. Test it works
curl localhost:8080

# 4. If broken, restore immediately
iptables-restore < /tmp/before.rules

# 5. If working, save permanently
iptables-save > /etc/iptables/rules.v4
```

### Remote Access Safety

When working remotely via SSH:

```bash
# Method 1: Schedule rule flush (insurance)
at now + 5 minutes <<< 'iptables -F; iptables -P INPUT ACCEPT'

# Method 2: Use iptables-apply (auto-reverts if you disconnect)
iptables-apply /etc/iptables/rules.v4

# Method 3: Always allow your IP first
iptables -I INPUT 1 -s YOUR_IP -j ACCEPT
```

### Persistence Across Reboots

```bash
# Debian/Ubuntu
apt install iptables-persistent
netfilter-persistent save
netfilter-persistent reload

# Files location:
/etc/iptables/rules.v4
/etc/iptables/rules.v6

# RHEL/CentOS
service iptables save
# Or
iptables-save > /etc/sysconfig/iptables
```

---

## 8. Practice Exercises

### Exercise 1: Basic Firewall
```bash
# Goal: Allow only SSH and HTTP, drop everything else

# 1. Set default DROP policy for INPUT
# 2. Allow loopback
# 3. Allow ESTABLISHED,RELATED
# 4. Allow SSH (22) and HTTP (80)
# 5. Test with: nmap -F localhost
```

### Exercise 2: Trace a Packet
```bash
# Goal: See exactly which rules a packet hits

# 1. Enable TRACE for ICMP
iptables -t raw -A PREROUTING -p icmp -j TRACE

# 2. Ping from another host
ping -c 1 <your-vm-ip>

# 3. Check trace
dmesg | tail -20

# 4. Clean up
iptables -t raw -F
```

### Exercise 3: Port Forwarding
```bash
# Goal: Forward port 8080 to local nginx on 80

# 1. Start nginx
sudo systemctl start nginx

# 2. Add DNAT rule
iptables -t nat -A PREROUTING -p tcp --dport 8080 -j REDIRECT --to-port 80

# 3. Test
curl localhost:8080

# 4. View NAT table
iptables -t nat -L -n -v
```

### Exercise 4: Rate Limiting
```bash
# Goal: Block IPs after 5 failed SSH attempts

# 1. Implement rate limiting (see section 5.4)
# 2. Test with hydra or manual failed attempts
# 3. Check if IP gets blocked
# 4. View the recent list: cat /proc/net/xt_recent/SSH
```

### Exercise 5: Analyze Existing Rules
```bash
# Goal: Understand what's already configured

# 1. List all rules in all tables
for t in filter nat mangle raw; do
    echo "=== TABLE: $t ==="
    iptables -t $t -L -v -n
done

# 2. Identify custom chains (Docker, Tailscale, etc.)
# 3. Trace a packet and correlate with rules
```

---

## Quick Reference Card

### Viewing Rules
```bash
iptables -L -v -n                    # Filter table
iptables -t nat -L -v -n             # NAT table
iptables -S                          # Rules in iptables-save format
```

### Common Matches
```bash
-p tcp/udp/icmp                      # Protocol
--dport 22                           # Destination port
--sport 1024:65535                   # Source port range
-s 192.168.1.0/24                    # Source IP/network
-d 10.0.0.1                          # Destination IP
-i eth0                              # Input interface
-o eth1                              # Output interface
-m conntrack --ctstate NEW           # Connection state
-m multiport --dports 80,443         # Multiple ports
```

### Common Targets
```bash
-j ACCEPT                            # Allow packet
-j DROP                              # Silently discard
-j REJECT                            # Discard with ICMP error
-j LOG                               # Log to syslog
-j DNAT --to-destination IP:PORT     # Destination NAT
-j SNAT --to-source IP               # Source NAT
-j MASQUERADE                        # Dynamic SNAT
-j REDIRECT --to-port PORT           # Local port redirect
```

### Persistence
```bash
# Debian/Ubuntu
apt install iptables-persistent
netfilter-persistent save
netfilter-persistent reload

# Rules stored in:
/etc/iptables/rules.v4
/etc/iptables/rules.v6
```

---

## Quick Mapping Table (Memorize This!)

| DevOps Scenario | Chain/Table | Key Rule |
|-----------------|-------------|----------|
| **Protect local services** (SSH, web) | `filter INPUT` | `-A INPUT -p tcp --dport 22 -j ACCEPT` |
| **Control outbound** (egress) | `filter OUTPUT` | `-A OUTPUT -d bad.ip -j DROP` |
| **Route between networks** | `filter FORWARD` | `-A FORWARD -i eth1 -o eth0 -j ACCEPT` |
| **Port forward to internal** | `nat PREROUTING` | `-t nat -A PREROUTING --dport 80 -j DNAT --to 192.168.1.10:80` |
| **Hide private IPs** (NAT) | `nat POSTROUTING` | `-t nat -A POSTROUTING -o eth0 -j MASQUERADE` |

### The Corrected Mental Model

**Wrong:** "Packet arrives → kernel applies iptables rules"

**Correct:**
```
1. Packet arrives on NIC → enters kernel
2. Kernel hits PREROUTING hook (raw/mangle/nat tables)
3. Routing decision: local vs forward?
4. If local → INPUT hook (mangle/filter)
5. If forward → FORWARD hook → POSTROUTING hook
6. Local process replies → OUTPUT hook → POSTROUTING hook
7. Packet exits via NIC
```

**Key insight:** iptables doesn't process packets "once" - it's a **pipeline of hooks**, each consulting specific tables.

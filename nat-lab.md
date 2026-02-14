# NAT Lab: SNAT, DNAT, and MASQUERADE
> Master Network Address Translation with hands-on exercises on two VMs

## Table of Contents
1. [Lab Environment](#1-lab-environment) - Network layout and roles
2. [Phase 1: Clean Slate](#2-phase-1-clean-slate) - Reset all tables
3. [Phase 2: IP Forwarding](#3-phase-2-ip-forwarding) - Enable the kernel to route
4. [Phase 3: MASQUERADE](#4-phase-3-masquerade---m-as-nat-gateway) - M as NAT gateway for W
5. [Phase 4: SNAT vs MASQUERADE](#5-phase-4-snat-vs-masquerade) - When to use which
6. [Phase 5: DNAT (Port Forwarding)](#6-phase-5-dnat---port-forwarding) - Forward traffic to internal host
7. [Phase 6: The Return Path Problem](#7-phase-6-the-return-path-problem) - Why DNAT breaks on same subnet
8. [Phase 7: Full NAT Gateway](#8-phase-7-full-nat-gateway) - Combined SNAT + DNAT ruleset
9. [Phase 8: Debugging NAT](#9-phase-8-debugging-nat) - conntrack, tcpdump, counters
10. [Phase 9: Persistence & Cleanup](#10-phase-9-persistence--cleanup) - Save and reset

## Overview

This lab covers **Phase 3 of the roadmap** — NAT Mastery. You'll build on
the stateful firewall knowledge from iptables-lab.md and the packet flow
understanding from packet-journey.md.

**What you'll learn:**
- Turn M into a NAT gateway that masquerades W's traffic
- Forward ports through M to reach services on W (DNAT)
- Understand the return path — why NAT breaks without conntrack
- Debug NAT with conntrack and tcpdump
- Know when to use SNAT vs MASQUERADE

**Prerequisite knowledge:**
- Stateful firewall (ESTABLISHED,RELATED) from iptables-lab.md
- Packet flow through PREROUTING → routing → FORWARD → POSTROUTING from packet-journey.md

---

## 1. Lab Environment

```
                    Internet / Default Gateway
                           192.168.11.1
                               │
          ┌────────────────────┼────────────────────┐
          │                    │                     │
┌─────────┴───────────┐  ┌────┴────────────────┐  ┌─┴───────────────────┐
│  M (NAT Gateway)    │  │  W (Internal Host)  │  │  Admin PC           │
│  192.168.11.109     │  │  192.168.11.110     │  │  192.168.11.50      │
│                     │  │                     │  │  (always allowed)   │
│  Roles:             │  │  Roles:             │  │                     │
│  - NAT gateway      │  │  - Routes via M     │  │  - External client  │
│  - Port forwarder   │  │  - Web server       │  │  - Tests DNAT       │
│  - SNAT/MASQUERADE  │  │  - Backend service  │  │                     │
└─────────────────────┘  └─────────────────────┘  └─────────────────────┘
```

**Convention:** Run commands on the host shown in the prompt:
- `M#` = run on 192.168.11.109 (NAT gateway)
- `W#` = run on 192.168.11.110 (internal host)

> **Before you start:** Check your interface name on both hosts:
> ```bash
> ip -br a
> ```
> Replace `eth0` in the examples below with your actual interface name.

---

## 2. Phase 1: Clean Slate

Flush **all tables** on both hosts — including nat (which iptables-lab.md didn't touch).

```bash
# Run on BOTH M and W
iptables -F                    # Flush filter table
iptables -X                    # Delete custom chains
iptables -Z                    # Zero counters
iptables -t nat -F             # Flush NAT table
iptables -t nat -X
iptables -t nat -Z
iptables -t mangle -F          # Flush mangle table
iptables -P INPUT ACCEPT
iptables -P FORWARD ACCEPT
iptables -P OUTPUT ACCEPT
```

**Verify on both:**
```bash
iptables -L -v -n
iptables -t nat -L -v -n
```

**Expected:** All chains empty, all policies ACCEPT, zero counters in both filter and nat tables.

---

## 3. Phase 2: IP Forwarding

By default, Linux drops packets not addressed to itself. To act as a router
or NAT gateway, M must forward packets between hosts.

### Check current state

```bash
M# sysctl net.ipv4.ip_forward
```

**Expected output:** `net.ipv4.ip_forward = 0` (disabled by default)

### Enable temporarily (lost on reboot)

```bash
M# sysctl -w net.ipv4.ip_forward=1
```

### Enable permanently

```bash
M# echo 'net.ipv4.ip_forward = 1' >> /etc/sysctl.d/99-nat-gateway.conf
M# sysctl -p /etc/sysctl.d/99-nat-gateway.conf
```

### Verify

```bash
M# cat /proc/sys/net/ipv4/ip_forward
# Should output: 1
```

**Concept:** Without `ip_forward=1`, packets arriving at M with a destination
other than M's own IPs are silently dropped — they never reach the FORWARD chain.

```
ip_forward = 0:
  Packet for 8.8.8.8 arrives at M → kernel says "not for me" → DROP

ip_forward = 1:
  Packet for 8.8.8.8 arrives at M → routing decision → FORWARD chain → POSTROUTING → out
```

---

## 4. Phase 3: MASQUERADE — M as NAT Gateway

**Goal:** W sends all its internet traffic through M. M rewrites the source IP
to its own address (MASQUERADE), making W invisible to the outside world.

```
W (192.168.11.110)                  M (192.168.11.109)              Internet
       │                                   │                           │
       │  src=.110  dst=8.8.8.8            │                           │
       ├──────────────────────────────────► │                           │
       │                                   │  MASQUERADE               │
       │                                   │  src=.109  dst=8.8.8.8   │
       │                                   ├─────────────────────────► │
       │                                   │                           │
       │                                   │  src=8.8.8.8  dst=.109   │
       │                                   │ ◄─────────────────────────┤
       │                                   │  reverse-NAT              │
       │  src=8.8.8.8  dst=.110            │                           │
       │ ◄─────────────────────────────────┤                           │
```

### Step 1 — Save W's original default route

Before changing anything, save W's current gateway so you can restore it later.

```bash
W# ip route show default
# Example output: default via 192.168.11.1 dev eth0 proto dhcp metric 100
# ^^^ note this — you'll need it for cleanup
```

### Step 2 — Add MASQUERADE rule on M

```bash
M# iptables -t nat -A POSTROUTING -s 192.168.11.110 -o eth0 -j MASQUERADE
```

**Rule breakdown:**
- `-t nat` — operate on the nat table
- `-A POSTROUTING` — append to POSTROUTING chain (last hook before packet leaves)
- `-s 192.168.11.110` — only NAT traffic from W
- `-o eth0` — only when leaving via the outbound interface
- `-j MASQUERADE` — rewrite source IP to M's interface IP

### Step 3 — Allow forwarding on M

M needs to allow W's traffic through the FORWARD chain:

```bash
# Allow W's traffic to be forwarded out
M# iptables -A FORWARD -s 192.168.11.110 -o eth0 -j ACCEPT

# Allow return traffic (responses) back to W
M# iptables -A FORWARD -d 192.168.11.110 -m state --state ESTABLISHED,RELATED -j ACCEPT
```

**Concept:** MASQUERADE only rewrites the source IP — it doesn't bypass the
FORWARD chain. If FORWARD policy is DROP without these rules, packets get
masqueraded but never leave (or return traffic never reaches W).

### Step 4 — Change W's default route to go through M

```bash
W# ip route replace default via 192.168.11.109
```

**Verify:**
```bash
W# ip route show default
# Expected: default via 192.168.11.109 dev eth0
```

### Step 5 — Test

**On W — try reaching the internet:**
```bash
W# ping -c 3 8.8.8.8
W# curl -s --max-time 5 ifconfig.me
```

**On M — watch the traffic (run BEFORE the test above):**
```bash
M# tcpdump -ni eth0 host 8.8.8.8 -c 10
```

**What you should see on tcpdump:**
```
# Outbound: src is M's IP (.109), NOT W's IP (.110) — MASQUERADE worked!
192.168.11.109 > 8.8.8.8: ICMP echo request
8.8.8.8 > 192.168.11.109: ICMP echo reply
```

### Step 6 — Inspect conntrack on M

```bash
M# conntrack -L | grep 8.8.8.8
```

**Expected entry (simplified):**
```
icmp  1 src=192.168.11.110 dst=8.8.8.8     [UNREPLIED]
          src=8.8.8.8     dst=192.168.11.109           ← reply tuple rewritten!
```

Notice: the **Original** tuple has W's real IP (.110), but the **Reply** tuple
has M's IP (.109). This is how conntrack knows to reverse the NAT on return packets.

### Step 7 — Verify the nat table counters

```bash
M# iptables -t nat -L POSTROUTING -v -n
```

**Expected:** The MASQUERADE rule shows packet/byte counters increasing.

**Concept recap — what happened step by step:**

```
1. W sends packet: src=.110 dst=8.8.8.8
2. W's routing: default via .109 → sends to M
3. M receives packet on eth0
4. M: PREROUTING → no DNAT rules → pass
5. M: routing decision → dst is NOT local → FORWARD chain
6. M: FORWARD → rule matches src=.110 → ACCEPT
7. M: POSTROUTING → MASQUERADE → src rewritten to .109
8. M: conntrack creates entry mapping .110 ↔ .109
9. Packet leaves M as src=.109 dst=8.8.8.8
10. Reply arrives: src=8.8.8.8 dst=.109
11. M: conntrack matches reply tuple → reverse NAT → dst becomes .110
12. M: FORWARD → ESTABLISHED,RELATED → ACCEPT
13. Packet delivered to W as src=8.8.8.8 dst=.110
```

> See [packet-journey.md — Scenario 2](packet-journey.md#scenario-2-snatmasquerade)
> for the detailed diagram of this flow.

---

## 5. Phase 4: SNAT vs MASQUERADE

MASQUERADE and SNAT do the same thing — rewrite the source IP. The difference
is subtle but important for production.

### SNAT — Static source NAT

```bash
# Replace the MASQUERADE rule with explicit SNAT
M# iptables -t nat -D POSTROUTING -s 192.168.11.110 -o eth0 -j MASQUERADE
M# iptables -t nat -A POSTROUTING -s 192.168.11.110 -o eth0 -j SNAT --to-source 192.168.11.109
```

**Test (same as before):**
```bash
W# ping -c 2 8.8.8.8
M# conntrack -L | grep 8.8.8.8
```

Works the same. So what's the difference?

### Comparison

```
┌──────────────────┬──────────────────────────────────────────────┐
│                  │  MASQUERADE              SNAT                │
├──────────────────┼──────────────────────────────────────────────┤
│ Source IP        │  Auto-detects from       You specify it      │
│                  │  outgoing interface      explicitly           │
│                  │                                              │
│ When IP changes  │  Adapts automatically    Rule becomes wrong  │
│  (DHCP, PPPoE)  │  (re-reads iface IP)     (must update rule)  │
│                  │                                              │
│ Performance      │  Slightly slower         Slightly faster     │
│                  │  (checks IP each time)   (IP is cached)      │
│                  │                                              │
│ Use when         │  Dynamic IP (home,       Static IP (cloud    │
│                  │  DHCP, dial-up)          VMs, servers)       │
└──────────────────┴──────────────────────────────────────────────┘
```

**Rule of thumb:**
- **Home lab / DHCP** → `MASQUERADE`
- **Cloud VM / static IP** → `SNAT --to-source <ip>` (slightly more efficient)

### Reset back to MASQUERADE for remaining exercises

```bash
M# iptables -t nat -F POSTROUTING
M# iptables -t nat -A POSTROUTING -s 192.168.11.110 -o eth0 -j MASQUERADE
```

---

## 6. Phase 5: DNAT — Port Forwarding

**Goal:** External clients connect to M:8080, and M forwards the traffic
to W's web server on port 80.

```
Admin PC (.50)           M (.109)                  W (.110)
    │                       │                         │
    │  dst=.109:8080        │                         │
    ├──────────────────────►│                         │
    │                       │  DNAT                   │
    │                       │  dst→.110:80            │
    │                       ├────────────────────────►│
    │                       │                         │  nginx responds
    │                       │  reverse-NAT            │
    │                       │◄────────────────────────┤
    │  src=.109:8080        │                         │
    │◄──────────────────────┤                         │
```

### Step 1 — Start a web server on W

```bash
W# cat > /tmp/web.py << 'EOF'
from http.server import HTTPServer, BaseHTTPRequestHandler
import socket

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        srv_ip, srv_port = self.server.server_address
        cli_ip, cli_port = self.client_address
        body = (
            f"Hello from W ({socket.gethostname()})\n"
            f"  Server: {srv_ip}:{srv_port}\n"
            f"  Client: {cli_ip}:{cli_port}\n"
        )
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.end_headers()
        self.wfile.write(body.encode())
    def log_message(self, *a): pass

HTTPServer(("0.0.0.0", 80), Handler).serve_forever()
EOF
W# python3 /tmp/web.py &
```

**Verify locally:**
```bash
W# curl -s http://127.0.0.1
# Expected:
# Hello from W (...)
#   Server: 0.0.0.0:80
#   Client: 127.0.0.1:<port>
```

### Step 2 — Add DNAT rule on M

```bash
M# iptables -t nat -A PREROUTING -i eth0 -p tcp --dport 8080 \
   -j DNAT --to-destination 192.168.11.110:80
```

**Rule breakdown:**
- `-t nat -A PREROUTING` — rewrite destination BEFORE routing decision
- `-i eth0` — only for traffic arriving on the external interface
- `-p tcp --dport 8080` — match TCP port 8080
- `-j DNAT --to-destination 192.168.11.110:80` — rewrite dest to W:80

**Why PREROUTING?** The routing decision comes AFTER PREROUTING. If we don't
rewrite the destination first, the kernel sees dst=.109 (local) and sends the
packet to INPUT — never reaches FORWARD.

```
Without DNAT in PREROUTING:
  Packet dst=.109:8080 → routing: "that's me" → INPUT → no service on 8080 → RST

With DNAT in PREROUTING:
  Packet dst=.109:8080 → DNAT: dst→.110:80 → routing: "not me" → FORWARD → W
```

### Step 3 — Allow forwarded DNAT traffic

```bash
M# iptables -A FORWARD -p tcp -d 192.168.11.110 --dport 80 \
   -m state --state NEW -j ACCEPT
```

> The ESTABLISHED,RELATED rule from Phase 3 handles return traffic.
> If you skipped Phase 3 or flushed, add it:
> ```bash
> M# iptables -A FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT
> ```

### Step 4 — Test from Admin PC

```bash
# From Admin PC (192.168.11.50):
curl -s http://192.168.11.109:8080
```

**Expected:** `Hello from W (...)`

**Did it work?** If yes, great — skip to Step 6.

**Did it fail?** Read Phase 6 below — you've hit the **return path problem**.

### Step 5 — Watch with tcpdump (run on M BEFORE the curl)

Open two terminals on M:

```bash
# Terminal 1: watch incoming traffic
M# tcpdump -ni eth0 port 8080 -c 4

# Terminal 2: watch forwarded traffic toward W
M# tcpdump -ni eth0 host 192.168.11.110 and port 80 -c 4
```

**Now curl from admin PC.** You should see:
- Terminal 1: `192.168.11.50 > 192.168.11.109.8080`
- Terminal 2: `192.168.11.50 > 192.168.11.110.80` (DNAT applied)

### Step 6 — Inspect conntrack

```bash
M# conntrack -L | grep 8080
```

**Expected (simplified):**
```
tcp  6 ESTABLISHED src=192.168.11.50 dst=192.168.11.109 sport=XXXXX dport=8080
                   src=192.168.11.110 dst=192.168.11.50 sport=80 dport=XXXXX
```

The conntrack entry shows both the original (what the client sent) and reply
(what the backend sends back) tuples.

---

## 7. Phase 6: The Return Path Problem

> **This is the #1 NAT debugging issue in real-world scenarios.**

### The problem: same-subnet DNAT

When the client, the gateway, and the backend are **all on the same subnet**,
DNAT alone breaks. Here's why:

```
Step 1: Admin (.50) sends to M (.109):8080
        src=.50  dst=.109:8080

Step 2: M DNATs: dst → .110:80, forwards to W
        src=.50  dst=.110:80        ← source is still .50!

Step 3: W receives packet, sees src=.50
        W checks routing: .50 is on my LAN, I know its MAC
        W responds DIRECTLY to .50 (bypasses M entirely!)
        src=.110:80  dst=.50

Step 4: Admin PC receives packet from .110:80
        But it's expecting a response from .109:8080!
        → TCP RST or silently dropped
        → Connection hangs or fails
```

```
                BROKEN — asymmetric routing

Admin (.50)             M (.109)              W (.110)
    │                       │                     │
    │──── SYN ─────────────►│                     │
    │                       │──── DNAT'd SYN ────►│
    │                       │                     │
    │◄──── SYN-ACK directly from W ───────────────│  ← WRONG!
    │   (src=.110:80, but expected .109:8080)     │
    │                                             │
    │   TCP mismatch → connection fails           │
```

### The fix: SNAT the forwarded traffic too

Make M also rewrite the **source IP** of DNAT'd packets, so W sees M as
the client and responds back through M:

```bash
M# iptables -t nat -A POSTROUTING -d 192.168.11.110 -p tcp --dport 80 \
   -j MASQUERADE
```

**Now the flow is correct:**

```
                FIXED — symmetric routing

Admin (.50)             M (.109)              W (.110)
    │                       │                     │
    │──── SYN ─────────────►│                     │
    │   dst=.109:8080       │                     │
    │                       │──── DNAT+SNAT ─────►│
    │                       │  src=.109 dst=.110  │  ← W sees M as client
    │                       │                     │
    │                       │◄── response ────────│
    │                       │  src=.110 dst=.109  │  ← W responds to M
    │                       │                     │
    │◄── reverse NAT ───────│                     │
    │  src=.109:8080        │                     │  ← Admin sees M:8080
```

### When you DON'T need this fix

If the client is on a **different subnet** from the backend, the return
path naturally goes through the gateway:

```
Client (1.2.3.4)  →  Gateway (203.0.113.1:8080)  →  Backend (10.0.0.5:80)
                                                          │
                                                          │ src=10.0.0.5 dst=1.2.3.4
                                                          │ routing: 1.2.3.4 not on my LAN
                                                          │ → default gateway → back through NAT gateway
                                                          ▼
                                                     Gateway reverses NAT ✓
```

### Trade-off of full NAT (SNAT + DNAT)

```
┌──────────────────────────────────────────────────────────────────────┐
│  Pros                          │  Cons                              │
├────────────────────────────────┼────────────────────────────────────┤
│  Works on any topology         │  Backend loses real client IP      │
│  (same subnet, cross-subnet)   │  (W sees .109, not .50)           │
│                                │                                    │
│  No asymmetric routing         │  All traffic flows through M      │
│                                │  (potential bottleneck)            │
│                                │                                    │
│  Simple to debug               │  Logs on W show gateway IP,       │
│  (all traffic through one hop) │  not real client IP                │
└────────────────────────────────┴────────────────────────────────────┘
```

**DevOps workaround for losing client IP:**
- Use `X-Forwarded-For` header (HTTP reverse proxy, not raw NAT)
- Use proxy protocol (HAProxy, nginx stream)
- Move to separate subnets (proper topology, no hairpin needed)

---

## 8. Phase 7: Full NAT Gateway

Combine everything into a complete gateway ruleset on M.

### Complete ruleset for M

```bash
# ── 1. Kernel: enable forwarding ──
sysctl -w net.ipv4.ip_forward=1

# ── 2. Flush everything ──
iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X

# ── 3. Default policies ──
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT ACCEPT

# ── 4. Loopback ──
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

# ── 5. Allow established (filter table) ──
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT

# ── 6. SSH access to gateway itself ──
iptables -A INPUT -p tcp -s 192.168.11.50 --dport 22 -j ACCEPT

# ── 7. FORWARD rules ──
# Allow W's outbound traffic
iptables -A FORWARD -s 192.168.11.110 -o eth0 -j ACCEPT
# Allow DNAT'd traffic to W's web server
iptables -A FORWARD -p tcp -d 192.168.11.110 --dport 80 -m state --state NEW -j ACCEPT

# ── 8. NAT rules ──
# MASQUERADE: W's outbound traffic (SNAT)
iptables -t nat -A POSTROUTING -s 192.168.11.110 -o eth0 -j MASQUERADE
# DNAT: port forward 8080 → W:80
iptables -t nat -A PREROUTING -i eth0 -p tcp --dport 8080 -j DNAT --to-destination 192.168.11.110:80
# Hairpin: SNAT for same-subnet DNAT (fixes return path)
iptables -t nat -A POSTROUTING -d 192.168.11.110 -p tcp --dport 80 -j MASQUERADE

# ── 9. Logging (optional) ──
iptables -A INPUT -j LOG --log-prefix "GW-INPUT-DROP: " --log-level 4
iptables -A FORWARD -j LOG --log-prefix "GW-FORWARD-DROP: " --log-level 4
```

### Verify the full ruleset

```bash
M# iptables -L -v -n --line-numbers
M# iptables -t nat -L -v -n --line-numbers
```

### Test matrix

Run these tests to verify everything works:

| # | Test | From | To | Expected |
|---|------|------|----|----------|
| 1 | W pings internet | W | 8.8.8.8 | OK (MASQUERADE) |
| 2 | W curls internet | W | any HTTP | OK (MASQUERADE) |
| 3 | Admin curls M:8080 | .50 | M:8080 | OK (DNAT → W:80) |
| 4 | SSH to M from admin | .50 | M:22 | OK (INPUT rule) |
| 5 | SSH to M from random | any | M:22 | BLOCKED |
| 6 | Random port on M | .50 | M:3306 | BLOCKED + logged |

---

## 9. Phase 8: Debugging NAT

### 8.1 The debugging workflow

When NAT isn't working, diagnose in this order:

```
1. Is ip_forward enabled?          → sysctl net.ipv4.ip_forward
2. Are the NAT rules there?        → iptables -t nat -L -v -n
3. Is FORWARD allowing it?         → iptables -L FORWARD -v -n
4. Is conntrack tracking it?       → conntrack -L | grep <port>
5. Is the packet actually arriving?→ tcpdump on each hop
6. Is the return path correct?     → tcpdump on return interface
```

### 8.2 Essential commands

**View NAT rules with counters:**
```bash
iptables -t nat -L -v -n --line-numbers
```
If counters on your DNAT/MASQUERADE rules stay at 0, the traffic isn't matching.

**Watch conntrack in real-time:**
```bash
# All new connections
conntrack -E

# Filter for specific traffic
conntrack -E | grep 8080
conntrack -E | grep DNAT
```

**View the conntrack table:**
```bash
# All entries
conntrack -L

# Only NAT'd entries
conntrack -L | grep DNAT
conntrack -L | grep MASQ

# Count by state
conntrack -L 2>/dev/null | awk '{print $4}' | sort | uniq -c | sort -rn
```

**tcpdump at each hop (run on M):**
```bash
# What arrives from the client?
tcpdump -ni eth0 port 8080

# What gets forwarded to backend?
tcpdump -ni eth0 host 192.168.11.110 and port 80

# What returns from backend?
tcpdump -ni eth0 src 192.168.11.110 and port 80
```

**Trace packets through iptables (heavy, use briefly):**
```bash
# Enable
iptables -t raw -A PREROUTING -p tcp --dport 8080 -j TRACE
iptables -t raw -A OUTPUT -p tcp --sport 8080 -j TRACE

# Read
dmesg | grep TRACE

# Disable when done!
iptables -t raw -F
```

### 8.3 Common NAT problems

| Symptom | Likely Cause | Fix |
|---------|--------------|-----|
| W can't reach internet | ip_forward=0 | `sysctl -w net.ipv4.ip_forward=1` |
| W can't reach internet | No FORWARD rule | Add `-A FORWARD -s W -j ACCEPT` |
| W can't reach internet | No MASQUERADE | Add POSTROUTING MASQUERADE rule |
| DNAT not working | No DNAT rule | Add PREROUTING DNAT rule |
| DNAT not working | FORWARD blocks it | Add FORWARD rule for DNAT'd dst |
| DNAT works for some clients, not others | Same-subnet return path | Add MASQUERADE for DNAT'd traffic |
| conntrack shows entries but traffic dies | MTU/fragmentation | Check `tcpdump` for ICMP "need frag" |
| "Connection refused" | Backend service not running | Check `ss -tlnp` on backend |
| Rules have counters but no response | Return traffic blocked | Check FORWARD ESTABLISHED,RELATED |

### 8.4 Exercise: Break and fix

Try each of these on M, test, then fix:

**Break 1 — Remove FORWARD ESTABLISHED,RELATED:**
```bash
M# iptables -D FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT
# Test: W# ping 8.8.8.8 → hangs (SYN goes out, SYN-ACK can't return)
# Fix:
M# iptables -I FORWARD 1 -m state --state ESTABLISHED,RELATED -j ACCEPT
```

**Break 2 — Disable forwarding:**
```bash
M# sysctl -w net.ipv4.ip_forward=0
# Test: W# ping 8.8.8.8 → no response (packets silently dropped by kernel)
# Fix:
M# sysctl -w net.ipv4.ip_forward=1
```

**Break 3 — Remove MASQUERADE:**
```bash
M# iptables -t nat -F POSTROUTING
# Test: W# ping 8.8.8.8 → no response
#   Why? 8.8.8.8 receives src=192.168.11.110 (private IP)
#   It has no route back to a private IP → response discarded
# Fix:
M# iptables -t nat -A POSTROUTING -s 192.168.11.110 -o eth0 -j MASQUERADE
```

---

## 10. Phase 9: Persistence & Cleanup

### Save the NAT gateway rules

```bash
M# iptables-save > /etc/iptables/rules.v4
# Or if iptables-persistent is installed:
M# netfilter-persistent save
```

`iptables-save` captures **all tables** (filter + nat + mangle + raw) in one file.

### Restore W's default route

```bash
# Replace with the gateway you noted in Phase 3 Step 1
W# ip route replace default via 192.168.11.1
```

### Verify W can reach internet directly again

```bash
W# ping -c 2 8.8.8.8
```

### Full cleanup — reset everything

**On M:**
```bash
iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X
iptables -t mangle -F
iptables -t raw -F
iptables -P INPUT ACCEPT
iptables -P FORWARD ACCEPT
iptables -P OUTPUT ACCEPT
sysctl -w net.ipv4.ip_forward=0
```

**On W:**
```bash
W# ip route replace default via 192.168.11.1
W# kill %1 2>/dev/null   # stop python web server if running
```

### Stop the web server on W

```bash
W# kill %1 2>/dev/null
# Or find and kill it:
W# fuser -k 80/tcp
```

---

## Quick Reference

### NAT table commands
```bash
iptables -t nat -L -v -n                              # List NAT rules
iptables -t nat -L PREROUTING -v -n --line-numbers    # DNAT rules
iptables -t nat -L POSTROUTING -v -n --line-numbers   # SNAT/MASQUERADE rules
iptables -t nat -F                                     # Flush all NAT rules
iptables -t nat -D POSTROUTING <N>                    # Delete rule by line number
```

### The three NAT operations
```bash
# MASQUERADE — dynamic SNAT (auto-detects outgoing IP)
iptables -t nat -A POSTROUTING -s 10.0.0.0/24 -o eth0 -j MASQUERADE

# SNAT — static source NAT (you specify the IP)
iptables -t nat -A POSTROUTING -s 10.0.0.0/24 -o eth0 -j SNAT --to-source 203.0.113.1

# DNAT — destination NAT / port forwarding
iptables -t nat -A PREROUTING -i eth0 -p tcp --dport 8080 -j DNAT --to-destination 10.0.0.5:80
```

### Debugging
```bash
sysctl net.ipv4.ip_forward                    # Is forwarding on?
conntrack -L                                   # View tracked connections
conntrack -E                                   # Watch connections live
conntrack -L | grep DNAT                       # Find DNAT'd connections
tcpdump -ni <iface> port <N>                  # Capture traffic
iptables -L FORWARD -v -n                     # Check FORWARD chain
```

### Mapping to roadmap checklist

After this lab you can:

| Checklist Item | Where You Practiced |
|----------------|---------------------|
| Build NAT gateway for a private subnet | Phase 3 (MASQUERADE) |
| Configure DNAT port-forward with correct return path | Phase 5 + 6 |
| Explain SNAT vs MASQUERADE | Phase 4 |
| Debug NAT with conntrack and tcpdump | Phase 8 |

**Next up:** Phase 5 of the roadmap — Cloud Reality (Security Groups, NACLs, and iptables layering).

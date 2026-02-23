# Iptables Hands-On Lab
> Practice firewall rules, stateful filtering, and network security on two VMs

## Table of Contents
1. [Lab Environment](#1-lab-environment) - VM roles and network layout
2. [Phase 1: Clean Slate](#2-phase-1-clean-slate) - Reset and understand defaults
3. [Phase 2: Base Hardening](#3-phase-2-base-hardening) - Essential foundation rules
4. [Phase 3: SSH Access Control](#4-phase-3-ssh-access-control) - Restrict remote access
5. [Phase 4: Stateful Filtering](#5-phase-4-stateful-filtering) - Connection tracking
6. [Phase 5: Service Rules](#6-phase-5-service-rules) - HTTP, HTTPS, DNS, ICMP
7. [Phase 6: Logging & Debugging](#7-phase-6-logging--debugging) - Troubleshoot dropped packets
8. [Phase 7: Rate Limiting](#8-phase-7-rate-limiting) - Brute-force protection
9. [Phase 8: Port Knocking (Bonus)](#9-phase-8-port-knocking-bonus) - Hidden SSH access
10. [Phase 9: Persistence](#10-phase-9-persistence) - Save and restore rules
11. [Verification Checklist](#11-verification-checklist) - Test everything works
12. [Cleanup](#12-cleanup) - Reset to open state

---

## 1. Lab Environment

```
┌─────────────────────┐         ┌─────────────────────┐
│  M (Master/Client)  │         │  W (Worker/Server)   │
│  192.168.11.104     │◄───────►│  192.168.11.108      │
│  Role: SSH client,  │   LAN   │  Role: SSH server,   │
│  test traffic src   │         │  web server, target   │
└─────────────────────┘         └─────────────────────┘
          ▲                               ▲
          │         ┌───────────┐         │
          └────────►│ Admin PC  │◄────────┘
                    │ 192.168.11.50       │
                    │ (always allowed)    │
                    └───────────┘
```

**Convention:** Run commands on the host shown in the prompt:
- `M#` = run on 192.168.11.104
- `W#` = run on 192.168.11.108

---

## 2. Phase 1: Clean Slate

Flush all rules and start fresh on **both hosts**.

```bash
# Run on BOTH M and W
iptables -F            # Flush all rules in all chains
iptables -X            # Delete user-defined chains
iptables -Z            # Zero packet/byte counters
iptables -P INPUT ACCEPT
iptables -P FORWARD ACCEPT
iptables -P OUTPUT ACCEPT
```

**Verify on both:**
```bash
iptables -L -v -n
```

**Expected:** All chains show policy ACCEPT, no rules, zero counters.

**Concept:** Before building a firewall, always start clean. The `-F` flag flushes
rules but does NOT reset policies — that's why we explicitly set ACCEPT first.

> **WARNING:** If you're remote, always set ACCEPT before flushing.
> Flushing with a DROP policy and no rules = you lock yourself out.

---

## 3. Phase 2: Base Hardening

These rules go on **both hosts** and form the foundation for everything else.

### Step 1 — Allow loopback

Many services (DNS resolver, databases, local sockets) talk over `lo`.

```bash
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT
```

**Test:**
```bash
ping -c 1 127.0.0.1       # Should work
resolvectl status          # DNS resolver uses 127.0.0.53
```

### Step 2 — Allow established/related connections

This is the most important rule in any stateful firewall. Without it,
you can receive new connections but return traffic gets dropped.

```bash
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
```

**Concept:** The kernel's connection tracking (conntrack) module keeps a table
of all active connections. This rule says: "if a packet belongs to a conversation
we already know about, let it in."

**Inspect the conntrack table:**
```bash
conntrack -L 2>/dev/null || cat /proc/net/nf_conntrack
```

### Step 3 — Set default DROP policy

```bash
iptables -P INPUT DROP
iptables -P FORWARD DROP
```

> OUTPUT stays ACCEPT — these are your machines, you trust outbound traffic.

**Verify on both:**
```bash
iptables -L -v -n
```

**Expected rules in order:**
1. ACCEPT on lo
2. ACCEPT ESTABLISHED,RELATED
3. Policy: DROP

**Test from admin PC (192.168.11.50):**
```bash
# This should FAIL now (no SSH rule yet)
ssh ubuntu@192.168.11.108
```

---

## 4. Phase 3: SSH Access Control

### On W (192.168.11.108) — Allow SSH from admin + M

```bash
W# iptables -A INPUT -p tcp -s 192.168.11.50 --dport 22 -j ACCEPT
W# iptables -A INPUT -p tcp -s 192.168.11.104 --dport 22 -j ACCEPT
```

### On M (192.168.11.104) — Allow SSH from admin only

```bash
M# iptables -A INPUT -p tcp -s 192.168.11.50 --dport 22 -j ACCEPT
```

### Test

```bash
# From admin PC → both should work
ssh ubuntu@192.168.11.104
ssh ubuntu@192.168.11.108

# From M → W should work (because of ESTABLISHED,RELATED + W's SSH rule)
M# ssh ubuntu@192.168.11.108

# From W → M should FAIL (M has no rule allowing SSH from W)
W# ssh ubuntu@192.168.11.104
```

**Concept:** Notice how M can SSH to W even though M only has an
ESTABLISHED,RELATED rule and a rule from .50. That's because:
- M's OUTPUT is ACCEPT → SYN goes out
- W's INPUT has a rule for .104 → SYN accepted
- W's OUTPUT is ACCEPT → SYN-ACK goes out
- M's INPUT ESTABLISHED,RELATED → SYN-ACK accepted (it's part of M's outbound connection)

---

## 5. Phase 4: Stateful Filtering

### Exercise: See connection tracking in action

**On W:**
```bash
W# watch -n 1 'conntrack -L 2>/dev/null | grep tcp || cat /proc/net/nf_conntrack | grep tcp'
```

**On M:** Open an SSH session to W:
```bash
M# ssh ubuntu@192.168.11.108
```

**Observe** the conntrack entry appear on W. You'll see something like:
```
tcp  6 431999 ESTABLISHED src=192.168.11.104 dst=192.168.11.108 sport=XXXXX dport=22
                          src=192.168.11.108 dst=192.168.11.104 sport=22 dport=XXXXX [ASSURED]
```

**Concept:** The `[ASSURED]` flag means traffic has been seen in both directions.
The conntrack module tracks: protocol, source/dest IP, source/dest port, state, timeout.

### Exercise: Difference between NEW, ESTABLISHED, RELATED

Add a rule that only accepts NEW SSH connections (not just any packet to port 22):

```bash
# On W — replace existing SSH rules with state-aware versions
W# iptables -D INPUT -p tcp -s 192.168.11.104 --dport 22 -j ACCEPT
W# iptables -A INPUT -p tcp -s 192.168.11.104 --dport 22 -m state --state NEW -j ACCEPT
```

**Test:** SSH from M to W should still work because:
- NEW packets (SYN) match the new rule
- Subsequent packets match ESTABLISHED,RELATED (rule #2)

---

## 6. Phase 5: Service Rules

### On W — Simulate a web server

```bash
W# python3 -m http.server 80 &
W# python3 -m http.server 443 &
```

### Allow HTTP/HTTPS from anyone on W

```bash
W# iptables -A INPUT -p tcp --dport 80 -j ACCEPT
W# iptables -A INPUT -p tcp --dport 443 -j ACCEPT
```

### Test from M

```bash
M# curl http://192.168.11.108
M# curl http://192.168.11.108:443
```

### Allow ICMP (ping) — both hosts

```bash
# On BOTH hosts
iptables -A INPUT -p icmp --icmp-type echo-request -j ACCEPT
iptables -A INPUT -p icmp --icmp-type echo-reply -j ACCEPT
```

**Test:**
```bash
M# ping -c 2 192.168.11.108    # Should work
W# ping -c 2 192.168.11.104    # Should work
```

### Allow DNS (if needed for outbound resolution)

DNS uses UDP 53. Since OUTPUT is ACCEPT and we have ESTABLISHED,RELATED,
outbound DNS already works. But if you ever set OUTPUT to DROP:

```bash
# Only needed if OUTPUT policy is DROP
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT
```

### Stop the web server when done

```bash
W# kill %1 %2
```

---

## 7. Phase 6: Logging & Debugging

### Create a LOG rule before the final DROP

Since INPUT policy is DROP, dropped packets are silent. Add logging:

```bash
# On BOTH hosts — append at the end (just before the implicit DROP)
iptables -A INPUT -j LOG --log-prefix "IPT-DROP: " --log-level 4
```

**Concept:** The LOG target is non-terminating — it logs and continues to the
next rule. Since there's no next rule, the packet hits the chain policy (DROP).

### Generate some dropped traffic and watch the log

```bash
# From M — try to connect to a blocked port on W
M# nc -zv 192.168.11.108 3306

# On W — check the log
W# dmesg | tail -5
# Or:
W# journalctl -k --since "1 min ago" | grep IPT-DROP
```

**Expected log entry:**
```
IPT-DROP: IN=ens18 OUT= SRC=192.168.11.104 DST=192.168.11.108 ...DPT=3306...
```

### Useful debugging commands

```bash
# List rules with line numbers (for inserting/deleting by position)
iptables -L INPUT -v -n --line-numbers

# Watch counters in real-time
watch -n 1 'iptables -L INPUT -v -n'

# Check conntrack table
conntrack -L
conntrack -E    # Live event monitoring
```

---

## 8. Phase 7: Rate Limiting

Protect SSH from brute-force attacks.

### On W — Add rate limit for SSH

First, remove the existing SSH rule from M and replace it:

```bash
# Delete old rule (check line number first)
W# iptables -L INPUT -v -n --line-numbers
W# iptables -D INPUT <line-number-of-104-ssh-rule>

# Add rate-limited version: max 3 new connections per minute from .104
W# iptables -A INPUT -p tcp -s 192.168.11.104 --dport 22 \
   -m state --state NEW \
   -m recent --set --name SSH_104

W# iptables -A INPUT -p tcp -s 192.168.11.104 --dport 22 \
   -m state --state NEW \
   -m recent --update --seconds 60 --hitcount 4 --name SSH_104 \
   -j DROP

W# iptables -A INPUT -p tcp -s 192.168.11.104 --dport 22 \
   -m state --state NEW -j ACCEPT
```

### Test from M

```bash
# Rapid SSH attempts — 4th one within 60s should be blocked
M# for i in 1 2 3 4 5; do echo "Attempt $i"; ssh -o ConnectTimeout=3 ubuntu@192.168.11.108 exit 2>&1; done
```

**Concept:** The `recent` module tracks source IPs. The rules say:
1. Record every NEW SSH connection from .104 in list "SSH_104"
2. If the same IP appears 4+ times in 60 seconds → DROP
3. Otherwise → ACCEPT

---

## 9. Phase 8: Port Knocking (Bonus)

Hide SSH behind a "knock sequence" — connect to ports 7000, 8000, 9000
in order before SSH opens.

### On W — Setup port knocking chains

```bash
# First, remove existing SSH rules for .104 (keep .50 rule for safety!)
W# iptables -L INPUT -v -n --line-numbers
# Delete SSH rules for .104 (NOT the .50 rule)

# Create knock chains
W# iptables -N KNOCK1
W# iptables -N KNOCK2
W# iptables -N KNOCK3

# Stage 1: Knock on port 7000 → move to stage 2
W# iptables -A KNOCK1 -p tcp --dport 7000 \
   -m recent --set --name KNOCK1 -j DROP

# Stage 2: Must have knocked on 7000, now knock on 8000
W# iptables -A KNOCK2 -p tcp --dport 8000 \
   -m recent --rcheck --seconds 10 --name KNOCK1 \
   -m recent --set --name KNOCK2 -j DROP

# Stage 3: Must have knocked on 8000, now knock on 9000
W# iptables -A KNOCK3 -p tcp --dport 9000 \
   -m recent --rcheck --seconds 10 --name KNOCK2 \
   -m recent --set --name KNOCK3 -j DROP

# SSH rule: Only allow if all 3 knocks completed
W# iptables -A INPUT -p tcp -s 192.168.11.104 --dport 22 \
   -m recent --rcheck --seconds 15 --name KNOCK3 -j ACCEPT

# Wire the knock chains into INPUT
W# iptables -A INPUT -p tcp -s 192.168.11.104 -j KNOCK1
W# iptables -A INPUT -p tcp -s 192.168.11.104 -j KNOCK2
W# iptables -A INPUT -p tcp -s 192.168.11.104 -j KNOCK3
```

### Test from M

```bash
# Knock sequence
M# nc -zw1 192.168.11.108 7000
M# nc -zw1 192.168.11.108 8000
M# nc -zw1 192.168.11.108 9000

# Now SSH should work (within 15 seconds of last knock)
M# ssh ubuntu@192.168.11.108
```

**Without knocking first, SSH will time out.**

> **⚠ Timing gotcha:** The `--seconds 10` windows between knocks are tight.
> Running each `nc` as a separate command with typing delay will cause the
> sequence to expire. Chain everything on one line:
> ```bash
> nc -zw1 <target> 7000; nc -zw1 <target> 8000; nc -zw1 <target> 9000; ssh user@<target>
> ```
> See [iptables-debug.md](iptables-debug.md#1-port-knocking-timeout) for full diagnosis.

---

## 10. Phase 9: Persistence

iptables rules live **only in kernel memory** — every reboot wipes them clean.
This phase ensures your carefully crafted rules survive restarts.

### The problem

```
Boot → kernel loads → netfilter initialized → ALL chains empty, policies ACCEPT
```

No matter what rules you added in Phases 2-8, a `reboot` resets everything.

### Step 1 — Snapshot your current rules

```bash
# On BOTH hosts — dump the entire ruleset to a file
iptables-save > /etc/iptables.rules
```

**Inspect the saved file:**
```bash
cat /etc/iptables.rules
```

You'll see your rules in `iptables-restore` format — this is NOT the same
format as `iptables -L`. It looks like:
```
*filter
:INPUT DROP [0:0]
:FORWARD DROP [0:0]
:OUTPUT ACCEPT [0:0]
-A INPUT -i lo -j ACCEPT
-A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
-A INPUT -p tcp -s 192.168.11.50 --dport 22 -j ACCEPT
...
COMMIT
```

**Concept:** `iptables-save` captures everything atomically — chains, policies,
rules, and custom chains. `iptables-restore` loads them back as one atomic
operation (no moment where you're half-configured).

### Step 2 — Choose a restore method

#### Option A — iptables-persistent (recommended for Ubuntu/Debian)

The simplest approach. A package that auto-restores on boot.

```bash
# On BOTH hosts
apt install iptables-persistent
```

During install it asks "Save current IPv4 rules?" → **Yes**
This saves to `/etc/iptables/rules.v4`.

**After ANY rule change, re-save:**
```bash
netfilter-persistent save
# Or manually:
iptables-save > /etc/iptables/rules.v4
```

**How it works under the hood:**
```
iptables-persistent (package)
  ↓ installs
netfilter-persistent.service (systemd unit)
  ↓ on boot, runs
iptables-restore < /etc/iptables/rules.v4
  ↓ loads rules into
kernel netfilter tables
```

**Verify the service:**
```bash
systemctl status netfilter-persistent
# Should show: loaded, enabled
```

**Test persistence:**
```bash
reboot
# After reboot:
iptables -L -v -n    # Rules should be back
```

#### Option B — systemd one-shot (manual, works anywhere)

If you don't want to install packages, create your own systemd service.

```bash
cat <<'EOF' > /etc/systemd/system/iptables-restore.service
[Unit]
Description=Restore iptables rules
Before=network-pre.target
Wants=network-pre.target

[Service]
Type=oneshot
ExecStart=/sbin/iptables-restore /etc/iptables.rules
ExecReload=/sbin/iptables-restore /etc/iptables.rules

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable iptables-restore.service
```

**After ANY rule change, re-save:**
```bash
iptables-save > /etc/iptables.rules
```

#### Option C — crontab @reboot (quick and dirty)

```bash
crontab -e
# Add this line:
@reboot /sbin/iptables-restore < /etc/iptables.rules
```

Works but has no guarantees about timing relative to network coming up.

### Common gotcha: forgetting to re-save

The #1 mistake with iptables persistence:

```
1. You save rules                    ✓ iptables-save > /etc/iptables.rules
2. You add/change rules in a session ✓ iptables -A INPUT ...
3. You reboot                        ✗ Changes from step 2 are LOST
```

**Rule of thumb:** After every rule change, run `iptables-save` again.
If using iptables-persistent: `netfilter-persistent save`.

### Verify persistence works

```bash
# 1. Check saved file matches current rules
diff <(iptables-save) /etc/iptables/rules.v4    # Option A
diff <(iptables-save) /etc/iptables.rules        # Option B

# 2. Reboot and verify
reboot
# After reboot:
iptables -L -v -n
```

---

## 11. Verification Checklist

Run these tests to confirm your firewall works correctly:

| # | Test | From | To | Expected |
|---|------|------|----|----------|
| 1 | SSH from admin | .50 | M (.104) | OK |
| 2 | SSH from admin | .50 | W (.108) | OK |
| 3 | SSH from M | .104 | W (.108) | OK |
| 4 | SSH from W | .108 | M (.104) | BLOCKED |
| 5 | Ping M → W | .104 | .108 | OK (if ICMP rule added) |
| 6 | Ping W → M | .108 | .104 | OK (if ICMP rule added) |
| 7 | HTTP to W | .104 | .108:80 | OK (if web rule added) |
| 8 | Random port | .104 | .108:3306 | BLOCKED + logged |
| 9 | apt update | W | internet | OK (ESTABLISHED,RELATED + lo) |
| 10 | Brute-force SSH | .104 | .108:22 | 4th attempt blocked |

---

## 12. Cleanup

To reset everything back to open:

```bash
# On BOTH hosts
iptables -F
iptables -X
iptables -Z
iptables -P INPUT ACCEPT
iptables -P FORWARD ACCEPT
iptables -P OUTPUT ACCEPT
```

---

## Quick Reference

```bash
iptables -L -v -n                        # List all rules with counters
iptables -L INPUT -v -n --line-numbers   # List with line numbers
iptables -I INPUT <N> ...                # Insert at position N
iptables -D INPUT <N>                    # Delete rule at position N
iptables -A INPUT ...                    # Append to end
iptables -F                              # Flush all rules
iptables -P INPUT DROP                   # Set default policy
iptables-save                            # Dump rules to stdout
iptables-restore < file                  # Load rules from file
conntrack -L                             # View connection table
conntrack -E                             # Watch connections live
```

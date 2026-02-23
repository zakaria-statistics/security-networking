# Packet Journey: Request and Response
> Follow a packet step-by-step through iptables, conntrack, and NAT

## Table of Contents
1. [Scenario 1: Direct (No NAT)](#scenario-1-direct-no-nat) - M → W on the same LAN
2. [Scenario 2: SNAT/MASQUERADE](#scenario-2-snatmasquerade) - Internal host → Internet
3. [Scenario 3: DNAT (Port Forwarding)](#scenario-3-dnat-port-forwarding) - Internet → Internal host

---

## Network Diagrams

### Scenario 1 — Direct
```
M (192.168.11.104)  ◄──── LAN ────►  W (192.168.11.108)
```

### Scenarios 2 & 3 — NAT
```
Internal Host        NAT Gateway              Remote Server
10.0.0.5        ──►  203.0.113.1  ──► Internet ──►  8.8.8.8
(private)             (public)                       (public)
```

---

## Scenario 1: Direct (No NAT)

**Action:** M (192.168.11.104) runs `ssh ubuntu@192.168.11.108`

---

### REQUEST: M → W

```
M's Kernel (192.168.11.104)
│
│  Step 1: Application creates socket
│  ssh connects to 192.168.11.108:22
│  Kernel assigns ephemeral port 44626
│
│  Step 2: Packet is constructed
│  ┌─────────────────────────────────────┐
│  │ src=192.168.11.104  sport=44626     │
│  │ dst=192.168.11.108  dport=22        │
│  │ flags=SYN                           │
│  └─────────────────────────────────────┘
│
│  Step 3: OUTPUT chain (M's iptables)
│  Policy: ACCEPT → packet passes
│
│  Step 4: conntrack creates NEW entry on M
│  ┌─────────────────────────────────────────────────┐
│  │ Original: .104:44626 → .108:22                  │
│  │ Reply:    .108:22 → .104:44626   (auto-flipped) │
│  │ State:    [NEW] [UNREPLIED]                      │
│  └─────────────────────────────────────────────────┘
│
│  Step 5: POSTROUTING chain → no NAT rules → pass
│
│  Step 6: Packet leaves M's network interface
│
───────────────── WIRE ─────────────────
│
│  Step 7: Packet arrives at W's network interface
│
W's Kernel (192.168.11.108)
│
│  Step 8: PREROUTING chain → no NAT rules → pass
│
│  Step 9: conntrack creates NEW entry on W
│  ┌─────────────────────────────────────────────────┐
│  │ Original: .104:44626 → .108:22                  │
│  │ Reply:    .108:22 → .104:44626   (auto-flipped) │
│  │ State:    [NEW] [UNREPLIED]                      │
│  └─────────────────────────────────────────────────┘
│
│  Step 10: Routing decision → destination is local → INPUT chain
│
│  Step 11: INPUT chain (W's iptables)
│  Rule: -p tcp -s 192.168.11.104 --dport 22 -j ACCEPT
│  ✓ Match → packet accepted
│
│  Step 12: Packet delivered to sshd process on port 22
```

---

### RESPONSE: W → M

```
W's Kernel (192.168.11.108)
│
│  Step 1: sshd sends SYN-ACK response
│  ┌─────────────────────────────────────┐
│  │ src=192.168.11.108  sport=22        │
│  │ dst=192.168.11.104  dport=44626     │
│  │ flags=SYN-ACK                       │
│  └─────────────────────────────────────┘
│
│  Step 2: OUTPUT chain → Policy: ACCEPT → pass
│
│  Step 3: conntrack updates entry on W
│  ┌─────────────────────────────────────────────────┐
│  │ Original: .104:44626 → .108:22                  │
│  │ Reply:    .108:22 → .104:44626                  │
│  │ State:    [NEW] → [ESTABLISHED] [ASSURED]       │
│  │           (traffic seen in both directions now)  │
│  └─────────────────────────────────────────────────┘
│
│  Step 4: POSTROUTING → no NAT → pass
│
│  Step 5: Packet leaves W's network interface
│
───────────────── WIRE ─────────────────
│
│  Step 6: Packet arrives at M's network interface
│
M's Kernel (192.168.11.104)
│
│  Step 7: PREROUTING → pass
│
│  Step 8: conntrack looks up the packet
│  src=.108:22 dst=.104:44626 → matches Reply tuple!
│  State updated: [NEW] → [ESTABLISHED] [ASSURED]
│
│  Step 9: Routing decision → destination is local → INPUT chain
│
│  Step 10: INPUT chain (M's iptables)
│  Rule: -m state --state ESTABLISHED,RELATED -j ACCEPT
│  conntrack says this packet is ESTABLISHED
│  ✓ Match → packet accepted
│
│  Step 11: Packet delivered to ssh client
│
│  *** TCP handshake complete, SSH session active ***
```

---

### What happens WITHOUT the ESTABLISHED,RELATED rule on M?

```
Step 10 FAILS:
  INPUT chain (M's iptables):
    Rule 1: -p tcp -s 192.168.11.50 --dport 22 -j ACCEPT
            src=.108? NO. dport=44626? NO. → no match
    No more rules → Policy: DROP
    ✗ SYN-ACK dropped silently
    ✗ SSH hangs → "Connection timed out"
```

This is exactly the problem you hit earlier.

---

## Scenario 2: SNAT/MASQUERADE

**Action:** Internal host (10.0.0.5) runs `curl https://8.8.8.8`

**NAT Gateway rule:**
```bash
iptables -t nat -A POSTROUTING -s 10.0.0.0/24 -o eth0 -j MASQUERADE
```

---

### REQUEST: Internal → Internet

```
Internal Host (10.0.0.5)
│
│  Step 1: curl creates socket
│  ┌─────────────────────────────────────┐
│  │ src=10.0.0.5    sport=51234         │
│  │ dst=8.8.8.8     dport=443           │
│  │ flags=SYN                           │
│  └─────────────────────────────────────┘
│
│  Step 2: OUTPUT → ACCEPT, conntrack creates entry
│  Step 3: Packet leaves internal host
│
───────────────── Internal Network ─────────────────
│
NAT Gateway (10.0.0.1 internal / 203.0.113.1 public)
│
│  Step 4: Packet arrives on internal interface
│
│  Step 5: PREROUTING chain (nat table) → no DNAT rules → pass
│
│  Step 6: conntrack creates NEW entry
│  ┌─────────────────────────────────────────────────┐
│  │ Original: 10.0.0.5:51234 → 8.8.8.8:443         │
│  │ Reply:    8.8.8.8:443 → 10.0.0.5:51234          │
│  │ State:    [NEW] [UNREPLIED]                      │
│  └─────────────────────────────────────────────────┘
│
│  Step 7: Routing decision → not local → FORWARD chain
│  FORWARD: ACCEPT → pass
│
│  Step 8: POSTROUTING chain (nat table)
│  Rule: -s 10.0.0.0/24 -o eth0 -j MASQUERADE
│  ✓ Match!
│
│  Step 9: NAT rewrites the packet AND the conntrack reply tuple
│
│  Packet is rewritten:
│  ┌─────────────────────────────────────┐
│  │ src=203.0.113.1  sport=51234        │  ← src changed!
│  │ dst=8.8.8.8      dport=443          │
│  │ flags=SYN                           │
│  └─────────────────────────────────────┘
│
│  conntrack entry updated:
│  ┌─────────────────────────────────────────────────────┐
│  │ Original: 10.0.0.5:51234 → 8.8.8.8:443             │
│  │ Reply:    8.8.8.8:443 → 203.0.113.1:51234           │
│  │                          ^^^^^^^^^^^^^               │
│  │                          rewritten! (was 10.0.0.5)   │
│  │ State:    [NEW] [UNREPLIED]                          │
│  └─────────────────────────────────────────────────────┘
│
│  Step 10: Packet leaves public interface
│
───────────────── Internet ─────────────────
│
│  Step 11: Packet arrives at 8.8.8.8
│  Server sees src=203.0.113.1 (has no idea about 10.0.0.5)
```

---

### RESPONSE: Internet → Internal

```
Remote Server (8.8.8.8)
│
│  Step 1: Server sends SYN-ACK
│  ┌─────────────────────────────────────┐
│  │ src=8.8.8.8      sport=443          │
│  │ dst=203.0.113.1  dport=51234        │  ← replies to public IP
│  │ flags=SYN-ACK                       │
│  └─────────────────────────────────────┘
│
───────────────── Internet ─────────────────
│
NAT Gateway (203.0.113.1)
│
│  Step 2: Packet arrives on public interface
│
│  Step 3: PREROUTING → conntrack lookup
│  src=8.8.8.8:443 dst=203.0.113.1:51234
│  Matches Reply tuple! → ESTABLISHED
│
│  Step 4: conntrack reverses the NAT automatically
│  (NAT rules are NOT consulted again — only first packet uses them)
│
│  Packet is rewritten:
│  ┌─────────────────────────────────────┐
│  │ src=8.8.8.8   sport=443             │
│  │ dst=10.0.0.5  dport=51234           │  ← dst restored to private!
│  │ flags=SYN-ACK                       │
│  └─────────────────────────────────────┘
│
│  Step 5: Routing decision → dst=10.0.0.5 → internal network → FORWARD
│  FORWARD: ESTABLISHED,RELATED → ACCEPT
│
│  Step 6: POSTROUTING → no rewrite needed (already handled)
│
│  Step 7: Packet leaves internal interface
│
───────────────── Internal Network ─────────────────
│
│  Step 8: Packet arrives at 10.0.0.5
│  curl receives SYN-ACK from 8.8.8.8 → connection established
```

---

### Key Point: NAT Only Runs Once

```
Packet 1 (SYN):     NAT rule evaluated → conntrack entry created + rewritten
Packet 2 (SYN-ACK): conntrack handles translation → NAT rule SKIPPED
Packet 3 (ACK):     conntrack handles translation → NAT rule SKIPPED
Packet 4 (data):    conntrack handles translation → NAT rule SKIPPED
...
Packet N:           conntrack handles translation → NAT rule SKIPPED

NAT rules are only consulted for the FIRST packet.
Every subsequent packet is translated using the stored conntrack tuples.
```

---

## Scenario 3: DNAT (Port Forwarding)

**Action:** External client connects to the gateway's public IP on port 8080,
forwarded to internal web server 10.0.0.5:80

**NAT Gateway rules:**
```bash
iptables -t nat -A PREROUTING -i eth0 -p tcp --dport 8080 -j DNAT --to 10.0.0.5:80
iptables -t nat -A POSTROUTING -s 10.0.0.0/24 -o eth0 -j MASQUERADE
```

---

### REQUEST: Internet → Internal

```
External Client (1.2.3.4)
│
│  Step 1: Client connects to public IP
│  ┌─────────────────────────────────────┐
│  │ src=1.2.3.4      sport=60000        │
│  │ dst=203.0.113.1  dport=8080         │  ← public IP, port 8080
│  │ flags=SYN                           │
│  └─────────────────────────────────────┘
│
───────────────── Internet ─────────────────
│
NAT Gateway (203.0.113.1)
│
│  Step 2: Packet arrives on public interface
│
│  Step 3: PREROUTING chain (nat table)
│  Rule: -i eth0 -p tcp --dport 8080 -j DNAT --to 10.0.0.5:80
│  ✓ Match!
│
│  Step 4: conntrack creates entry + DNAT rewrites
│
│  Packet is rewritten:
│  ┌─────────────────────────────────────┐
│  │ src=1.2.3.4   sport=60000           │
│  │ dst=10.0.0.5  dport=80              │  ← dst changed!
│  │ flags=SYN                           │
│  └─────────────────────────────────────┘
│
│  conntrack entry:
│  ┌───────────────────────────────────────────────────────┐
│  │ Original: 1.2.3.4:60000 → 203.0.113.1:8080           │
│  │ Reply:    10.0.0.5:80 → 1.2.3.4:60000                │
│  │           ^^^^^^^^^^                                   │
│  │           NOT 203.0.113.1:8080 (rewritten by DNAT)    │
│  └───────────────────────────────────────────────────────┘
│
│  Step 5: Routing decision → dst=10.0.0.5 → FORWARD chain
│  FORWARD: ACCEPT → pass
│
│  Step 6: POSTROUTING → packet goes to internal network
│
│  Step 7: Packet arrives at 10.0.0.5:80
│  Web server sees src=1.2.3.4 (knows the real client IP)
```

---

### RESPONSE: Internal → Internet

```
Internal Web Server (10.0.0.5)
│
│  Step 1: Web server sends SYN-ACK
│  ┌─────────────────────────────────────┐
│  │ src=10.0.0.5  sport=80              │
│  │ dst=1.2.3.4   dport=60000           │
│  │ flags=SYN-ACK                       │
│  └─────────────────────────────────────┘
│
───────────────── Internal Network ─────────────────
│
NAT Gateway
│
│  Step 2: Packet arrives on internal interface
│
│  Step 3: conntrack lookup
│  src=10.0.0.5:80 dst=1.2.3.4:60000
│  Matches Reply tuple! → ESTABLISHED
│
│  Step 4: conntrack reverses the DNAT automatically
│
│  Packet is rewritten:
│  ┌─────────────────────────────────────────┐
│  │ src=203.0.113.1  sport=8080             │  ← src restored to public IP!
│  │ dst=1.2.3.4      dport=60000            │
│  │ flags=SYN-ACK                           │
│  └─────────────────────────────────────────┘
│
│  Step 5: Routing → FORWARD → POSTROUTING → out public interface
│
───────────────── Internet ─────────────────
│
│  Step 6: Packet arrives at 1.2.3.4
│  Client sees response from 203.0.113.1:8080
│  (has no idea about 10.0.0.5)
```

---

## Summary: Where Things Happen

```
                        INCOMING PACKET
                              │
                              ▼
                     ┌─────────────────┐
                     │   PREROUTING    │ ← DNAT happens here
                     │   (nat table)   │
                     │   + conntrack   │ ← entry created/looked up
                     └────────┬────────┘
                              │
                      Routing Decision
                     /                \
                    ▼                  ▼
           ┌──────────────┐    ┌──────────────┐
           │    INPUT     │    │   FORWARD    │
           │  (local dst) │    │ (passing thru)│
           └──────┬───────┘    └──────┬───────┘
                  │                   │
                  ▼                   ▼
           Local Process       ┌──────────────┐
                  │            │  POSTROUTING  │ ← SNAT/MASQUERADE here
                  ▼            │  (nat table)  │
           ┌──────────────┐    └──────┬───────┘
           │    OUTPUT    │           │
           └──────┬───────┘           ▼
                  │            Packet leaves
                  ▼
           ┌──────────────┐
           │  POSTROUTING │
           └──────┬───────┘
                  │
                  ▼
           Packet leaves
```

### The conntrack + NAT relationship:
- **conntrack** = the tracking system (always active, tracks ALL connections)
- **NAT** = a consumer of conntrack (modifies the reply tuple on first packet only)
- **Same table** = NAT doesn't have its own table, it reuses conntrack entries
- **First packet only** = NAT rules run once, conntrack handles every subsequent packet

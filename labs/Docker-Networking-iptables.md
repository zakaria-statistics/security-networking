# Docker Networking & iptables Deep Dive (v27+)
> How Docker programs the Linux kernel to route, isolate, and NAT container traffic

## Table of Contents
1. [Fundamentals: Bridge vs Router](#1-fundamentals-bridge-vs-router) - What docker0 actually is
2. [Two Custom Bridges Architecture](#2-two-custom-bridges-architecture) - How multiple networks work
3. [The Router Component Explained](#3-the-router-component-explained) - ip_forward + routing table + iptables
4. [Routing Tables on Every Machine](#4-routing-tables-on-every-machine) - Not just for routers
5. [Special IP Addresses](#5-special-ip-addresses) - 0.0.0.0, broadcast, multicast, anycast
6. [Netfilter: Kernel-Level Packet Processing](#6-netfilter-kernel-level-packet-processing) - Where rules live
7. [Docker and Kubernetes: Rule Generators](#7-docker-and-kubernetes-rule-generators) - High-level to low-level
8. [Kernel Modules for Container Networking](#8-kernel-modules-for-container-networking) - overlay and br_netfilter
9. [Docker + iptables: How Docker Talks to the Kernel](#9-docker--iptables-how-docker-talks-to-the-kernel) - netlink interface
10. [The v27 Chain Architecture](#10-the-v27-chain-architecture) - New filter table design
11. [Actual iptables Rules Docker Creates](#11-actual-iptables-rules-docker-creates) - What runs on your system
12. [Packet Flow Examples](#12-packet-flow-examples) - End-to-end traces through v27 chains
13. [Summary and Reference Tables](#13-summary-and-reference-tables) - Quick reference

---

## 1. Fundamentals: Bridge vs Router

### The Core Question

Is Docker's bridge (docker0) a router or a switch?

### The Answer

**A Docker bridge is a Layer 2 switch, not a router.**

It forwards Ethernet frames based on MAC addresses within a single subnet. It has no understanding of IP addresses or routing decisions.

```
┌──────────────────────────────────────────────────────────┐
│                                                          │
│  Layer 2 Switch              vs        Layer 3 Router   │
│  ────────────────                      ───────────────   │
│                                                          │
│  • Forwards frames based               • Forwards packets│
│    on MAC addresses                      based on IPs   │
│                                                          │
│  • Operates within single              • Connects        │
│    broadcast domain                      different       │
│                                          networks        │
│                                                          │
│  • No IP routing decisions             • Makes routing   │
│                                          decisions       │
│                                                          │
└──────────────────────────────────────────────────────────┘
```

### Where Routing Happens

The Linux host itself acts as the router. The `docker0` bridge connects containers, but the host's network stack routes traffic between different networks.

```
Your LAN (192.168.11.0/24)
        │
        │ eth0: 192.168.11.x
   ┌────┴────┐
   │  HOST   │ ◄── Linux kernel does NAT/routing here
   └────┬────┘
        │ docker0: 172.17.0.1  ◄── Gateway IP on the bridge
        │
   ┌────┴────┐  (Layer 2 bridge/switch)
   │ docker0 │
   └─┬────┬──┘
     │    │
  ┌──┴┐  ┌┴──┐
  │C1 │  │C2 │   Containers: 172.17.0.2, 172.17.0.3
  └───┘  └───┘
```

### Key Insight

- **docker0** = virtual switch (Layer 2)
- **172.17.0.1** = IP address assigned to that switch interface on the host, acting as the default gateway for containers
- **iptables/NAT** on the host = the actual routing between 172.17.x.x and 192.168.11.x

---

## 2. Two Custom Bridges Architecture

When you create two custom bridges, you're creating **two separate Layer 2 switches**, each with its own subnet. The host's network stack becomes the router connecting everything.

```
                    Your Physical LAN
                   192.168.11.0/24
                          │
                          │ eth0: 192.168.11.50 (example)
                          │
              ┌───────────┴───────────┐
              │                       │
              │     LINUX HOST        │
              │                       │
              │  ┌─────────────────┐  │
              │  │                 │  │
              │  │  ROUTER         │  │
              │  │  (iptables +    │  │
              │  │   IP forwarding)│  │
              │  │                 │  │
              │  └───┬─────────┬───┘  │
              │      │         │      │
              │      │         │      │
              │ ┌────┴───┐ ┌───┴────┐ │
              │ │10.10.0.1│ │10.20.0.1│ │
              │ │ (gw)   │ │ (gw)   │ │
              └─┼────────┼─┼────────┼─┘
                │        │ │        │
         ┌──────┴──────┐ │ │ ┌──────┴──────┐
         │             │ │ │ │             │
         │  BRIDGE A   │ │ │ │  BRIDGE B   │
         │  (switch)   │ │ │ │  (switch)   │
         │             │ │ │ │             │
         │ 10.10.0.0/24│ │ │ │ 10.20.0.0/24│
         │             │ │ │ │             │
         └──────┬──────┘ │ │ └──────┬──────┘
                │        │ │        │
           ┌────┴────┐   │ │   ┌────┴────┐
           │Container│   │ │   │Container│
           │    A    │   │ │   │    B    │
           │10.10.0.2│   │ │   │10.20.0.2│
           └─────────┘   │ │   └─────────┘
                         │ │
                    (no direct path)
```

### Traffic Flow: Container A to Container B

```
Container A (10.10.0.2)
    │
    │ Packet: src=10.10.0.2, dst=10.20.0.2
    │ "Destination not in my subnet, send to gateway"
    │
    ▼
Bridge A (switch)
    │
    │ Forwards frame to gateway MAC
    │
    ▼
Host Interface on Bridge A (10.10.0.1)
    │
    │ Packet enters host's network stack
    │
    ▼
ROUTER (iptables + ip_forward)
    │
    │ "10.20.0.2 is reachable via Bridge B interface"
    │ Forwards packet to 10.20.0.1 interface
    │
    ▼
Host Interface on Bridge B (10.20.0.1)
    │
    │ Packet exits toward Bridge B
    │
    ▼
Bridge B (switch)
    │
    │ Forwards frame to Container B's MAC
    │
    ▼
Container B (10.20.0.2)
```

### Why Isolation Exists by Default

With two custom bridges, Docker's iptables rules block packets between Bridge A and Bridge B. This is intentional security segmentation enforced by the `DOCKER-INTERNAL` chain (v27+).

---

## 3. The Router Component Explained

When people say "the router is iptables + ip_forward," they mean three things working together:

### 1. ip_forward (The Capability)

A simple kernel parameter. A boolean. Either the kernel will forward packets between interfaces or it will not.

```
┌─────────────────────────────────────────────────────────────┐
│                                                             │
│  ip_forward = 0                                             │
│                                                             │
│  Packet arrives dst=8.8.8.8                                 │
│           │                                                 │
│           ▼                                                 │
│    "Is this my IP?" ──► NO                                  │
│           │                                                 │
│           ▼                                                 │
│       DROP IT                                               │
│                                                             │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│                                                             │
│  ip_forward = 1 (Docker host)                               │
│                                                             │
│  Packet arrives dst=8.8.8.8                                 │
│           │                                                 │
│           ▼                                                 │
│    "Is this my IP?" ──► NO                                  │
│           │                                                 │
│           ▼                                                 │
│    Consult routing table                                    │
│    "8.8.8.8 matches 0.0.0.0/0 → send via eth0"              │
│           │                                                 │
│           ▼                                                 │
│    FORWARD IT                                               │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### 2. Routing Table (The Directions)

Once forwarding is permitted, the kernel consults its routing table to determine which interface to use.

```
Destination        Gateway         Interface
─────────────────────────────────────────────
10.10.0.0/24       0.0.0.0         bridge_a    ← 0.0.0.0 = directly connected
10.20.0.0/24       0.0.0.0         bridge_b    ← host IS the gateway
0.0.0.0/0          192.168.11.1    eth0        ← default route
```

### 3. iptables (The Policy Enforcer and Modifier)

**Filtering**: Before or after the routing decision, iptables can inspect the packet and decide whether to allow it, drop it, or reject it.

**NAT**: When a container talks to the outside world, iptables rewrites the source IP to the host's IP (masquerade).

### How They Interact

```
Packet arrives at host
         │
         ▼
   ┌─────────────┐
   │ ip_forward  │──── disabled ────► DROPPED
   │  enabled?   │
   └──────┬──────┘
          │ yes
          ▼
   ┌─────────────┐
   │  iptables   │──── DROP rule ────► DROPPED
   │  FORWARD    │
   │   chain     │
   └──────┬──────┘
          │ allowed
          ▼
   ┌─────────────┐
   │  Routing    │
   │   Table     │──── "use bridge_b interface"
   │  lookup     │
   └──────┬──────┘
          │
          ▼
   ┌─────────────┐
   │  iptables   │
   │    NAT      │──── rewrite if needed
   │ POSTROUTING │
   └──────┬──────┘
          │
          ▼
    Packet exits via
    correct interface
```

---

## 4. Routing Tables on Every Machine

A routing table is not exclusive to routers. **Every device with a network stack has one**.

```
┌─────────────────────────────────────────────────────────────┐
│                                                             │
│  YOUR LAPTOP'S ROUTING TABLE                                │
│                                                             │
│  Destination        Gateway         Interface               │
│  ─────────────────────────────────────────────              │
│  192.168.11.0/24    0.0.0.0         eth0   (local network)  │
│  0.0.0.0/0          192.168.11.1    eth0   (default route)  │
│                                                             │
│  Translation:                                               │
│  • "To reach 192.168.11.x, send directly out eth0"          │
│  • "To reach anything else, send to 192.168.11.1 (router)"  │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### Endpoint vs Router

| Device | Has Routing Table? | ip_forward? | Uses Table For |
|--------|-------------------|-------------|----------------|
| Your laptop | Yes | 0 (disabled) | Own outgoing traffic only |
| Docker host | Yes | 1 (enabled) | Own traffic + forwarding container traffic |
| Container | Yes | 0 (usually) | Own outgoing traffic only |
| Physical router | Yes | 1 (enabled) | Forwarding everyone's traffic |

---

## 5. Special IP Addresses

### The Two 0.0.0.0 Meanings

```
Destination        Gateway         Interface
─────────────────────────────────────────────
192.168.11.0/24    0.0.0.0         eth0
0.0.0.0/0          192.168.11.1    eth0
```

**Gateway 0.0.0.0** = "No gateway needed, send directly"
The destination is on my local network.

**Destination 0.0.0.0/0** = "Match everything"
This is the default route.

### Quick Reference

| Address | Meaning |
|---------|---------|
| 0.0.0.0 | "Any" or "none" depending on context |
| 127.0.0.1 | Localhost (loopback) |
| 255.255.255.255 | Broadcast to everyone on local network |
| 224.0.0.0/4 | Multicast range (one-to-many) |
| Anycast | Same IP advertised from multiple locations, routed to nearest |

```
UNICAST:      One sender → One receiver
BROADCAST:    One sender → Everyone on local network
MULTICAST:    One sender → Specific group who subscribed
ANYCAST:      One sender → Nearest node sharing same IP
```

---

## 6. Netfilter: Kernel-Level Packet Processing

Netfilter is not a process, not a VM, and not tied to any single network interface. It lives inside the **Linux kernel itself**.

```
┌─────────────────────────────────────────────────────────────┐
│                      USER SPACE                             │
│                                                             │
│   ┌─────────┐  ┌─────────┐  ┌─────────┐  ┌──────────┐     │
│   │ Process │  │ Process │  │ Docker  │  │ iptables │     │
│   │    A    │  │    B    │  │  daemon │  │ command  │     │
│   └────┬────┘  └────┬────┘  └────┬────┘  └────┬─────┘     │
│        │            │            │             │           │
├────────┼────────────┼────────────┼─────────────┼───────────┤
│        ▼            ▼            ▼             ▼           │
│   ┌─────────────────────────────────────────────────┐     │
│   │                 LINUX KERNEL                    │     │
│   │   ┌─────────────────────────────────────────┐   │     │
│   │   │              NETFILTER                  │   │     │
│   │   │  Hooks into the kernel's network stack  │   │     │
│   │   │  Inspects EVERY packet flowing through  │   │     │
│   │   └─────────────────────────────────────────┘   │     │
│   └─────────────────────────────────────────────────┘     │
│                      KERNEL SPACE                           │
└─────────────────────────────────────────────────────────────┘
```

| Component | What It Is | Where It Lives |
|-----------|------------|----------------|
| Netfilter | Kernel framework with hooks | Inside the kernel |
| iptables | User-space command to configure Netfilter | User space |
| nftables | Newer user-space command (replaces iptables) | User space |
| Rules/chains | Configuration stored in kernel memory | Kernel memory |

---

## 7. Docker and Kubernetes: Rule Generators

The kernel does not understand containers or pods. It only understands packets, interfaces, and rules.

**Docker and Kubernetes are just rule generators.** They translate high-level concepts into low-level Netfilter rules.

```
┌─────────────────────────────────────────────────────────────┐
│  USER SPACE                                                 │
│                                                             │
│  ┌───────────┐  ┌───────────┐  ┌───────────────┐           │
│  │  Docker   │  │  kubelet  │  │  kube-proxy   │           │
│  │  daemon   │  │           │  │               │           │
│  └─────┬─────┘  └─────┬─────┘  └───────┬───────┘           │
│        ▼              ▼                ▼                    │
│  ┌─────────────────────────────────────────────┐           │
│  │   "Please create these rules and chains"    │           │
│  │   - DOCKER-FORWARD chain                    │           │
│  │   - KUBE-SERVICES chain                     │           │
│  │   - NAT rules for service IPs               │           │
│  └──────────────────────┬──────────────────────┘           │
├─────────────────────────┼───────────────────────────────────┤
│                         ▼                                   │
│  ┌─────────────────────────────────────────────┐           │
│  │  LINUX KERNEL — only sees rules and chains  │           │
│  └─────────────────────────────────────────────┘           │
└─────────────────────────────────────────────────────────────┘
```

| High-Level Concept | What Gets Created |
|--------------------|-------------------|
| Docker bridge network | Bridge interface + DOCKER-FORWARD chain |
| Container port publish (-p 8080:80) | DNAT in nat/DOCKER + ACCEPT in filter/DOCKER |
| Kubernetes Service (ClusterIP) | KUBE-SERVICES chain with DNAT to pod IPs |
| Kubernetes NetworkPolicy | CNI chain rules (e.g., cali-* for Calico) |
| Pod-to-external traffic | Masquerade rule to hide pod IP |

---

## 8. Kernel Modules for Container Networking

### overlay

Required for container image layers to work.

```
CONTAINER IMAGE LAYERS
  ┌─────────────────┐
  │  Layer 3: App   │  (your code)
  ├─────────────────┤
  │  Layer 2: Deps  │  (npm install, pip install)
  ├─────────────────┤
  │  Layer 1: Base  │  (ubuntu, alpine)
  └─────────────────┘
  Overlay filesystem merges these into ONE view
```

### br_netfilter

Allows iptables to process bridged network traffic.

```
WITHOUT br_netfilter:
  Container A ────► Bridge ────► Container B
                      │
                      X  iptables never sees this

WITH br_netfilter:
  Container A ────► Bridge ────► Container B
                      │
                      ▼
                  iptables
```

### Required Sysctl Settings

```bash
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
```

---

## 9. Docker + iptables: How Docker Talks to the Kernel

Docker uses the **netlink** interface to write rules into the kernel.

```
DOCKER DAEMON
  └── libnetwork (Docker's networking library)
        └── go-iptables library (executes iptables commands)
              └── NETLINK SOCKET (NETLINK_NETFILTER)
                    └── KERNEL: Netfilter subsystem
                          (receives rules, stores in memory, enforces on every packet)
```

### The Tables Docker Uses

| Table | Purpose | Docker Uses |
|-------|---------|-------------|
| raw | Mark packets to skip connection tracking | Rarely |
| mangle | Modify packet headers (TTL, TOS, marks) | Rarely |
| nat | Rewrite source or destination addresses | Heavily |
| filter | Accept, drop, or reject packets | Heavily |

---

## 10. The v27 Chain Architecture

Docker v27 redesigned the filter table chain structure. The old `DOCKER-ISOLATION-STAGE-1` and `DOCKER-ISOLATION-STAGE-2` chains are gone. The new architecture is cleaner and each chain has a single, well-defined responsibility.

> **Pre-v27 note:** Older Docker versions used `DOCKER-ISOLATION-STAGE-1` and `DOCKER-ISOLATION-STAGE-2` for cross-network isolation and added several rules directly into the FORWARD chain. If you SSH into an older server you may still see those chains.

### The New Chain Hierarchy (filter table)

```
FORWARD
  ├── DOCKER-USER        (your custom rules — evaluated first, never touched by Docker)
  └── DOCKER-FORWARD     (Docker's main dispatch chain)
        ├── DOCKER-CT        (return traffic: RELATED,ESTABLISHED → ACCEPT)
        ├── DOCKER-INTERNAL  (cross-network isolation DROP rules)
        ├── DOCKER-BRIDGE    (inbound to containers → calls DOCKER)
        │     └── DOCKER     (per-container rules + default DROP)
        └── ACCEPT           (container egress: in=docker0 → ACCEPT)
```

### What Each Chain Does

```
┌─────────────────────────────────────────────────────────────────┐
│ DOCKER-CT                                                       │
│                                                                 │
│  ACCEPT  all  *  docker0  ctstate RELATED,ESTABLISHED           │
│                                                                 │
│  "If packet is going TO docker0 AND belongs to an               │
│   existing connection → allow it (return traffic)"              │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│ DOCKER-INTERNAL                                                 │
│                                                                 │
│  (empty when only default bridge)                               │
│  When custom networks exist, Docker adds DROP rules here        │
│  to prevent traffic crossing between different bridges.         │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│ DOCKER-BRIDGE                                                   │
│                                                                 │
│  DOCKER  all  *  docker0                                        │
│                                                                 │
│  "If packet is going TO docker0 → check per-container rules"    │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│ DOCKER                                                          │
│                                                                 │
│  (ACCEPT rules for published ports — added here per container)  │
│  DROP  all  !docker0  docker0                                   │
│                                                                 │
│  "External traffic arriving at docker0 is denied by default"    │
│  "Published ports add ACCEPT rules BEFORE this DROP"            │
│                                                                 │
│  Note: The DROP matches !docker0 → docker0                      │
│  Container-to-container (docker0 → docker0) does NOT match      │
│  because in=docker0 fails the !docker0 condition                │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│ Final ACCEPT in DOCKER-FORWARD                                  │
│                                                                 │
│  ACCEPT  all  docker0  *                                        │
│                                                                 │
│  "If packet came FROM docker0 (container egress) → allow it"   │
│  This fires for: container → internet, container → container    │
│  (both have in=docker0 and don't hit the DROP in DOCKER)        │
└─────────────────────────────────────────────────────────────────┘
```

### The DROP Rule's Precision

The DROP in DOCKER is deliberately scoped:

```
DROP  !docker0 → docker0
= "came from outside, going into a container"
= default-deny for inbound external traffic

Does NOT match:
  docker0 → docker0  (container-to-container — in IS docker0)
  docker0 → eth0     (container egress — out is NOT docker0)
```

This is why container-to-container and outbound traffic still work without any published port.

### Traffic Decision Table

| Traffic direction | in= | out= | Path through DOCKER-FORWARD | Result |
|---|---|---|---|---|
| External → Container (no port published) | eth0 | docker0 | CT(miss) → INTERNAL(miss) → BRIDGE → DOCKER(DROP) | **DROP** |
| External → Container (port published) | eth0 | docker0 | CT(miss) → INTERNAL(miss) → BRIDGE → DOCKER(ACCEPT) | **ACCEPT** |
| Return traffic → Container | eth0 | docker0 | CT(ACCEPT — ESTABLISHED) | **ACCEPT** |
| Container → External | docker0 | eth0 | CT(miss) → INTERNAL(miss) → BRIDGE(miss, out≠docker0) → ACCEPT | **ACCEPT** |
| Container ↔ Container (same bridge) | docker0 | docker0 | CT(ACCEPT if established) or BRIDGE → DOCKER(DROP misses — in=docker0) → ACCEPT | **ACCEPT** |
| Container A → Container B (different networks) | br-A | br-B | INTERNAL(DROP) | **DROP** |

---

## 11. Actual iptables Rules Docker Creates

### On Daemon Start (No Containers Running)

**nat table:**

```bash
# Create the DOCKER chain in nat
iptables -t nat -N DOCKER

# Redirect inbound traffic destined for a local IP into DOCKER chain (for DNAT)
iptables -t nat -A PREROUTING -m addrtype --dst-type LOCAL -j DOCKER

# Same for locally-generated traffic (excludes loopback)
iptables -t nat -A OUTPUT ! -d 127.0.0.0/8 -m addrtype --dst-type LOCAL -j DOCKER

# Masquerade container traffic leaving via any interface except docker0
iptables -t nat -A POSTROUTING -s 172.17.0.0/16 ! -o docker0 -j MASQUERADE
```

**filter table:**

```bash
# Create all Docker chains
iptables -N DOCKER
iptables -N DOCKER-BRIDGE
iptables -N DOCKER-CT
iptables -N DOCKER-FORWARD
iptables -N DOCKER-INTERNAL
iptables -N DOCKER-USER

# FORWARD: hand off to user rules first, then Docker's dispatch chain
iptables -A FORWARD -j DOCKER-USER
iptables -A FORWARD -j DOCKER-FORWARD

# DOCKER-FORWARD: ordered dispatch
iptables -A DOCKER-FORWARD -j DOCKER-CT        # return traffic first
iptables -A DOCKER-FORWARD -j DOCKER-INTERNAL  # isolation check
iptables -A DOCKER-FORWARD -j DOCKER-BRIDGE    # inbound-to-container check
iptables -A DOCKER-FORWARD -i docker0 -j ACCEPT # container egress

# DOCKER-CT: allow return traffic going to docker0
iptables -A DOCKER-CT -o docker0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

# DOCKER-BRIDGE: dispatch to per-container rules for traffic going to docker0
iptables -A DOCKER-BRIDGE -o docker0 -j DOCKER

# DOCKER: default-deny for external-inbound (pre-v27 used DOCKER-ISOLATION for this)
iptables -A DOCKER ! -i docker0 -o docker0 -j DROP

# DOCKER-USER: empty — your rules go here
# (Docker adds a RETURN at the end; your rules go before it)
```

### On Container Start with Published Port

```bash
docker run -d -p 8080:80 --name web nginx
# Container IP: 172.17.0.2
```

Docker adds to **nat/DOCKER**:
```bash
# DNAT: rewrite external traffic arriving on port 8080 to container:80
iptables -t nat -A DOCKER ! -i docker0 -p tcp --dport 8080 \
    -j DNAT --to-destination 172.17.0.2:80

# Hairpin: container reaching its own published port via localhost
iptables -t nat -A POSTROUTING -s 172.17.0.2 -d 172.17.0.2 \
    -p tcp --dport 80 -j MASQUERADE
```

Docker adds to **filter/DOCKER** (before the DROP):
```bash
# ACCEPT for published port — inserted BEFORE the DROP rule
iptables -I DOCKER -d 172.17.0.2 ! -i docker0 -o docker0 \
    -p tcp --dport 80 -j ACCEPT
```

**Result — DOCKER chain now looks like:**
```
1  ACCEPT  tcp  !docker0  docker0  dst=172.17.0.2  dport=80   ← published port
2  DROP    all  !docker0  docker0                              ← default deny
```

### On Custom Network Creation

```bash
docker network create --subnet 10.10.0.0/24 frontend
# Creates bridge: br-abc123
```

Docker adds:

```bash
# nat: masquerade for this network's containers going external
iptables -t nat -A POSTROUTING -s 10.10.0.0/24 ! -o br-abc123 -j MASQUERADE

# filter/DOCKER-INTERNAL: prevent cross-network traffic
# (rules that drop traffic between br-abc123 and other bridges)

# filter/DOCKER-CT: return traffic for this bridge
iptables -A DOCKER-CT -o br-abc123 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

# filter/DOCKER-BRIDGE: dispatch for this bridge
iptables -A DOCKER-BRIDGE -o br-abc123 -j DOCKER

# filter/DOCKER: default deny for this bridge
iptables -A DOCKER ! -i br-abc123 -o br-abc123 -j DROP

# filter/DOCKER-FORWARD: egress from this bridge
iptables -A DOCKER-FORWARD -i br-abc123 -j ACCEPT
```

---

## 12. Packet Flow Examples

### Flow 1: External Client → Published Port (Inbound)

Client `192.168.11.100` requests `http://192.168.11.50:8080`

```
CLIENT 192.168.11.100
     │  src=192.168.11.100, dst=192.168.11.50:8080
     ▼
┌─────────────────────────────────────────────────────────────┐
│  nat / PREROUTING                                           │
│                                                             │
│  DOCKER chain: -p tcp --dport 8080                          │
│  Action: DNAT → dst becomes 172.17.0.2:80                   │
└─────────────────────────────────────────────────────────────┘
     │
     ▼
┌─────────────────────────────────────────────────────────────┐
│  ROUTING DECISION                                           │
│                                                             │
│  "172.17.0.2 is not my IP, ip_forward=1"                    │
│  "Route via docker0"                                        │
└─────────────────────────────────────────────────────────────┘
     │
     ▼
┌─────────────────────────────────────────────────────────────┐
│  filter / FORWARD → DOCKER-USER (empty) → DOCKER-FORWARD    │
│                                                             │
│  DOCKER-CT:      out=docker0, ctstate=NEW → miss            │
│  DOCKER-INTERNAL: no rules → miss                           │
│  DOCKER-BRIDGE:  out=docker0 → jump to DOCKER               │
│    DOCKER rule 1: ACCEPT dst=172.17.0.2 dport=80 ✓          │
│  Verdict: ACCEPT                                            │
└─────────────────────────────────────────────────────────────┘
     │
     ▼
┌─────────────────────────────────────────────────────────────┐
│  nat / POSTROUTING                                          │
│                                                             │
│  MASQUERADE: -s 172.17.0.0/16 ! -o docker0                  │
│  Output IS docker0 → no masquerade                          │
└─────────────────────────────────────────────────────────────┘
     │
     ▼
Container nginx (172.17.0.2:80)
  sees: src=192.168.11.100, dst=172.17.0.2:80
```

### Flow 2: Container → External (Outbound)

Container `172.17.0.2` requests `https://8.8.8.8`

```
CONTAINER 172.17.0.2
     │  src=172.17.0.2, dst=8.8.8.8
     ▼
┌─────────────────────────────────────────────────────────────┐
│  nat / PREROUTING                                           │
│  DOCKER chain: no DNAT rules match → pass through          │
└─────────────────────────────────────────────────────────────┘
     │
     ▼
┌─────────────────────────────────────────────────────────────┐
│  ROUTING DECISION                                           │
│  "8.8.8.8 not local, ip_forward=1, route via eth0"          │
└─────────────────────────────────────────────────────────────┘
     │
     ▼
┌─────────────────────────────────────────────────────────────┐
│  filter / FORWARD → DOCKER-USER → DOCKER-FORWARD            │
│                                                             │
│  DOCKER-CT:      out=eth0 (not docker0) → miss              │
│  DOCKER-INTERNAL: no rules → miss                           │
│  DOCKER-BRIDGE:  out=eth0 (not docker0) → miss              │
│  Final ACCEPT:   in=docker0 ✓                               │
│  Verdict: ACCEPT                                            │
└─────────────────────────────────────────────────────────────┘
     │
     ▼
┌─────────────────────────────────────────────────────────────┐
│  nat / POSTROUTING                                          │
│                                                             │
│  MASQUERADE: -s 172.17.0.0/16 ! -o docker0                  │
│  src=172.17.0.2 ✓, out=eth0 (not docker0) ✓                 │
│  Action: rewrite src → 192.168.11.50                        │
│  Kernel stores NAT mapping in conntrack                      │
└─────────────────────────────────────────────────────────────┘
     │
     ▼
INTERNET (8.8.8.8)  ← sees src=192.168.11.50
```

### Flow 3: Container → Container (Same Bridge)

```
Container A (172.17.0.2)
     │  src=172.17.0.2, dst=172.17.0.3
     ▼
┌─────────────────────────────────────────────────────────────┐
│  filter / FORWARD → DOCKER-USER → DOCKER-FORWARD            │
│                                                             │
│  DOCKER-CT:      out=docker0, NEW → miss                    │
│  DOCKER-INTERNAL: no rules → miss                           │
│  DOCKER-BRIDGE:  out=docker0 → jump to DOCKER               │
│    DOCKER DROP: !docker0 → docker0                          │
│    in=docker0 → "!docker0" is FALSE → DROP does NOT match   │
│    Returns from DOCKER → returns from DOCKER-BRIDGE         │
│  Final ACCEPT:   in=docker0 ✓                               │
│  Verdict: ACCEPT                                            │
└─────────────────────────────────────────────────────────────┘
     │
     ▼
Container B (172.17.0.3)
```

The DROP rule's `!docker0` condition deliberately exempts container-to-container traffic.

### Flow 4: Cross-Network (Blocked)

Container A on `frontend` (10.10.0.2) tries to reach Container B on `backend` (10.20.0.2)

```
Container A (10.10.0.2)
     │  src=10.10.0.2, dst=10.20.0.2
     ▼
┌─────────────────────────────────────────────────────────────┐
│  filter / FORWARD → DOCKER-USER → DOCKER-FORWARD            │
│                                                             │
│  DOCKER-CT:      not established → miss                     │
│  DOCKER-INTERNAL: DROP rule: in=br-frontend, out=br-backend │
│  Verdict: DROP                                              │
└─────────────────────────────────────────────────────────────┘

Container B receives nothing.
```

---

## 13. Summary and Reference Tables

### Complete Chain Traversal (v27)

```
                      PACKET ARRIVES
                            │
                            ▼
                 ┌─────────────────────┐
                 │  nat / PREROUTING   │
                 │  DOCKER chain       │
                 │  (DNAT for ports)   │
                 └──────────┬──────────┘
                            │
                            ▼
                 ┌─────────────────────┐
                 │  ROUTING DECISION   │
                 └──────────┬──────────┘
                            │
                            ▼
                 ┌─────────────────────────────────────┐
                 │  filter / FORWARD                   │
                 │                                     │
                 │  DOCKER-USER (your rules)            │
                 │         │                           │
                 │         ▼                           │
                 │  DOCKER-FORWARD                     │
                 │    ├── DOCKER-CT  (established→OK)  │
                 │    ├── DOCKER-INTERNAL (isolation)  │
                 │    ├── DOCKER-BRIDGE                │
                 │    │      └── DOCKER (DROP default) │
                 │    └── ACCEPT (container egress)    │
                 └──────────────┬──────────────────────┘
                                │
                                ▼
                 ┌─────────────────────┐
                 │  nat / POSTROUTING  │
                 │  MASQUERADE         │
                 └──────────┬──────────┘
                            │
                            ▼
                      PACKET LEAVES
```

### v27 Chain Purposes

| Chain | Table | Responsibility |
|-------|-------|----------------|
| DOCKER-USER | filter | Your custom rules — evaluated before Docker's, never modified by Docker |
| DOCKER-FORWARD | filter | Main dispatch — routes to CT, INTERNAL, BRIDGE, then egress ACCEPT |
| DOCKER-CT | filter | Allow return traffic (ESTABLISHED/RELATED) going into docker0 |
| DOCKER-INTERNAL | filter | Cross-network isolation — DROP rules between different bridges |
| DOCKER-BRIDGE | filter | Dispatch inbound-to-container traffic to DOCKER per-container rules |
| DOCKER | filter | Per-container ACCEPT rules + default DROP for external inbound |
| DOCKER (nat) | nat | DNAT rules for published ports |
| PREROUTING | nat | Sends traffic destined for local IPs into the DOCKER nat chain |
| POSTROUTING | nat | MASQUERADE for containers going external |

### Scenario Summary

| Scenario | Table | Chain | Rule |
|----------|-------|-------|------|
| Container outbound | nat | POSTROUTING | MASQUERADE source IP |
| Published port (DNAT) | nat | DOCKER | DNAT to container IP:port |
| Published port (allow) | filter | DOCKER | ACCEPT before DROP |
| Return traffic | filter | DOCKER-CT | ACCEPT ESTABLISHED to docker0 |
| Container egress | filter | DOCKER-FORWARD | ACCEPT in=docker0 |
| Default deny inbound | filter | DOCKER | DROP !docker0 → docker0 |
| Cross-network isolation | filter | DOCKER-INTERNAL | DROP between bridges |
| Your custom rules | filter | DOCKER-USER | Anything you add |

### Viewing Rules on Your System

```bash
# See all chains and rules
iptables -L -n -v

# See nat table
iptables -t nat -L -n -v

# Full dump (machine readable)
iptables-save

# Specific chains
iptables -L DOCKER -n -v
iptables -L DOCKER-FORWARD -n -v
iptables -L DOCKER-INTERNAL -n -v
```

### Who Does What

| Component | Role |
|-----------|------|
| Docker daemon | Creates/deletes chains and rules when containers/networks start/stop |
| iptables command | User-space tool to write rules to the kernel |
| Netfilter | Kernel framework that enforces rules on every packet |
| Routing table | Decides which interface to forward a packet to |
| ip_forward | Kernel parameter that enables packet forwarding between interfaces |
| conntrack | Tracks NAT mappings so return traffic can be un-NATted |
| Bridges | Layer 2 switching within the same Docker network |
| br_netfilter | Forces bridged traffic through Netfilter (required for iptables to see it) |

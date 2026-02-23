# Docker Networking & iptables Deep Dive

A comprehensive guide to understanding Docker networking, Linux kernel networking concepts, iptables, and how containers communicate.

---

## Table of Contents

1. [Fundamentals: Bridge vs Router](#fundamentals-bridge-vs-router)
2. [Two Custom Bridges Architecture](#two-custom-bridges-architecture)
3. [The Router Component Explained](#the-router-component-explained)
4. [Routing Tables on Every Machine](#routing-tables-on-every-machine)
5. [Special IP Addresses](#special-ip-addresses)
6. [Netfilter: Kernel-Level Packet Processing](#netfilter-kernel-level-packet-processing)
7. [Docker and Kubernetes: Rule Generators](#docker-and-kubernetes-rule-generators)
8. [Kernel Modules for Container Networking](#kernel-modules-for-container-networking)
9. [Docker + iptables: Complete Breakdown](#docker--iptables-complete-breakdown)
10. [Actual iptables Rules Docker Creates](#actual-iptables-rules-docker-creates)
11. [Packet Flow Examples](#packet-flow-examples)
12. [Summary and Reference Tables](#summary-and-reference-tables)

---

## Fundamentals: Bridge vs Router

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

## Two Custom Bridges Architecture

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
           │         │   │ │   │         │
           │Container│   │ │   │Container│
           │    A    │   │ │   │    B    │
           │         │   │ │   │         │
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

With two custom bridges and no explicit iptables rules allowing inter-bridge traffic, the router component will **DROP** packets between Bridge A and Bridge B. This is intentional security segmentation.

---

## The Router Component Explained

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
│    Endpoints don't forward other people's traffic           │
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
10.10.0.0/24       0.0.0.0         bridge_a
10.20.0.0/24       0.0.0.0         bridge_b
0.0.0.0/0          192.168.11.1    eth0
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

## Routing Tables on Every Machine

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

## Special IP Addresses

### The Two 0.0.0.0 Meanings

```
Destination        Gateway         Interface
─────────────────────────────────────────────
192.168.11.0/24    0.0.0.0         eth0
0.0.0.0/0          192.168.11.1    eth0
```

**Gateway 0.0.0.0** = "No gateway needed, send directly"
The destination is on my local network. I can ARP for the MAC address and deliver the frame myself.

**Destination 0.0.0.0/0** = "Match everything"
This is the default route. If no other rule matches, use this one.

### Quick Reference

| Address | Meaning |
|---------|---------|
| 0.0.0.0 | "Any" or "none" depending on context |
| 127.0.0.1 | Localhost (loopback) |
| 255.255.255.255 | Broadcast to everyone on local network |
| 224.0.0.0/4 | Multicast range (one-to-many) |
| Anycast | Same IP advertised from multiple locations, routed to nearest |

### Broadcast vs Multicast vs Anycast

```
UNICAST:      One sender → One receiver
BROADCAST:    One sender → Everyone on local network
MULTICAST:    One sender → Specific group who subscribed
ANYCAST:      One sender → Nearest node sharing same IP
```

---

## Netfilter: Kernel-Level Packet Processing

Netfilter is not a process, not a VM, and not tied to any single network interface. It lives inside the **Linux kernel itself**.

```
┌─────────────────────────────────────────────────────────────┐
│                      USER SPACE                             │
│                                                             │
│   ┌─────────┐  ┌─────────┐  ┌─────────┐  ┌──────────┐       │
│   │ Process │  │ Process │  │ Docker  │  │ iptables │       │
│   │    A    │  │    B    │  │  daemon │  │ command  │       │
│   └────┬────┘  └────┬────┘  └────┬────┘  └────┬─────┘       │
│        │            │            │             │            │
├────────┼────────────┼────────────┼─────────────┼────────────┤
│        │            │            │             │            │
│        ▼            ▼            ▼             ▼            │
│   ┌─────────────────────────────────────────────────┐       │
│   │                                                 │       │
│   │                 LINUX KERNEL                    │       │
│   │                                                 │       │
│   │   ┌─────────────────────────────────────────┐   │       │
│   │   │                                         │   │       │
│   │   │              NETFILTER                  │   │       │
│   │   │                                         │   │       │
│   │   │  Hooks into the kernel's network stack  │   │       │
│   │   │  Inspects EVERY packet flowing through  │   │       │
│   │   │                                         │   │       │
│   │   └─────────────────────────────────────────┘   │       │
│   │                                                 │       │
│   └─────────────────────────────────────────────────┘       │
│                                                             │
│                      KERNEL SPACE                           │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### The Relationship

| Component | What It Is | Where It Lives |
|-----------|------------|----------------|
| Netfilter | Kernel framework with hooks | Inside the kernel |
| iptables | User-space command to configure Netfilter | User space |
| nftables | Newer user-space command (replaces iptables) | User space |
| Rules/chains | Configuration stored in kernel memory | Kernel memory |

### iptables Sits Between All Interfaces

Every packet, regardless of source or destination interface, must pass through Netfilter checkpoints.

```
                eth0                    docker0
                  │                        │
                  ▼                        ▼
        ┌─────────────────────────────────────────────┐
        │                                             │
        │            NETFILTER CHECKPOINTS            │
        │                                             │
        │   ┌─────┐  ┌─────┐  ┌─────┐  ┌─────┐       │
        │   │ PRE │  │ FWD │  │ OUT │  │POST │       │
        │   └─────┘  └─────┘  └─────┘  └─────┘       │
        │                                             │
        └─────────────────────────────────────────────┘
                  │                        │
                  ▼                        ▼
              to external              to container
```

---

## Docker and Kubernetes: Rule Generators

The kernel does not understand containers or pods or services. It only understands packets, interfaces, and rules.

**Docker and Kubernetes are just rule generators.** They translate high-level concepts into low-level Netfilter rules.

```
┌─────────────────────────────────────────────────────────────┐
│                   USER SPACE                                │
│                                                             │
│  ┌───────────┐  ┌───────────┐  ┌───────────────┐            │
│  │  Docker   │  │  kubelet  │  │  kube-proxy   │            │
│  │  daemon   │  │           │  │               │            │
│  └─────┬─────┘  └─────┬─────┘  └───────┬───────┘            │
│        │              │                │                    │
│        ▼              ▼                ▼                    │
│  ┌─────────────────────────────────────────────┐            │
│  │                                             │            │
│  │   "Please create these rules and chains"    │            │
│  │                                             │            │
│  │   - DOCKER chain                            │            │
│  │   - KUBE-SERVICES chain                     │            │
│  │   - KUBE-FORWARD chain                      │            │
│  │   - NAT rules for service IPs               │            │
│  │                                             │            │
│  └──────────────────────┬──────────────────────┘            │
│                         │                                   │
├─────────────────────────┼───────────────────────────────────┤
│                         ▼                                   │
│  ┌─────────────────────────────────────────────┐            │
│  │              LINUX KERNEL                   │            │
│  │                                             │            │
│  │    Kernel does not know what "Docker" is    │            │
│  │    It only sees rules and chains            │            │
│  └─────────────────────────────────────────────┘            │
│                                                             │
│                   KERNEL SPACE                              │
└─────────────────────────────────────────────────────────────┘
```

### High-Level to Low-Level Translation

| High-Level Concept | What Gets Created |
|--------------------|-------------------|
| Docker bridge network | Bridge interface + iptables DOCKER chain |
| Container port publish (-p 8080:80) | DNAT rule to forward traffic |
| Kubernetes Service (ClusterIP) | KUBE-SERVICES chain with DNAT to pod IPs |
| Kubernetes NetworkPolicy | KUBE-FORWARD rules to allow/deny |
| Pod-to-external traffic | Masquerade rule to hide pod IP |

---

## Kernel Modules for Container Networking

### overlay

Required for container image layers to work.

```
┌─────────────────────────────────────────────────────────────┐
│                                                             │
│  CONTAINER IMAGE LAYERS                                     │
│                                                             │
│  ┌─────────────────┐                                        │
│  │  Layer 3: App   │  (your code)                           │
│  ├─────────────────┤                                        │
│  │  Layer 2: Deps  │  (npm install, pip install)            │
│  ├─────────────────┤                                        │
│  │  Layer 1: Base  │  (ubuntu, alpine)                      │
│  └─────────────────┘                                        │
│                                                             │
│  Overlay filesystem merges these into ONE view              │
│  Container sees a single unified filesystem                 │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### br_netfilter

Allows iptables to process bridged network traffic.

**The Problem:**

```
Bridge operates at Layer 2 (MAC addresses)
iptables operates at Layer 3/4 (IP addresses, ports)

By default, traffic switched within a bridge
NEVER reaches iptables

Container A ────► Bridge ────► Container B
                    │
                    X  iptables never sees this
```

**With br_netfilter loaded:**

```
Container A ────► Bridge ────► Container B
                    │
                    ▼
                iptables

Now bridged traffic passes through Netfilter
```

### Why Kubernetes Needs br_netfilter

| Feature | Requires br_netfilter? |
|---------|------------------------|
| NetworkPolicies (allow/deny pod traffic) | Yes |
| Service routing (ClusterIP, NodePort) | Yes |
| kube-proxy DNAT rules | Yes |
| Pod-to-pod traffic filtering | Yes |

Without br_netfilter, pods on the same node talking through a bridge would **bypass all Kubernetes network rules**.

### Required Sysctl Settings

```bash
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
```

---

## Docker + iptables: Complete Breakdown

### How Docker Talks to the Kernel

Docker does not use syscalls directly for iptables. It uses the **netlink** interface.

```
┌─────────────────────────────────────────────────────────────┐
│  DOCKER DAEMON                                              │
│                                                             │
│  ┌─────────────────────────────────────────────────────┐    │
│  │  libnetwork (Docker's networking library)           │    │
│  └──────────────────────┬──────────────────────────────┘    │
│                         │                                   │
│                         ▼                                   │
│  ┌─────────────────────────────────────────────────────┐    │
│  │  iptables (go-iptables library)                     │    │
│  │  Executes /sbin/iptables commands                   │    │
│  └──────────────────────┬──────────────────────────────┘    │
│                         │                                   │
├─────────────────────────┼───────────────────────────────────┤
│                         │                                   │
│                         ▼                                   │
│  ┌─────────────────────────────────────────────────────┐    │
│  │  NETLINK SOCKET                                     │    │
│  │  Protocol: NETLINK_NETFILTER                        │    │
│  │  Sends rule structures to kernel                    │    │
│  └──────────────────────┬──────────────────────────────┘    │
│                         │                                   │
│                         ▼                                   │
│  ┌─────────────────────────────────────────────────────┐    │
│  │  KERNEL: Netfilter subsystem                        │    │
│  │  Receives rules, stores in memory                   │    │
│  │  Enforces on every packet                           │    │
│  └─────────────────────────────────────────────────────┘    │
│                                                             │
│  KERNEL SPACE                                               │
└─────────────────────────────────────────────────────────────┘
```

### The Tables and Their Purposes

| Table | Purpose | Docker Uses |
|-------|---------|-------------|
| raw | Mark packets to skip connection tracking | Rarely |
| mangle | Modify packet headers (TTL, TOS, marks) | Rarely |
| nat | Rewrite source or destination addresses | Heavily |
| filter | Accept, drop, or reject packets | Heavily |

---

## Actual iptables Rules Docker Creates

### Scenario 1: Docker Daemon Starts (No Containers)

**nat table:**

```bash
iptables -t nat -N DOCKER
iptables -t nat -A PREROUTING -m addrtype --dst-type LOCAL -j DOCKER
iptables -t nat -A OUTPUT ! -d 127.0.0.0/8 -m addrtype --dst-type LOCAL -j DOCKER
iptables -t nat -A POSTROUTING -s 172.17.0.0/16 ! -o docker0 -j MASQUERADE
```

**filter table:**

```bash
iptables -N DOCKER
iptables -N DOCKER-ISOLATION-STAGE-1
iptables -N DOCKER-ISOLATION-STAGE-2
iptables -N DOCKER-USER
iptables -A FORWARD -j DOCKER-USER
iptables -A FORWARD -j DOCKER-ISOLATION-STAGE-1
iptables -A FORWARD -o docker0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
iptables -A FORWARD -o docker0 -j DOCKER
iptables -A FORWARD -i docker0 ! -o docker0 -j ACCEPT
iptables -A FORWARD -i docker0 -o docker0 -j ACCEPT
iptables -A DOCKER-ISOLATION-STAGE-1 -i docker0 ! -o docker0 -j DOCKER-ISOLATION-STAGE-2
iptables -A DOCKER-ISOLATION-STAGE-1 -j RETURN
iptables -A DOCKER-ISOLATION-STAGE-2 -o docker0 -j DROP
iptables -A DOCKER-ISOLATION-STAGE-2 -j RETURN
iptables -A DOCKER-USER -j RETURN
```

### Rule Explanations

**MASQUERADE Rule:**

```
┌─────────────────────────────────────────────────────────────┐
│  nat / POSTROUTING                                          │
│                                                             │
│  -s 172.17.0.0/16 ! -o docker0 -j MASQUERADE                │
│                                                             │
│  Translation:                                               │
│    Source: 172.17.0.0/16 (any container)                    │
│    Output: NOT docker0 (going external)                     │
│    Action: Replace source IP with host IP                   │
│                                                             │
│  Why: External servers cannot route to 172.17.x.x           │
│       Must hide behind host's real IP                       │
└─────────────────────────────────────────────────────────────┘
```

**ESTABLISHED/RELATED Rule:**

```
┌─────────────────────────────────────────────────────────────┐
│  filter / FORWARD                                           │
│                                                             │
│  -o docker0 -m conntrack --ctstate RELATED,ESTABLISHED      │
│  -j ACCEPT                                                  │
│                                                             │
│  Translation:                                               │
│    Output: docker0                                          │
│    State: Part of existing connection                       │
│    Action: Allow                                            │
│                                                             │
│  Why: Return traffic for connections containers initiated   │
│       must be allowed back in                               │
└─────────────────────────────────────────────────────────────┘
```

**Outbound Allow Rule:**

```
┌─────────────────────────────────────────────────────────────┐
│  filter / FORWARD                                           │
│                                                             │
│  -i docker0 ! -o docker0 -j ACCEPT                          │
│                                                             │
│  Translation:                                               │
│    Input: docker0 (from container)                          │
│    Output: NOT docker0 (going external)                     │
│    Action: Allow                                            │
│                                                             │
│  Why: Containers can initiate outbound connections          │
└─────────────────────────────────────────────────────────────┘
```

**Isolation Stage 1:**

```
┌─────────────────────────────────────────────────────────────┐
│  filter / DOCKER-ISOLATION-STAGE-1                          │
│                                                             │
│  -i docker0 ! -o docker0 -j DOCKER-ISOLATION-STAGE-2        │
│                                                             │
│  Translation:                                               │
│    Input: docker0                                           │
│    Output: NOT docker0 (different network)                  │
│    Action: Jump to stage 2 for further checks               │
└─────────────────────────────────────────────────────────────┘
```

**Isolation Stage 2:**

```
┌─────────────────────────────────────────────────────────────┐
│  filter / DOCKER-ISOLATION-STAGE-2                          │
│                                                             │
│  -o docker0 -j DROP                                         │
│                                                             │
│  Translation:                                               │
│    Output: docker0                                          │
│    Action: Drop                                             │
│                                                             │
│  Why: Traffic from one Docker network trying to reach       │
│       another Docker network gets dropped here              │
└─────────────────────────────────────────────────────────────┘
```

### Scenario 2: Run Container with Published Port

```bash
docker run -d -p 8080:80 --name web nginx
```

Docker adds:

```bash
# nat table - DNAT for incoming traffic
iptables -t nat -A DOCKER ! -i docker0 -p tcp --dport 8080 \
    -j DNAT --to-destination 172.17.0.2:80

# nat table - masquerade for hairpin/localhost access
iptables -t nat -A POSTROUTING -s 172.17.0.2 -d 172.17.0.2 \
    -p tcp --dport 80 -j MASQUERADE

# filter table - allow traffic to this container
iptables -A DOCKER -d 172.17.0.2 ! -i docker0 -o docker0 \
    -p tcp --dport 80 -j ACCEPT
```

**DNAT Rule Explained:**

```
┌─────────────────────────────────────────────────────────────┐
│  nat / DOCKER chain                                         │
│                                                             │
│  ! -i docker0 -p tcp --dport 8080                           │
│  -j DNAT --to-destination 172.17.0.2:80                     │
│                                                             │
│  Translation:                                               │
│    Input: NOT from docker0 (external traffic)               │
│    Protocol: TCP                                            │
│    Port: 8080                                               │
│    Action: Rewrite destination to 172.17.0.2:80             │
│                                                             │
│  Why: External client hits host:8080                        │
│       Must redirect to container:80                         │
│                                                             │
│  ! -i docker0 prevents:                                     │
│    Container-to-container traffic from being rewritten      │
└─────────────────────────────────────────────────────────────┘
```

### Scenario 3: Create Custom Network

```bash
docker network create --subnet 10.10.0.0/24 frontend
```

Docker adds:

```bash
# nat table
iptables -t nat -A POSTROUTING -s 10.10.0.0/24 ! -o br-abc123 -j MASQUERADE

# filter table - isolation rules
iptables -A DOCKER-ISOLATION-STAGE-1 -i br-abc123 ! -o br-abc123 \
    -j DOCKER-ISOLATION-STAGE-2
iptables -A DOCKER-ISOLATION-STAGE-2 -o br-abc123 -j DROP

# filter table - allow internal and outbound
iptables -A FORWARD -o br-abc123 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
iptables -A FORWARD -i br-abc123 ! -o br-abc123 -j ACCEPT
iptables -A FORWARD -i br-abc123 -o br-abc123 -j ACCEPT
```

### Scenario 4: Two Networks, Isolation in Action

```bash
docker network create frontend
docker network create backend
docker run -d --network frontend --name app1 nginx
docker run -d --network backend --name db mysql
```

**Isolation flow when app1 tries to reach db:**

```
┌─────────────────────────────────────────────────────────────┐
│  app1 (frontend/10.10.0.2) tries to reach db (10.20.0.2)    │
│                                                             │
│  Packet: src=10.10.0.2, dst=10.20.0.2                       │
└─────────────────────────────────────────────────────────────┘
                    │
                    ▼
┌─────────────────────────────────────────────────────────────┐
│  filter / FORWARD                                           │
│                                                             │
│  First rule: -j DOCKER-USER                                 │
│  DOCKER-USER has only: -j RETURN                            │
│  Continue to next rule                                      │
└─────────────────────────────────────────────────────────────┘
                    │
                    ▼
┌─────────────────────────────────────────────────────────────┐
│  DOCKER-ISOLATION-STAGE-1                                   │
│                                                             │
│  Rule: -i br-frontend ! -o br-frontend                      │
│        -j DOCKER-ISOLATION-STAGE-2                          │
│                                                             │
│  Check:                                                     │
│    Input interface: br-frontend ✓                           │
│    Output interface: br-backend (not br-frontend) ✓         │
│                                                             │
│  Action: Jump to DOCKER-ISOLATION-STAGE-2                   │
└─────────────────────────────────────────────────────────────┘
                    │
                    ▼
┌─────────────────────────────────────────────────────────────┐
│  DOCKER-ISOLATION-STAGE-2                                   │
│                                                             │
│  Rule: -o br-backend -j DROP                                │
│                                                             │
│  Check:                                                     │
│    Output interface: br-backend ✓                           │
│                                                             │
│  Action: DROP                                               │
│                                                             │
│  Packet is dropped. db never sees it.                       │
└─────────────────────────────────────────────────────────────┘
```

### Scenario 5: ICC (Inter-Container Communication) Disabled

```bash
docker network create --opt com.docker.network.bridge.enable_icc=false isolated
```

Docker adds:

```bash
iptables -A FORWARD -i br-isolated -o br-isolated -j DROP
```

Even containers on the **same** network cannot communicate.

---

## Packet Flow Examples

### Flow 1: External Client to Container (Inbound)

Client 192.168.11.100 requests http://192.168.11.50:8080

```
CLIENT 192.168.11.100
     │
     │  dst=192.168.11.50:8080
     ▼
┌─────────────────────────────────────────────────────────────┐
│  eth0 (192.168.11.50)                                       │
└─────────────────────────────────────────────────────────────┘
     │
     ▼
┌─────────────────────────────────────────────────────────────┐
│  nat / PREROUTING                                           │
│                                                             │
│  Rule matches: --dport 8080                                 │
│  Action: DNAT to 172.17.0.2:80                              │
│                                                             │
│  Packet now: dst=172.17.0.2:80                              │
└─────────────────────────────────────────────────────────────┘
     │
     ▼
┌─────────────────────────────────────────────────────────────┐
│  ROUTING DECISION                                           │
│                                                             │
│  "172.17.0.2 is not my IP"                                  │
│  "ip_forward=1, so forward it"                              │
│  "Routing table says: via docker0"                          │
└─────────────────────────────────────────────────────────────┘
     │
     ▼
┌─────────────────────────────────────────────────────────────┐
│  filter / FORWARD                                           │
│                                                             │
│  DOCKER-USER: no custom rules, continue                     │
│  DOCKER-ISOLATION: same network, continue                   │
│  DOCKER: -d 172.17.0.2 --dport 80 ACCEPT                    │
│                                                             │
│  Verdict: ACCEPT                                            │
└─────────────────────────────────────────────────────────────┘
     │
     ▼
┌─────────────────────────────────────────────────────────────┐
│  nat / POSTROUTING                                          │
│                                                             │
│  MASQUERADE rule checks: -o docker0?                        │
│  Output is docker0, rule says "! -o docker0"                │
│  No masquerade needed for this flow                         │
└─────────────────────────────────────────────────────────────┘
     │
     ▼
┌─────────────────────────────────────────────────────────────┐
│  docker0 bridge                                             │
└─────────────────────────────────────────────────────────────┘
     │
     ▼
┌─────────────────────────────────────────────────────────────┐
│  Container: nginx (172.17.0.2:80)                           │
│                                                             │
│  nginx sees:                                                │
│    src: 192.168.11.100                                      │
│    dst: 172.17.0.2:80                                       │
└─────────────────────────────────────────────────────────────┘
```

### Flow 2: Container to External (Outbound)

Container 172.17.0.2 requests https://8.8.8.8

```
CONTAINER 172.17.0.2
     │
     │  src=172.17.0.2, dst=8.8.8.8
     ▼
┌─────────────────────────────────────────────────────────────┐
│  docker0 bridge                                             │
└─────────────────────────────────────────────────────────────┘
     │
     ▼
┌─────────────────────────────────────────────────────────────┐
│  nat / PREROUTING                                           │
│                                                             │
│  No matching DNAT rules                                     │
│  Packet unchanged                                           │
└─────────────────────────────────────────────────────────────┘
     │
     ▼
┌─────────────────────────────────────────────────────────────┐
│  ROUTING DECISION                                           │
│                                                             │
│  "8.8.8.8 is not my IP"                                     │
│  "Forward via eth0 to default gateway"                      │
└─────────────────────────────────────────────────────────────┘
     │
     ▼
┌─────────────────────────────────────────────────────────────┐
│  filter / FORWARD                                           │
│                                                             │
│  Rule: -i docker0 -o eth0 ACCEPT                            │
│  Verdict: ACCEPT                                            │
└─────────────────────────────────────────────────────────────┘
     │
     ▼
┌─────────────────────────────────────────────────────────────┐
│  nat / POSTROUTING                                          │
│                                                             │
│  Rule: -s 172.17.0.0/16 ! -o docker0 -j MASQUERADE          │
│                                                             │
│  Source is 172.17.0.2 ✓                                     │
│  Output is eth0 (not docker0) ✓                             │
│                                                             │
│  Action: Rewrite src to 192.168.11.50                       │
│  Kernel saves mapping in conntrack                          │
└─────────────────────────────────────────────────────────────┘
     │
     ▼
┌─────────────────────────────────────────────────────────────┐
│  eth0 (192.168.11.50)                                       │
└─────────────────────────────────────────────────────────────┘
     │
     │  src=192.168.11.50, dst=8.8.8.8
     ▼
INTERNET (8.8.8.8)
```

### Flow 3: Container to Container (Same Bridge)

```
Container A (172.17.0.2)
        │
        │ src=172.17.0.2, dst=172.17.0.3
        ▼
┌─────────────────────────────────────────────────────────────┐
│  docker0 BRIDGE (Layer 2)                                   │
│                                                             │
│  Bridge sees destination MAC for 172.17.0.3                 │
│  Forwards frame directly to Container B                     │
│                                                             │
│  NO routing involved                                        │
│  NO iptables traversal (stays at Layer 2)                   │
└─────────────────────────────────────────────────────────────┘
        │
        ▼
  Container B (172.17.0.3)
```

Traffic between containers on the **same bridge** never leaves Layer 2.

---

## Summary and Reference Tables

### Chain Traversal Order

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
               ┌───────────────┼───────────────┐
               │               │               │
               ▼               ▼               ▼
        Local process?    Forward?       Forward?
        (INPUT chain)     (to container) (between nets)
                               │               │
                               ▼               ▼
                    ┌─────────────────────────────────┐
                    │      filter / FORWARD           │
                    │                                 │
                    │  DOCKER-USER (your rules)       │
                    │         │                       │
                    │         ▼                       │
                    │  DOCKER-ISOLATION-STAGE-1       │
                    │         │                       │
                    │         ▼                       │
                    │  DOCKER-ISOLATION-STAGE-2       │
                    │         │                       │
                    │         ▼                       │
                    │  DOCKER (per-container rules)   │
                    │                                 │
                    └──────────────┬──────────────────┘
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

### Docker's Chain Purposes

| Chain | Table | Purpose |
|-------|-------|---------|
| PREROUTING | nat | Rewrite destination (DNAT for published ports) |
| FORWARD | filter | Allow/deny packets passing through host |
| DOCKER-USER | filter | Your custom rules (survives Docker restarts) |
| DOCKER-ISOLATION-STAGE-1 | filter | Block traffic between different Docker networks |
| DOCKER-ISOLATION-STAGE-2 | filter | Second stage of network isolation |
| DOCKER | filter | Allow traffic to specific containers |
| POSTROUTING | nat | Rewrite source (MASQUERADE for outbound) |

### Who Does What

| Component | Role |
|-----------|------|
| Docker daemon | Creates/deletes rules when containers start/stop |
| iptables command | User-space tool to write rules to kernel |
| Netfilter | Kernel framework that enforces rules |
| Routing table | Decides which interface to use |
| ip_forward | Enables/disables forwarding ability |
| conntrack | Remembers NAT mappings for return traffic |
| Bridges | Layer 2 switching within same network |
| br_netfilter | Forces bridged traffic through iptables |

### Scenario Summary

| Scenario | Table | Chain | Rule Purpose |
|----------|-------|-------|--------------|
| Container outbound | nat | POSTROUTING | MASQUERADE source IP |
| Published port | nat | DOCKER | DNAT to container |
| Published port | filter | DOCKER | Allow forwarded traffic |
| Network isolation | filter | DOCKER-ISOLATION-STAGE-1 | Detect cross-network |
| Network isolation | filter | DOCKER-ISOLATION-STAGE-2 | Drop cross-network |
| Return traffic | filter | FORWARD | ACCEPT ESTABLISHED |
| ICC disabled | filter | FORWARD | DROP same-bridge traffic |
| Custom rules | filter | DOCKER-USER | User's rules (survives restart) |

### Viewing Rules on Your System

```bash
# See nat table rules
iptables -t nat -L -n -v --line-numbers

# See filter table rules
iptables -L -n -v --line-numbers

# See specific chain
iptables -L DOCKER -n -v
iptables -L DOCKER-ISOLATION-STAGE-1 -n -v

# See rules with full detail
iptables-save
```

---

## Quick Reference: The Kernel's Routing Decision

When a packet arrives, the kernel asks: **"Is this destination IP one of mine?"**

```
┌─────────────────────────────────────────────────────────────┐
│                                                             │
│  Packet arrives with dst=X.X.X.X                            │
│                                                             │
│  Kernel checks: "Do I own IP X.X.X.X?"                      │
│                                                             │
│  MY IP ADDRESSES:                                           │
│    eth0:     192.168.11.50                                  │
│    docker0:  172.17.0.1                                     │
│    lo:       127.0.0.1                                      │
│                                                             │
│  If YES → INPUT chain → Local process                       │
│  If NO  → FORWARD chain → Another destination               │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

---

*Document created from a deep-dive discussion on Docker networking, iptables, and Linux kernel networking concepts.*
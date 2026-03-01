# Kubernetes Packet Path: From Socket to Process Delivery

> Deep dive into how a packet travels through the full Kubernetes networking stack — from a process creating a socket inside a container, through virtual IPs and iptables rewriting, CNI routing, and finally delivery to a destination process in another pod's network namespace.

## Table of Contents

1. [Overview](#1-overview) - The abstraction stack at a glance
2. [Linux Networking Primitives](#2-linux-networking-primitives) - What actually exists at the kernel level
3. [Socket Creation Inside a Container](#3-socket-creation-inside-a-container) - Process binds and listens
4. [Pod Network Namespace](#4-pod-network-namespace) - The isolation boundary
5. [Veth Pairs: Bridging Namespaces](#5-veth-pairs-bridging-namespaces) - How packets escape the pod
6. [CNI: Cross-Node Routing](#6-cni-cross-node-routing) - Getting packets between nodes
7. [ClusterIP: The Virtual IP](#7-clusterip-the-virtual-ip) - Exists only in iptables rules
8. [Kube-Proxy and iptables DNAT](#8-kube-proxy-and-iptables-dnat) - The rewriting engine
9. [Full Packet Walk-Through](#9-full-packet-walk-through) - End-to-end with every hop
10. [Return Path](#10-return-path) - How the response gets back
11. [NodePort and LoadBalancer Paths](#11-nodeport-and-loadbalancer-paths) - External traffic entry, full LoadBalancer round-trip
12. [Inspecting Each Layer](#12-inspecting-each-layer) - Commands to observe it yourself

---

## 1. Overview

```
The Kubernetes networking stack is layers of abstraction
that resolve to one thing at the bottom:

  A process listening on a socket inside a Linux network namespace

Everything above exists to route packets to that socket
while hiding the complexity of pod scheduling, node placement, and IP changes.
```

**The abstraction stack:**

```
 ┌──────────────────────────────────────────┐
 │  Service DNS name                        │  ← human-friendly label
 │  (web.default.svc.cluster.local)         │
 ├──────────────────────────────────────────┤
 │  ClusterIP (10.96.0.10)                  │  ← virtual IP, no interface owns it
 │  exists ONLY as iptables/IPVS rules      │
 ├──────────────────────────────────────────┤
 │  Pod IP (10.244.1.5)                     │  ← namespace-scoped IP on a veth
 │  routable via CNI plugin routes/tunnels  │
 ├──────────────────────────────────────────┤
 │  veth pair                               │  ← kernel network namespace boundary
 │  (pod-side eth0 ↔ host-side vethXXXX)    │
 ├──────────────────────────────────────────┤
 │  Process socket                          │  ← the actual thing doing work
 │  (nginx pid 4521, bound to 0.0.0.0:80)  │
 └──────────────────────────────────────────┘
```

---

## 2. Linux Networking Primitives

Before Kubernetes, understand what the kernel provides:

### Network namespaces

```
A network namespace is an isolated copy of the entire network stack:
  - Its own interfaces (lo, eth0)
  - Its own routing table
  - Its own iptables rules
  - Its own /proc/net

Every container gets one. The host has the "default" namespace.

┌─────────────────────────────────────────────┐
│ Host (default network namespace)            │
│                                             │
│  eth0: 192.168.1.10    ← physical NIC       │
│  cni0: 10.244.0.1      ← bridge (CNI)       │
│  veth1a2b: ──┐                              │
│              │ (veth pair)                   │
│  ┌───────────┼─────────────────────┐        │
│  │ Pod netns │                     │        │
│  │  eth0: 10.244.0.5 (pod-side)   │        │
│  │  lo: 127.0.0.1                 │        │
│  │  routing table (own)           │        │
│  │  iptables (own)                │        │
│  └─────────────────────────────────┘        │
└─────────────────────────────────────────────┘
```

### Sockets

```
A socket is the kernel's endpoint for network communication.

It is a combination of:
  - Protocol (TCP/UDP)
  - Local address + port
  - Remote address + port (for connected sockets)

The kernel maintains a socket buffer (send/receive queues)
and delivers incoming packets that match to the owning process.
```

### Veth pairs

```
A virtual ethernet cable with two ends.
Whatever enters one end exits the other.

Created with:  ip link add veth-host type veth peer name veth-pod
Placed across:  ip link set veth-pod netns <pod-namespace>

This is the ONLY way packets cross namespace boundaries
(besides routing through a tunnel or bridge).
```

---

## 3. Socket Creation Inside a Container

When a server process (e.g., nginx) starts inside a container:

### What happens at the system call level

```
1. SOCKET CREATION
   Process calls: socket(AF_INET, SOCK_STREAM, 0)

   Kernel creates a socket structure in the process's network namespace.
   The namespace is inherited from the container's init process,
   which was placed there by the container runtime (containerd/CRI-O).

   Returns: file descriptor (e.g., fd=3)

2. BIND
   Process calls: bind(fd=3, {addr=0.0.0.0, port=80}, ...)

   Kernel registers this socket in the namespace's port table:
     "TCP port 80 on all interfaces in THIS namespace → fd 3 of pid 4521"

   0.0.0.0 means "any interface in my namespace" which is:
     - lo (127.0.0.1)
     - eth0 (10.244.1.5, the pod IP)

3. LISTEN
   Process calls: listen(fd=3, backlog=128)

   Kernel marks the socket as passive (accepting connections).
   Creates a SYN queue (half-open) and accept queue (completed handshakes).

4. ACCEPT (blocks, waiting)
   Process calls: accept(fd=3, ...)

   Process sleeps until a completed TCP connection is in the accept queue.
```

### What this looks like from the kernel's perspective

```
Namespace: pod-netns-abc123
  Interface eth0: 10.244.1.5/24
  Interface lo: 127.0.0.1/8

  Listening sockets:
    TCP 0.0.0.0:80 → pid 4521 (nginx), fd 3

  Routing table:
    default via 10.244.1.1 dev eth0    ← gateway is the host-side of the veth/bridge
    10.244.1.0/24 dev eth0 scope link
```

### Key point: the process sees NOTHING of Kubernetes

```
Inside the container, nginx thinks:
  - "I'm on a machine with IP 10.244.1.5"
  - "I'm listening on port 80"
  - "My gateway is 10.244.1.1"

It has NO knowledge of:
  - Nodes, Services, ClusterIPs
  - iptables rules rewriting packets
  - Other pods or their IPs
  - That it's even in a container
```

---

## 4. Pod Network Namespace

### How it gets created

```
Sequence when kubelet starts a pod:

1. kubelet tells the container runtime: "create this pod"

2. Runtime creates the "sandbox" container (the pause container)
   - This creates the network namespace
   - pause is a minimal process that holds the namespace open

3. kubelet calls the CNI plugin:
   "Set up networking for namespace /proc/<pause-pid>/ns/net"

4. CNI plugin:
   a. Creates a veth pair
   b. Puts one end (eth0) in the pod namespace
   c. Puts the other end (vethXXX) on the host
   d. Assigns Pod IP to the pod-side eth0
   e. Sets up routes (inside pod and on host)
   f. Connects host-side veth to bridge or routing table

5. App containers join the SAME namespace as the pause container
   → All containers in a pod share ONE network namespace
   → They share the same IP, same interfaces, same port space
```

### Multiple containers in one pod

```
Pod with nginx + sidecar:

┌────────────────────────────────────────────┐
│ Pod network namespace (single, shared)     │
│                                            │
│  eth0: 10.244.1.5                          │
│                                            │
│  ┌───────────────┐  ┌──────────────────┐   │
│  │ nginx         │  │ sidecar (envoy)  │   │
│  │ pid 4521      │  │ pid 4522         │   │
│  │ listen :80    │  │ listen :15001    │   │
│  └───────────────┘  └──────────────────┘   │
│                                            │
│  Both see the same eth0, same IP.          │
│  They can talk via localhost (127.0.0.1).  │
│  They CANNOT both bind to the same port.   │
└────────────────────────────────────────────┘
```

---

## 5. Veth Pairs: Bridging Namespaces

### The mechanism

```
A veth pair is a kernel object — two virtual interfaces linked together.
A packet sent into one end is immediately received on the other.

    Pod namespace              Host namespace
    ┌──────────┐               ┌──────────────┐
    │  eth0    │───────────────│  vethA1B2C3  │
    │10.244.1.5│  veth pair    │  (no IP)     │
    └──────────┘               └──────┬───────┘
                                      │
                               ┌──────┴───────┐
                               │   cni0       │  bridge (Flannel)
                               │ 10.244.1.1   │  OR direct routing (Calico)
                               └──────────────┘
```

### When a packet leaves a pod

```
1. nginx in Pod B (10.244.1.5) sends a response packet
   src: 10.244.1.5:80 → dst: 10.244.0.3:49182

2. Kernel in pod namespace checks routing table:
   "10.244.0.3 is not local → use default route → via 10.244.1.1 dev eth0"

3. Packet goes out through eth0 (pod-side of veth)

4. Packet INSTANTLY appears on vethA1B2C3 (host-side of veth)
   No copying, no tunneling — it's the same kernel object

5. If the host-side veth is attached to a bridge (cni0):
   → Bridge forwards based on MAC table

   If Calico (no bridge):
   → Packet goes directly into host routing table
   → Calico installs per-pod routes: "10.244.1.5 → dev vethA1B2C3"
```

### Two models: Bridge vs. Pure routing

```
FLANNEL (bridge model):
  vethA ──┐
  vethB ──┼── cni0 bridge ── host routing table ── flannel.1 (VXLAN)
  vethC ──┘

CALICO (pure routing, no bridge):
  vethA ── host routing table ── BGP/IPIP to other nodes
  vethB ──┘
  vethC ──┘

  Each veth gets a /32 route on the host:
    10.244.1.5 dev caliXXXX scope link
    10.244.1.6 dev caliYYYY scope link
```

---

## 6. CNI: Cross-Node Routing

Once a packet reaches the host network namespace, it needs to get to another node if the destination pod is remote.

### Flannel VXLAN

```
Node 1 (10.244.0.0/24)                    Node 2 (10.244.1.0/24)
┌─────────────────────┐                   ┌─────────────────────┐
│ Host routing table:  │                   │ Host routing table:  │
│ 10.244.1.0/24        │                   │ 10.244.0.0/24        │
│  → via flannel.1     │                   │  → via flannel.1     │
│                      │                   │                      │
│ flannel.1 (VXLAN)    │                   │ flannel.1 (VXLAN)    │
│  encapsulates in UDP │                   │  decapsulates        │
└──────────┬───────────┘                   └──────────┬───────────┘
           │                                          │
           │   UDP:8472 over physical network         │
           └──────────────────────────────────────────┘

Packet nesting:
┌─────────────────────────────────────────────────┐
│ Outer: src=192.168.1.10 dst=192.168.1.11 UDP:8472 │  ← real node IPs
│  ┌───────────────────────────────────────────┐  │
│  │ VXLAN header (VNI=1)                      │  │
│  │  ┌───────────────────────────────────────┐│  │
│  │  │ Inner: src=10.244.0.3 dst=10.244.1.5  ││  │  ← pod IPs
│  │  │        TCP SYN, dport=80              ││  │
│  │  └───────────────────────────────────────┘│  │
│  └───────────────────────────────────────────┘  │
└─────────────────────────────────────────────────┘
```

### Calico BGP (no encapsulation)

```
Node 1 routes:                    Node 2 routes:
10.244.1.0/24 via 192.168.1.11   10.244.0.0/24 via 192.168.1.10

Learned via BGP peering between calico-node agents on each node.

Packet on the wire is just:
┌───────────────────────────────────────┐
│ src=10.244.0.3 dst=10.244.1.5 TCP:80 │  ← pod IPs directly
└───────────────────────────────────────┘

No encapsulation overhead, but requires L2 adjacency
or a BGP-aware network fabric (router peering).
```

---

## 7. ClusterIP: The Virtual IP

### What makes it "virtual"

```
A ClusterIP like 10.96.0.10:

  ✗ Is NOT assigned to any network interface
  ✗ Does NOT exist in any network namespace
  ✗ Cannot be pinged from outside the cluster
  ✗ No ARP entry, no MAC address
  ✗ No process binds to it

  ✓ Exists ONLY as iptables rules (or IPVS entries)
  ✓ The kernel rewrites packets destined for it before routing
  ✓ It is a DNAT target, not a network endpoint
```

### Why it works despite not existing

```
When a pod sends a packet to 10.96.0.10:80:

1. Packet enters the kernel's netfilter pipeline
2. In the nat table, PREROUTING (or OUTPUT for local traffic) chain fires
3. iptables rule matches: -d 10.96.0.10 --dport 80
4. DNAT action rewrites destination to a real pod IP: 10.244.1.5:80
5. Routing decision happens AFTER the rewrite
6. Kernel routes to 10.244.1.5 (a real, routable pod IP)

The ClusterIP is consumed by iptables before routing ever sees it.
The IP doesn't need to exist on any interface because
no packet with that destination ever reaches the routing table.
```

### DNS resolution (the first step)

```
Pod wants to reach Service "web":

1. App does DNS lookup for "web" (or "web.default.svc.cluster.local")

2. /etc/resolv.conf in the pod (set by kubelet):
   nameserver 10.96.0.10    ← CoreDNS ClusterIP (itself virtual)
   search default.svc.cluster.local svc.cluster.local cluster.local

3. DNS query goes to 10.96.0.10:53
   → iptables rewrites to CoreDNS pod IP (e.g., 10.244.0.2:53)
   → CoreDNS responds: "web.default.svc.cluster.local → 10.96.1.50"

4. App now has the ClusterIP: 10.96.1.50
   It connects to 10.96.1.50:80
   → iptables rewrites to an actual backend pod IP

Even DNS resolution itself goes through the same DNAT mechanism.
```

---

## 8. Kube-Proxy and iptables DNAT

### What kube-proxy does

```
kube-proxy is a controller, NOT a proxy in the data path:

1. Watches the API server for Service and Endpoint changes
2. Translates them into iptables rules (or IPVS entries)
3. Installs those rules on every node

It does NOT:
  - Sit in the packet path
  - Forward packets
  - Terminate connections

After rules are installed, kube-proxy could theoretically crash
and existing connections + rules would continue to work.
New Service changes wouldn't be reflected until it recovers.
```

### The iptables chain structure

```
Packet arrives at kernel:

nat table, PREROUTING chain (for incoming traffic)
  └─→ KUBE-SERVICES (jump)
        │
        ├─ match: -d 10.96.1.50/32 --dport 80
        │    └─→ KUBE-SVC-ABCDEF (Service chain)
        │          │
        │          ├─ statistic mode random probability 0.33
        │          │    └─→ KUBE-SEP-AAA (Endpoint A)
        │          │          └─ DNAT → 10.244.0.3:80
        │          │
        │          ├─ statistic mode random probability 0.50
        │          │    └─→ KUBE-SEP-BBB (Endpoint B)
        │          │          └─ DNAT → 10.244.1.5:80
        │          │
        │          └─ (remaining 100%)
        │               └─→ KUBE-SEP-CCC (Endpoint C)
        │                     └─ DNAT → 10.244.2.8:80
        │
        ├─ match: -d 10.96.0.10/32 --dport 53
        │    └─→ KUBE-SVC-DNS (CoreDNS chain)
        │          └─ ...
        │
        └─ (other services...)
```

### Probability-based load balancing

```
With 3 endpoints, iptables uses conditional probabilities:

Rule 1: probability 0.33333 → pick endpoint A (1/3 chance)
Rule 2: probability 0.50000 → pick endpoint B (1/2 of remaining 2/3 = 1/3)
Rule 3: (no probability)   → pick endpoint C (everything left = 1/3)

Result: equal 33.3% distribution across all three pods.

For 4 endpoints: 0.25, 0.333, 0.50, (rest)
For N endpoints: 1/N, 1/(N-1), 1/(N-2), ..., 1/1
```

### Connection tracking (conntrack)

```
After the first packet of a connection is DNATted:

  Conntrack table entry:
    tcp 6 src=10.244.0.3 dst=10.96.1.50 sport=49182 dport=80
          src=10.244.1.5 dst=10.244.0.3 sport=80 dport=49182 [ASSURED]

  All subsequent packets of THIS connection skip iptables rules entirely.
  Conntrack handles the rewrite directly.

  This means:
    - Same TCP connection always goes to the same pod (sticky per-connection)
    - Load balancing decision happens ONCE per connection, not per packet
    - Return packets are automatically reverse-translated
```

---

## 9. Full Packet Walk-Through

### Scenario

```
Pod A (client):  10.244.0.3 on Node 1
Service "web":   ClusterIP 10.96.1.50:80
Pod B (server):  10.244.1.5 on Node 2, nginx listening on :80
```

### Step-by-step: Pod A → Service → Pod B

```
STEP 1: APPLICATION (inside Pod A)
═══════════════════════════════════
  curl http://web:80/index.html

  DNS lookup: "web" → 10.96.1.50 (via CoreDNS, also DNAT'd)

  App calls: connect(fd, {10.96.1.50, port 80})
  Kernel creates socket, builds TCP SYN packet:
    src: 10.244.0.3:49182
    dst: 10.96.1.50:80


STEP 2: POD A's NETWORK NAMESPACE
══════════════════════════════════
  Packet hits the OUTPUT chain in nat table (locally generated traffic):

  → KUBE-SERVICES chain matches: -d 10.96.1.50 --dport 80
  → KUBE-SVC-ABCDEF chain: probability selects KUBE-SEP-BBB
  → DNAT rewrites destination:

    src: 10.244.0.3:49182
    dst: 10.244.1.5:80        ← rewritten from 10.96.1.50

  Conntrack records the translation.

  Routing decision: 10.244.1.5 → default via gateway → eth0


STEP 3: VETH TRAVERSAL (Pod A → Node 1 host)
═════════════════════════════════════════════
  Packet exits Pod A's eth0
  → appears on host-side vethXXXX
  → enters host namespace routing table

  NOTE: if kube-proxy runs in the host namespace (common),
  the DNAT happens here in PREROUTING instead of step 2.
  The result is the same.


STEP 4: HOST ROUTING (Node 1)
═════════════════════════════
  Host routing table:
    10.244.1.0/24 → via flannel.1 (VXLAN) or via 192.168.1.11 (BGP)

  With MASQUERADE (externalTrafficPolicy=Cluster or cross-node):
    POSTROUTING may SNAT:
      src: 192.168.1.10:random   ← node's host IP (eth0), NOT the cni0 bridge IP
      dst: 10.244.1.5:80

  For pod-to-pod within the cluster: typically NO MASQUERADE.
  MASQUERADE applies mainly to NodePort/LoadBalancer with policy=Cluster.


STEP 5: ENCAPSULATION (if overlay network)
══════════════════════════════════════════
  Flannel VXLAN wraps the packet:

  ┌─────────────────────────────────────────────────┐
  │ Outer ethernet frame                            │
  │  src MAC: Node1-NIC     dst MAC: Node2-NIC      │
  │ ┌─────────────────────────────────────────────┐ │
  │ │ Outer IP                                    │ │
  │ │  src: 192.168.1.10   dst: 192.168.1.11      │ │
  │ │ ┌─────────────────────────────────────────┐ │ │
  │ │ │ UDP dst port 8472 (VXLAN)               │ │ │
  │ │ │ ┌─────────────────────────────────────┐ │ │ │
  │ │ │ │ VXLAN header (VNI=1)                │ │ │ │
  │ │ │ │ ┌─────────────────────────────────┐ │ │ │ │
  │ │ │ │ │ Inner: 10.244.0.3 → 10.244.1.5 │ │ │ │ │
  │ │ │ │ │ TCP SYN dport=80                │ │ │ │ │
  │ │ │ │ └─────────────────────────────────┘ │ │ │ │
  │ │ │ └─────────────────────────────────────┘ │ │ │
  │ │ └─────────────────────────────────────────┘ │ │
  │ └─────────────────────────────────────────────┘ │
  └─────────────────────────────────────────────────┘

  Goes out Node 1's physical NIC → physical network → Node 2's NIC


STEP 6: DECAPSULATION (Node 2)
══════════════════════════════
  Node 2's NIC receives the outer packet
  Kernel sees UDP:8472 → flannel.1 VXLAN device
  Strips outer headers, reveals inner packet:
    src: 10.244.0.3:49182
    dst: 10.244.1.5:80


STEP 7: HOST ROUTING (Node 2) → POD B's NAMESPACE
══════════════════════════════════════════════════
  Routing table: 10.244.1.5 → dev vethBBBBBB (or via cni0 bridge)

  Packet crosses the veth pair into Pod B's namespace
  Arrives on Pod B's eth0 (10.244.1.5)


STEP 8: KERNEL SOCKET DELIVERY (inside Pod B)
══════════════════════════════════════════════
  Kernel in Pod B's namespace:

  1. Receives packet on eth0
  2. Checks: TCP, dst port 80
  3. Looks up listening socket table:
     "TCP 0.0.0.0:80 → pid 4521 (nginx), fd 3"
  4. Completes TCP handshake (SYN-ACK back through same path in reverse)
  5. Places completed connection in the accept queue
  6. nginx's accept() returns with a new connected socket fd
  7. nginx reads the HTTP request from the socket buffer
  8. Processes it, writes response back to the socket
```

---

## 10. Return Path

### Response packet traversal

```
Pod B (nginx) writes HTTP response → kernel builds packet:

  src: 10.244.1.5:80
  dst: 10.244.0.3:49182

Path back:

  Pod B eth0 → veth → Node 2 host → encapsulate → physical network
  → Node 1 NIC → decapsulate → Node 1 host routing

  At Node 1, conntrack sees this packet matches an existing entry:
    Original: 10.244.0.3:49182 → 10.96.1.50:80 (the ClusterIP)
    Reply:    10.244.1.5:80 → 10.244.0.3:49182

  Conntrack does REVERSE translation (un-DNAT):
    src: 10.96.1.50:80          ← restored to the ClusterIP
    dst: 10.244.0.3:49182

  → Routes to Pod A via veth

  Pod A's app sees the response coming from 10.96.1.50:80
  (the ClusterIP it originally connected to, NOT the actual pod IP)
```

### Why conntrack reverse-NAT matters

```
Without it:
  App connected to:     10.96.1.50:80
  Response comes from:  10.244.1.5:80

  TCP stack rejects it: "I don't have a connection to 10.244.1.5"

With conntrack:
  Response is rewritten back to appear from 10.96.1.50:80
  TCP stack accepts it: "This matches my connection to 10.96.1.50:80"

  The virtual IP illusion is maintained end-to-end.
```

---

## 11. NodePort and LoadBalancer Paths

### NodePort packet path

```
External client → Node1:30080

STEP 1: Packet arrives at Node 1's physical NIC
  src: 203.0.113.50:12345     ← external client
  dst: 192.168.1.10:30080     ← node IP + NodePort

STEP 2: iptables PREROUTING → KUBE-SERVICES → KUBE-NODEPORTS
  Matches: --dport 30080
  → KUBE-SVC-ABCDEF chain
  → Selects endpoint via probability

  DNAT rewrites:
    dst: 10.244.1.5:80        ← backend pod (may be on another node)

STEP 3a: If policy=Cluster AND pod is on another node:
  MASQUERADE (SNAT) in POSTROUTING:
    src: 192.168.1.10:random   ← node's host IP replaces client IP
    dst: 10.244.1.5:80

  Packet crosses to Node 2 → Pod B
  Pod B sees request from 192.168.1.10 (client IP lost)

STEP 3b: If policy=Local:
  No MASQUERADE. Only forwards to local pods.
  If no local pod → DROP (KUBE-XLB chain)
  Pod B sees request from 203.0.113.50 (client IP preserved)
```

### Hands-on: NodePort deployment example

```yaml
# File: nodeport-demo.yaml
# Creates a Deployment + NodePort Service to see the packet path in action

apiVersion: apps/v1
kind: Deployment
metadata:
  name: web-nodeport-demo
  labels:
    app: web-nodeport
spec:
  replicas: 2
  selector:
    matchLabels:
      app: web-nodeport
  template:
    metadata:
      labels:
        app: web-nodeport
    spec:
      containers:
      - name: nginx
        image: nginx:alpine
        ports:
        - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: web-nodeport-svc
spec:
  type: NodePort
  selector:
    app: web-nodeport
  ports:
  - port: 80            # ClusterIP port (internal)
    targetPort: 80       # Container port
    nodePort: 30080      # External port on every node (range: 30000-32767)
  # externalTrafficPolicy: Cluster   ← default, may SNAT (lose client IP)
  # externalTrafficPolicy: Local     ← preserves client IP, but only routes to local pods
```

```
Mapping:

  kubectl apply -f nodeport-demo.yaml
    ↓ creates
  Deployment → 2 ReplicaSet Pods (nginx)
  Service type=NodePort → ClusterIP + NodePort rule
    ↓ kube-proxy generates
  iptables chains: KUBE-NODEPORTS → KUBE-SVC-xxx → KUBE-SEP-xxx
    ↓ inspect
  kubectl get svc web-nodeport-svc
  kubectl get endpoints web-nodeport-svc
  sudo iptables -t nat -L KUBE-NODEPORTS -n | grep 30080
```

```
Verification steps:

  # 1. Check the service got its NodePort
  kubectl get svc web-nodeport-svc
  #  NAME               TYPE       CLUSTER-IP    EXTERNAL-IP   PORT(S)        AGE
  #  web-nodeport-svc   NodePort   10.96.X.X     <none>        80:30080/TCP   10s

  # 2. Check endpoints are populated (pods are backing the service)
  kubectl get endpoints web-nodeport-svc
  #  NAME               ENDPOINTS                     AGE
  #  web-nodeport-svc   10.244.1.5:80,10.244.2.8:80   10s

  # 3. Hit the NodePort from outside the cluster (use any node's IP)
  curl http://<NODE_IP>:30080

  # 4. Trace the iptables path on the node
  #    -S prints rules in raw format (shows --dport), -L hides it without -v
  sudo iptables -t nat -S KUBE-NODEPORTS          # shows --dport 30080
  sudo iptables -t nat -S KUBE-EXT-<hash>         # shows jump to SVC chain
  sudo iptables -t nat -S KUBE-SVC-<hash>         # shows probability-based routing
  sudo iptables -t nat -S KUBE-SEP-<hash>         # shows DNAT to pod IP

  #    To find the chain hash for your service:
  sudo iptables -t nat -S | grep web-nodeport      # lists all related chains

  # 5. Watch conntrack entries created during the request
  sudo conntrack -L -p tcp --dport 30080

  # 6. Compare traffic policies
  #    Edit the service to switch between Cluster and Local:
  kubectl patch svc web-nodeport-svc -p '{"spec":{"externalTrafficPolicy":"Local"}}'
  #    Now only nodes with a local pod will respond on :30080
  #    But client IP is preserved (check nginx access logs):
  kubectl logs -l app=web-nodeport --tail=5
```

### Annotated chain walk (real output)

The full iptables chain walk for a NodePort request, with annotations:

```
STEP 1: KUBE-NODEPORTS — entry point for all NodePort traffic
─────────────────────────────────────────────────────────────
  -A KUBE-NODEPORTS -p tcp --comment "default/web-nodeport-svc"
     -j KUBE-EXT-7WM2IUBQOCTRHK5M

  Any TCP packet arriving on port 30080 → jump to the EXT chain.


STEP 2: KUBE-EXT — external traffic handling
─────────────────────────────────────────────
  -A KUBE-EXT-7WM2IUBQOCTRHK5M
     --comment "masquerade traffic for default/web-nodeport-svc external destinations"
     -j KUBE-MARK-MASQ                    ← marks packet for SNAT later
  -A KUBE-EXT-7WM2IUBQOCTRHK5M
     -j KUBE-SVC-7WM2IUBQOCTRHK5M        ← then jump to the SVC chain

  KUBE-MARK-MASQ sets a netfilter mark (0x4000). In POSTROUTING, marked
  packets get MASQUERADE'd (source IP replaced with node IP).
  This is why externalTrafficPolicy=Cluster loses the client IP.


STEP 3: KUBE-SVC — load balancing (probability-based)
─────────────────────────────────────────────────────
  -A KUBE-SVC-7WM2IUBQOCTRHK5M
     ! -s 10.244.0.0/16 -d 10.104.109.9/32 -p tcp
     -j KUBE-MARK-MASQ                    ← MASQ for non-pod traffic to ClusterIP

  -A KUBE-SVC-7WM2IUBQOCTRHK5M
     --comment "web-nodeport-svc -> 10.244.1.16:80"
     -m statistic --mode random --probability 0.50000000000
     -j KUBE-SEP-B3ORHEA6RRRCAMQ6        ← 50% chance → Pod A

  -A KUBE-SVC-7WM2IUBQOCTRHK5M
     --comment "web-nodeport-svc -> 10.244.3.13:80"
     -j KUBE-SEP-NAHLKICCZBPYNBXJ        ← remaining 50% → Pod B

  With 2 replicas: first rule fires 50% of the time.
  If it doesn't match, the second rule catches everything else (100% of remainder).
  With 3 replicas it would be: 0.333 → 0.500 → 1.000 (always sums to 100%).


STEP 4: KUBE-SEP — endpoint DNAT (the actual rewrite)
─────────────────────────────────────────────────────
  -A KUBE-SEP-B3ORHEA6RRRCAMQ6
     -s 10.244.1.16/32 -j KUBE-MARK-MASQ ← hairpin: if pod talks to itself
  -A KUBE-SEP-B3ORHEA6RRRCAMQ6
     -p tcp -j DNAT --to-destination 10.244.1.16:80   ← rewrite dst to pod IP

  -A KUBE-SEP-NAHLKICCZBPYNBXJ
     -s 10.244.3.13/32 -j KUBE-MARK-MASQ
  -A KUBE-SEP-NAHLKICCZBPYNBXJ
     -p tcp -j DNAT --to-destination 10.244.3.13:80


CONNTRACK — proves it all worked
────────────────────────────────
  conntrack -L -p tcp --dport 30080:

  src=192.168.11.50  dst=192.168.11.170  sport=49356  dport=30080   ← original
  src=10.244.3.13    dst=10.244.0.0      sport=80     dport=65372   ← reply

  Reading this:
  • Original direction: client 192.168.11.50 → node 192.168.11.170:30080
  • Reply direction:    pod 10.244.3.13:80 → 10.244.0.0 (MASQ'd node IP)
  • conntrack remembers the DNAT so replies get un-DNAT'd automatically
  • The client never sees any pod IPs — the illusion is maintained
```

```
Summary: the full chain path

  External client (192.168.11.50)
    │
    ▼  :30080
  KUBE-NODEPORTS ──→ KUBE-EXT  (mark for MASQUERADE)
                        │
                        ▼
                     KUBE-SVC  (50/50 random split)
                      /     \
                     ▼       ▼
               KUBE-SEP-A   KUBE-SEP-B
               DNAT to      DNAT to
               10.244.1.16  10.244.3.13
                     \       /
                      ▼     ▼
                   POSTROUTING
                   (MASQUERADE: src → node IP)
                        │
                        ▼
                   Pod receives request
```

### LoadBalancer: full round-trip (client URL → response)

This covers the layers NOT shown in the NodePort sections above:
DNS resolution, TCP handshake, ARP, MetalLB speaker, and the return path
through every hop.

```
Scenario (bare-metal with MetalLB L2 mode):

  Client machine:    192.168.11.50   (same LAN, e.g., your laptop)
  MetalLB VIP:       192.168.11.200  (assigned to Service)
  k8s-cp (Node 1):   192.168.11.170  (MetalLB speaker owns the VIP)
  k8s-w1 (Node 2):   192.168.11.171
  Pod A (nginx):     10.244.1.16     on Node 2
  Pod B (nginx):     10.244.3.13     on Node 3
```

```
═══════════════════════════════════════════════════════════
PHASE 1: CLIENT-SIDE — before any packet reaches the cluster
═══════════════════════════════════════════════════════════

User types: curl http://192.168.11.200/index.html

1a. URL PARSING (application layer)
    curl parses:
      scheme: http  →  TCP port 80
      host:   192.168.11.200
      path:   /index.html

1b. DNS (skipped here — IP is used directly)
    If user typed a hostname, the client's OS resolver
    would query its configured DNS (/etc/resolv.conf)
    to get the IP. This is standard client-side DNS,
    NOT Kubernetes CoreDNS (which only works inside pods).

1c. SOCKET CREATION (client kernel)
    curl calls: socket(AF_INET, SOCK_STREAM, 0)   → fd=3
    Then:        connect(fd=3, {192.168.11.200, 80})

    Kernel allocates ephemeral port (e.g., 49500):
      src: 192.168.11.50:49500
      dst: 192.168.11.200:80

1d. ARP RESOLUTION — "Who has 192.168.11.200?"
    ═══════════════════════════════════════════
    Client needs the MAC address to build the Ethernet frame.
    It broadcasts on the LAN:

      ARP Request (broadcast):
        "Who has 192.168.11.200? Tell 192.168.11.50"

    MetalLB speaker on Node 1 (k8s-cp) answers:
        "192.168.11.200 is at aa:bb:cc:dd:ee:01"  ← Node 1's MAC

    This is the KEY trick of MetalLB L2 mode:
    The speaker makes the node's NIC answer for an IP
    it doesn't really own, using gratuitous ARP.

    Client's ARP cache now has:
        192.168.11.200 → aa:bb:cc:dd:ee:01 (Node 1 MAC)

    ┌─────────────────────────────────────────────────────────┐
    │  MetalLB L2 vs BGP:                                    │
    │                                                        │
    │  L2 mode: speaker sends ARP/NDP replies                │
    │    → single node receives ALL traffic for the VIP      │
    │    → failover = new speaker sends gratuitous ARP       │
    │    → limitation: single node bottleneck                 │
    │                                                        │
    │  BGP mode: speaker peers with network router            │
    │    → router learns VIP route via BGP                    │
    │    → traffic can be ECMP'd across multiple nodes       │
    │    → better for high traffic, needs BGP-capable router  │
    └─────────────────────────────────────────────────────────┘

1e. ETHERNET FRAME BUILT (client kernel)
    ┌─────────────────────────────────────────────┐
    │ Ethernet                                    │
    │  dst MAC: aa:bb:cc:dd:ee:01 (Node 1)       │
    │  src MAC: ff:ff:00:11:22:33 (client NIC)   │
    │ ┌─────────────────────────────────────────┐ │
    │ │ IP                                      │ │
    │ │  src: 192.168.11.50                     │ │
    │ │  dst: 192.168.11.200                    │ │
    │ │ ┌─────────────────────────────────────┐ │ │
    │ │ │ TCP SYN                             │ │ │
    │ │ │  src port: 49500                    │ │ │
    │ │ │  dst port: 80                       │ │ │
    │ │ │  seq: 1000, ack: 0                  │ │ │
    │ │ │  flags: SYN                         │ │ │
    │ │ └─────────────────────────────────────┘ │ │
    │ └─────────────────────────────────────────┘ │
    └─────────────────────────────────────────────┘

    Frame goes onto the wire → arrives at Node 1's NIC.


═══════════════════════════════════════════════════════════
PHASE 2: NODE — NIC to iptables (before the NodePort path)
═══════════════════════════════════════════════════════════

2a. NIC RECEIVES FRAME
    Node 1's NIC sees dst MAC matches its own → accepts frame.
    Strips Ethernet header → passes IP packet to kernel.

    Note: the VIP 192.168.11.200 is configured as a secondary IP
    on a dummy or loopback interface by MetalLB, so the kernel
    recognizes it as "local" and processes it (doesn't forward).

2b. NETFILTER PREROUTING — LoadBalancer-specific rules
    The packet enters the netfilter PREROUTING chain.

    For LoadBalancer services, kube-proxy creates an ADDITIONAL
    entry in KUBE-SERVICES that matches the external IP:

      -A KUBE-SERVICES -d 192.168.11.200/32 -p tcp --dport 80
         --comment "default/web-lb-svc loadbalancer IP"
         -j KUBE-EXT-<hash>

    This is the difference from NodePort: LoadBalancer traffic
    matches on the VIP here, NodePort matches in KUBE-NODEPORTS.

    From KUBE-EXT onward, the path is identical to NodePort:
      KUBE-EXT → KUBE-MARK-MASQ → KUBE-SVC → KUBE-SEP → DNAT

    After DNAT:
      src: 192.168.11.50:49500
      dst: 10.244.1.16:80          ← pod on Node 2

2c. TCP HANDSHAKE (happens through the NAT)
    ═════════════════════════════════════════
    The TCP 3-way handshake completes THROUGH all the NAT layers.
    Each packet in the handshake follows the same DNAT/conntrack path:

    Client → Node 1 → Pod:   SYN       (DNAT'd)
    Pod → Node 1 → Client:   SYN-ACK   (un-DNAT'd by conntrack)
    Client → Node 1 → Pod:   ACK       (conntrack fast-path, no iptables)

    After the ACK, the TCP connection is ESTABLISHED.
    conntrack entry moves to ESTABLISHED state (longer timeout).

    From this point, ALL packets in this connection bypass iptables
    rules entirely — conntrack handles the rewrite directly.


═══════════════════════════════════════════════════════════
PHASE 3: HTTP REQUEST (application data over the TCP connection)
═══════════════════════════════════════════════════════════

3a. CLIENT SENDS HTTP REQUEST
    curl writes to the socket:

      GET /index.html HTTP/1.1\r\n
      Host: 192.168.11.200\r\n
      User-Agent: curl/7.88.1\r\n
      Accept: */*\r\n
      \r\n

    Kernel segments this into TCP, wraps in IP, and sends.
    conntrack rewrites dst 192.168.11.200 → 10.244.1.16 (fast-path).

3b. CROSS-NODE FORWARDING (Node 1 → Node 2)
    Already covered in sections 5-6 above (VXLAN encap, flannel routing).
    Packet arrives at Node 2 → de-encapsulated → routed to cni0 bridge
    → veth pair → Pod A's network namespace.

3c. POD RECEIVES — what src IP does the pod see?
    ═══════════════════════════════════════════════
    Pod A's eth0 receives the packet. But what are the addresses?

    Remember: TWO rewrites happened on Node 1 before the packet left:
      1. DNAT:       dst 192.168.11.200:80 → 10.244.1.16:80
      2. MASQUERADE: src 192.168.11.50:49500 → 10.244.0.0:65372

    So the packet arriving at the pod has:
      src: 10.244.0.0:65372       ← Node 1's flannel.1 IP (NOT the client)
      dst: 10.244.1.16:80         ← the pod itself

    The pod has NO idea about the real client (192.168.11.50).
    nginx logs will show:

      10.244.0.0 - - [01/Mar/2026:12:00:00] "GET /index.html HTTP/1.1" 200 615

    This is the cost of externalTrafficPolicy=Cluster:
      ✓ Load balances across ALL pods on ALL nodes
      ✗ Client IP is lost (replaced by the forwarding node's CNI IP)

    ┌─────────────────────────────────────────────────────────────────┐
    │  Why 10.244.0.0 and not 192.168.11.170 (node's host IP)?      │
    │                                                                │
    │  MASQUERADE uses the IP of the OUTGOING interface.             │
    │  The packet goes to 10.244.1.16 (pod on another node),        │
    │  so it exits via flannel.1 whose IP is 10.244.0.0.            │
    │                                                                │
    │  If the pod were on the SAME node, the packet would exit       │
    │  via cni0 (10.244.0.1), so MASQUERADE would use that instead. │
    └─────────────────────────────────────────────────────────────────┘

    ┌─────────────────────────────────────────────────────────────────┐
    │  With externalTrafficPolicy=Local:                             │
    │                                                                │
    │  No MASQUERADE happens. The pod sees:                          │
    │    src: 192.168.11.50:49500   ← real client IP preserved!      │
    │    dst: 10.244.1.16:80                                         │
    │                                                                │
    │  nginx logs:                                                   │
    │    192.168.11.50 - - "GET /index.html HTTP/1.1" 200 615       │
    │                                                                │
    │  But: traffic only goes to pods on the node that received it.  │
    │  If no local pod exists → connection is DROPPED.               │
    └─────────────────────────────────────────────────────────────────┘

3d. POD PROCESSES THE REQUEST
    Kernel delivers the data to nginx's socket (fd=6, listening on :80).
    nginx reads the HTTP request, finds /index.html, builds response.

    The connected socket's peer address (getpeername()) returns:
      10.244.0.0:65372    ← this is all nginx knows about "the client"

    nginx calls write() on the socket to send the response.
    The kernel knows to send it back to 10.244.0.0:65372.


═══════════════════════════════════════════════════════════
PHASE 4: RESPONSE — full return path
═══════════════════════════════════════════════════════════

4a. POD SENDS HTTP RESPONSE
    nginx writes to its connected socket:

      HTTP/1.1 200 OK\r\n
      Content-Type: text/html\r\n
      Content-Length: 615\r\n
      \r\n
      <!DOCTYPE html>...<html>...</html>

    Kernel builds TCP segment(s) using the socket's peer address:
      src: 10.244.1.16:80          ← pod's own IP
      dst: 10.244.0.0:65372        ← MASQ'd address it thinks is the client

    The pod just replies to whoever it thinks sent the request.
    It doesn't know about conntrack, MASQUERADE, or the real client.
    The un-NATting happens later on Node 1 (step 4c below).

    (With externalTrafficPolicy=Local: dst would be 192.168.11.50:49500
     and un-DNAT on Node 1 only needs to rewrite src VIP → done.)

4b. REVERSE PATH: Pod → Node 2 → Node 1
    Pod's routing table:  default via 10.244.1.1 (cni0 on Node 2)
    Node 2 routing table: 10.244.0.0/24 → via flannel.1

    VXLAN encapsulation (reverse direction):
      Outer: Node2-IP → Node1-IP, UDP:8472
      Inner: 10.244.1.16:80 → 10.244.0.0:65372

4c. CONNTRACK REVERSE TRANSLATION (Node 1)
    Packet arrives at Node 1, de-encapsulated.

    conntrack finds the matching entry and applies REVERSE translations:

      Step 1: un-MASQUERADE (reverse SNAT)
        dst: 10.244.0.0:65372 → 192.168.11.50:49500

      Step 2: un-DNAT (reverse DNAT)
        src: 10.244.1.16:80 → 192.168.11.200:80

    Packet is now:
      src: 192.168.11.200:80     ← looks like VIP responded
      dst: 192.168.11.50:49500   ← original client

4d. ARP + FRAME OUT (Node 1 → Client)
    Node 1 knows the client's MAC from its ARP cache
    (learned during the incoming SYN).

    Builds Ethernet frame:
      dst MAC: ff:ff:00:11:22:33 (client NIC)
      src MAC: aa:bb:cc:dd:ee:01 (Node 1 NIC)

    Frame goes onto the wire → client NIC receives it.

4e. CLIENT RECEIVES RESPONSE
    Client kernel matches the packet to the connected socket (fd=3)
    using the 4-tuple: {192.168.11.50:49500, 192.168.11.200:80}

    curl reads the HTTP response from the socket → prints to terminal.

    The client has NO idea that:
      - The response came from pod 10.244.1.16 on a different node
      - The packet was VXLAN-encapsulated between nodes
      - iptables did probability-based load balancing
      - conntrack rewrote addresses in both directions
      - The VIP 192.168.11.200 is "owned" by a MetalLB speaker

    To the client, it simply talked to 192.168.11.200:80.
```

```
═══════════════════════════════════════════════════════════
PHASE 5: CONNECTION TEARDOWN
═══════════════════════════════════════════════════════════

After curl finishes:

  Client → Pod:   FIN, ACK     (I'm done sending)
  Pod → Client:   FIN, ACK     (I'm done too)
  Client → Pod:   ACK           (acknowledged)

  All FIN/ACK packets follow the same conntrack fast-path.

  conntrack entry transitions:
    ESTABLISHED → FIN_WAIT → CLOSE_WAIT → TIME_WAIT → (expire)

  TIME_WAIT lasts 120 seconds (default).
  During TIME_WAIT, the 4-tuple is reserved to prevent
  stale packets from a previous connection being misinterpreted.

  After expiry, the conntrack entry is deleted.
  The iptables DNAT rules are ready for a NEW connection
  (which may land on a DIFFERENT pod — fresh probability roll).
```

```
Summary: layers crossed for a single HTTP request + response

  REQUEST (→):
  ┌──────────────────────────────────────────────────────────────────┐
  │ curl  →  socket  →  TCP SYN  →  ARP "who has VIP?"             │
  │   →  MetalLB speaker answers  →  frame to Node 1               │
  │   →  netfilter PREROUTING  →  KUBE-SERVICES (VIP match)        │
  │   →  KUBE-EXT  →  MARK-MASQ  →  KUBE-SVC  →  KUBE-SEP         │
  │   →  DNAT to pod IP  →  conntrack entry created                 │
  │   →  host routing  →  POSTROUTING MASQUERADE                    │
  │   →  VXLAN encap  →  wire  →  Node 2 de-encap                  │
  │   →  cni0 bridge  →  veth  →  pod netns  →  nginx socket       │
  └──────────────────────────────────────────────────────────────────┘

  RESPONSE (←):
  ┌──────────────────────────────────────────────────────────────────┐
  │ nginx  →  socket  →  TCP  →  pod eth0  →  veth  →  cni0        │
  │   →  Node 2 routing  →  VXLAN encap  →  wire                   │
  │   →  Node 1 de-encap  →  conntrack reverse:                     │
  │      un-MASQ (dst → client IP)  +  un-DNAT (src → VIP)         │
  │   →  ARP lookup client MAC  →  frame out  →  wire              │
  │   →  client NIC  →  kernel  →  socket  →  curl prints          │
  └──────────────────────────────────────────────────────────────────┘

  Total NAT translations per request:  4
    Forward DNAT, forward SNAT, reverse un-SNAT, reverse un-DNAT
  Total encapsulations per request:    2  (one each direction)
  iptables rule evaluations:           1  (first packet only, rest = conntrack)
```

#### Inspect it yourself

```bash
# 1. See MetalLB's VIP assignment
kubectl get svc web-lb-svc
#  EXTERNAL-IP = 192.168.11.200

# 2. Which node owns the VIP? (L2 mode)
#    Check ARP from the client machine or another node:
arping -c 1 192.168.11.200
#    The reply MAC tells you which node's speaker owns it

# 3. See the LoadBalancer-specific iptables rule (on the owning node)
sudo iptables -t nat -S | grep "loadbalancer IP"
#    Shows: -d 192.168.11.200/32 ... -j KUBE-EXT-<hash>

# 4. Watch conntrack entries during a request
#    Terminal 1:
sudo conntrack -E -p tcp --dst 192.168.11.200
#    Terminal 2:
curl http://192.168.11.200/

# 5. See the full translation in conntrack table
sudo conntrack -L -d 192.168.11.200

# 6. Check MetalLB speaker logs for ARP activity
kubectl logs -n metallb-system -l app=metallb,component=speaker --tail=10
```

---

## 12. Inspecting Each Layer

### Socket (inside the container)

```bash
# See listening sockets in a container
kubectl exec <pod> -- ss -tlnp
# Or
kubectl exec <pod> -- cat /proc/net/tcp

# Output example:
# State  Recv-Q  Send-Q  Local Address:Port  Peer Address:Port  Process
# LISTEN 0       128     0.0.0.0:80          0.0.0.0:*          users:(("nginx",pid=1,fd=6))
```

### Network namespace

```bash
# Find the pod's network namespace on the node
PID=$(crictl inspect <container-id> | jq .info.pid)
nsenter -t $PID -n ip addr show
nsenter -t $PID -n ip route show
nsenter -t $PID -n ss -tlnp
```

### Veth pairs

```bash
# On the node, find which veth connects to which pod
ip link show type veth

# Inside pod: get the interface index of the peer
kubectl exec <pod> -- cat /sys/class/net/eth0/iflink
# Then on the host, find the interface with that index
ip link | grep "^<index>:"
```

### CNI routes

```bash
# See where pod subnets route to
ip route show | grep 10.244

# Flannel: 10.244.1.0/24 via 10.244.1.0 dev flannel.1
# Calico:  10.244.1.5/32 dev caliXXXX scope link
```

### iptables rules (the DNAT)

```bash
# See all Service DNAT rules
iptables -t nat -L KUBE-SERVICES -n --line-numbers

# Follow a specific service chain
iptables -t nat -L KUBE-SVC-ABCDEF -n

# See endpoints (the actual DNAT targets)
iptables -t nat -L KUBE-SEP-AAA -n
```

### Conntrack entries

```bash
# See active connection translations
conntrack -L -d 10.96.1.50
# Shows: original dst=10.96.1.50 → reply src=10.244.1.5

# Count entries
conntrack -C
```

### VXLAN encapsulation

```bash
# Capture encapsulated traffic
tcpdump -i eth0 udp port 8472

# Capture inner (decapsulated) traffic
tcpdump -i flannel.1
```

---

## Summary: What's Real and What's Not

```
REAL (exists on a device/interface):
  ├─ Physical NIC IP (192.168.1.10)         → host eth0
  ├─ CNI bridge IP (10.244.0.1)             → cni0 interface
  ├─ Pod IP (10.244.1.5)                    → pod's eth0 (in its namespace)
  └─ Process socket (0.0.0.0:80, pid 4521) → kernel socket table

VIRTUAL (no device, just rules):
  ├─ ClusterIP (10.96.1.50)                → iptables DNAT rules only
  └─ Service DNS name                      → CoreDNS A record → ClusterIP

TRANSPORT (moves packets between real endpoints):
  ├─ Veth pairs                            → cross namespace boundary
  ├─ CNI bridge/routes                     → cross pods on same node
  └─ VXLAN/BGP                             → cross nodes
```

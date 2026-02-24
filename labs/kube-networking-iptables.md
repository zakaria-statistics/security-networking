# Kubernetes Networking & iptables
> How kube-proxy programs iptables to route Service traffic — with chain traces and hands-on inspection

## Table of Contents
1. [Overview](#1-overview) - Three network planes and what owns each one
2. [Phase 1: The Three Network Planes](#2-phase-1-the-three-network-planes) - Pod, Service, and Node networks
3. [Phase 2: kube-proxy Chain Hierarchy](#3-phase-2-kube-proxy-chain-hierarchy) - How KUBE-* chains are structured
4. [Phase 3: ClusterIP — DNAT in Action](#4-phase-3-clusterip--dnat-in-action) - Virtual IPs and per-pod probability routing
5. [Phase 4: NodePort Deep Dive](#5-phase-4-nodeport-deep-dive) - External traffic → DNAT → MASQUERADE
6. [Phase 5: ExternalTrafficPolicy](#6-phase-5-externaltrafficpolicy) - Preserving client IP vs even distribution
7. [Phase 6: NetworkPolicy and iptables](#7-phase-6-networkpolicy-and-iptables) - Pod-level firewalling by CNI
8. [Phase 7: Inspecting Rules on a Live Node](#8-phase-7-inspecting-rules-on-a-live-node) - Hands-on exploration and tracing
9. [Phase 8: Debugging Service Routing](#9-phase-8-debugging-service-routing) - "Service not reachable" workflow
10. [Phase 9: Beyond iptables — IPVS and eBPF](#10-phase-9-beyond-iptables--ipvs-and-ebpf) - Why and when iptables is replaced
11. [Quick Reference](#11-quick-reference) - Commands and chain map

## Overview

Kubernetes uses iptables to implement Service routing, load balancing,
and MASQUERADE. Every Service you create results in a set of KUBE-* chains
in the nat and filter tables. These are the same DNAT and MASQUERADE patterns
from [nat-lab.md](nat-lab.md) — applied at cluster scale.

**What you'll learn:**
- Why ClusterIP addresses exist only in iptables rules — no interface owns them
- How kube-proxy distributes traffic across pods using probability-based DNAT
- How NodePort traffic flows from external client to pod, including cross-node MASQUERADE
- Why the same "return path problem" from nat-lab.md appears in Kubernetes
- How NetworkPolicy enforcement works at the iptables level
- When and why clusters move to IPVS or eBPF

**Prerequisites:**
- DNAT, SNAT, MASQUERADE from [nat-lab.md](nat-lab.md)
- Docker networking basics from [Docker-Networking-iptables.md](Docker-Networking-iptables.md)

**Lab environment:** Any K8s node with `kubectl` and node access (`ssh` or `kubectl debug node`).

---

## 2. Phase 1: The Three Network Planes

```
┌─────────────────────────────────────────────────────────────────────┐
│                     Kubernetes Cluster                               │
│                                                                      │
│  1. Pod Network (CNI-managed)                                       │
│     Every pod gets a unique IP. Pods reach any other pod             │
│     directly by IP — no NAT between pods on different nodes.        │
│     Range: e.g., 10.244.0.0/16 (Flannel) or 10.42.0.0/16 (k3s)   │
│                                                                      │
│  2. Service Network (kube-proxy-managed)                            │
│     Virtual IPs (ClusterIP) that load-balance to pod endpoints.     │
│     Range: e.g., 10.96.0.0/12                                      │
│     These IPs exist ONLY in iptables rules — no interface has them. │
│     Try to ping a ClusterIP — it won't respond to ICMP.             │
│                                                                      │
│  3. Node Network (physical/cloud)                                   │
│     The actual IPs of your nodes. NodePort and LoadBalancer          │
│     expose services on these IPs.                                    │
│     Range: e.g., 192.168.11.0/24 (homelab)                         │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

### How traffic flows for each Service type

**ClusterIP (default):**

```
Pod A (10.244.1.5) → Service "my-svc" (10.96.0.10:80)

1. Pod A sends packet: src=10.244.1.5, dst=10.96.0.10:80
2. Packet hits iptables on the node (OUTPUT if same node, PREROUTING if different)
3. kube-proxy DNAT: dst → 10.244.2.8:8080 (one of the service's pods)
4. Packet routed to destination pod via CNI
5. Response follows reverse path — conntrack reverses the DNAT

No interface owns 10.96.0.10 — it's a "virtual" IP that ONLY exists
in iptables DNAT rules.
```

**NodePort:**

```
External client (192.168.11.50) → Node (192.168.11.109):30080

1. Packet arrives: src=.50, dst=.109:30080
2. PREROUTING → KUBE-SERVICES → KUBE-NODEPORTS
3. DNAT: dst → 10.244.2.8:8080 (pod endpoint)
4. If pod is on a DIFFERENT node:
   - FORWARD chain allows it
   - POSTROUTING: MASQUERADE (src rewritten to node's IP)
   - Packet forwarded to other node
5. Response path reversed via conntrack

This is EXACTLY the DNAT + MASQUERADE pattern from nat-lab.md!
```

**LoadBalancer:**

```
Cloud LB → NodePort → kube-proxy DNAT → Pod

LoadBalancer is NodePort with extra steps:
1. Cloud creates an external LB (AWS ELB, Azure LB, MetalLB, etc.)
2. LB health-checks all nodes on the NodePort
3. LB sends traffic to a healthy node's NodePort
4. From there, identical to NodePort flow above
```

---

## 3. Phase 2: kube-proxy Chain Hierarchy

kube-proxy creates a tree of custom chains in the nat and filter tables.
Understanding the hierarchy lets you read the rules without getting overwhelmed.

```
nat table:
  PREROUTING
    └─ KUBE-SERVICES           (entry point — matches all Service ClusterIPs)
         ├─ KUBE-SVC-XXXXX     (per-service chain — load balancing)
         │    ├─ KUBE-SEP-AAA  (Service EndPoint — DNAT to pod 1)
         │    ├─ KUBE-SEP-BBB  (DNAT to pod 2)
         │    └─ KUBE-SEP-CCC  (DNAT to pod 3)
         ├─ KUBE-SVC-YYYYY     (another service)
         │    └─ ...
         └─ KUBE-NODEPORTS     (matches NodePort traffic)
              └─ KUBE-SVC-XXXXX (same service chain, reused)

  POSTROUTING
    └─ KUBE-POSTROUTING        (MASQUERADE for traffic leaving the node)

filter table:
  FORWARD
    └─ KUBE-FORWARD            (allow forwarded service traffic)
  INPUT
    └─ KUBE-FIREWALL           (drop invalid packets)
```

### Example — a Service with 3 replicas

```bash
kubectl create deployment web --image=nginx --replicas=3
kubectl expose deployment web --port=80 --type=ClusterIP
```

**What kube-proxy creates:**

```
# Service ClusterIP: 10.96.45.123
# Pod endpoints: 10.244.1.5:80, 10.244.2.8:80, 10.244.3.2:80

# In KUBE-SERVICES — entry point matching the ClusterIP:
-A KUBE-SERVICES -d 10.96.45.123/32 -p tcp --dport 80 -j KUBE-SVC-ABCDEF

# In KUBE-SVC-ABCDEF — probabilistic load balancing:
-A KUBE-SVC-ABCDEF -m statistic --mode random --probability 0.33333 -j KUBE-SEP-AAA
-A KUBE-SVC-ABCDEF -m statistic --mode random --probability 0.50000 -j KUBE-SEP-BBB
-A KUBE-SVC-ABCDEF                                                   -j KUBE-SEP-CCC

# In each KUBE-SEP — the actual DNAT to the pod:
-A KUBE-SEP-AAA -p tcp -j DNAT --to-destination 10.244.1.5:80
-A KUBE-SEP-BBB -p tcp -j DNAT --to-destination 10.244.2.8:80
-A KUBE-SEP-CCC -p tcp -j DNAT --to-destination 10.244.3.2:80
```

**Load balancing math:**

```
Pod 1: probability 0.333  → 33.3% of traffic
Pod 2: probability 0.500  → 50% of remaining 66.7% = 33.3%
Pod 3: no probability     → everything left = 33.3%

Result: each pod gets ~33% of traffic.
With 4 pods: 0.25, 0.333, 0.5, 1.0 — same math applied recursively.
```

---

## 4. Phase 3: ClusterIP — DNAT in Action

### Traffic flow — pod to ClusterIP

```
Pod A (10.244.1.5) calls Service (10.96.45.123:80)

┌─────────────────────────────────────────────────────────────┐
│  Pod A sends:                                               │
│    src=10.244.1.5, dst=10.96.45.123:80                      │
└─────────────────────────────────────────────────────────────┘
                    │
                    ▼
┌─────────────────────────────────────────────────────────────┐
│  nat / OUTPUT (same node) or PREROUTING (different node)    │
│                                                             │
│  → KUBE-SERVICES                                            │
│  → KUBE-SVC-ABCDEF (matched ClusterIP 10.96.45.123)         │
│  → KUBE-SEP-BBB    (probability selected pod 2)             │
│                                                             │
│  Action: DNAT dst → 10.244.2.8:80                           │
└─────────────────────────────────────────────────────────────┘
                    │
                    ▼
┌─────────────────────────────────────────────────────────────┐
│  ROUTING DECISION                                           │
│                                                             │
│  "10.244.2.8 — is this on this node or another node?"       │
│                                                             │
│  If same node: deliver via veth/bridge to pod directly      │
│  If other node: FORWARD chain → CNI sends to Node 2         │
└─────────────────────────────────────────────────────────────┘
                    │
                    ▼
┌─────────────────────────────────────────────────────────────┐
│  nat / POSTROUTING → KUBE-POSTROUTING                       │
│                                                             │
│  MASQUERADE if traffic is leaving the node                  │
│  (so the receiving pod responds back through the same node) │
└─────────────────────────────────────────────────────────────┘
```

### Why ClusterIP can't be pinged

```
ping 10.96.45.123

ICMP goes through OUTPUT chain → KUBE-SERVICES → KUBE-SVC-ABCDEF
→ DNAT to a pod endpoint

BUT: ICMP doesn't match the TCP rule in KUBE-SVC-ABCDEF
     (the rule is -p tcp --dport 80)
     ICMP falls through with no match → no DNAT → packet goes nowhere
     No interface owns 10.96.45.123 → ICMP unreachable
```

### Inspect the rules

```bash
# Get the ClusterIP
SVC_IP=$(kubectl get svc web -o jsonpath='{.spec.clusterIP}')

# Find which KUBE-SVC chain handles this service
iptables-save -t nat | grep "$SVC_IP"
# -A KUBE-SERVICES -d 10.96.45.123/32 -p tcp --dport 80 -j KUBE-SVC-ABCDEF

# Follow the service chain — see probability distribution
iptables-save -t nat | grep "KUBE-SVC-ABCDEF"

# Follow each endpoint — see the DNAT rules with actual pod IPs
iptables-save -t nat | grep "KUBE-SEP-"
```

---

## 5. Phase 4: NodePort Deep Dive

### What happens when you create a NodePort Service

```bash
kubectl expose deployment web --port=80 --type=NodePort
# Kubernetes assigns a port, e.g., 30080
```

**Additional rules added (beyond ClusterIP rules):**

```
# In KUBE-SERVICES — catch NodePort traffic on any node IP:
-A KUBE-SERVICES -m addrtype --dst-type LOCAL -j KUBE-NODEPORTS

# In KUBE-NODEPORTS:
-A KUBE-NODEPORTS -p tcp --dport 30080 -j KUBE-SVC-ABCDEF
# (reuses the same service chain as ClusterIP)

# In KUBE-POSTROUTING — MASQUERADE when pod is on a different node:
-A KUBE-POSTROUTING -m comment --comment "kubernetes service traffic requiring SNAT" \
   -j MASQUERADE
```

### Same-node vs cross-node routing

```
Scenario 1: Pod is on the SAME node that received the NodePort traffic

Client (.50) ──► Node-1:30080
                    │
                    ├─ PREROUTING → KUBE-SERVICES → KUBE-NODEPORTS
                    ├─ DNAT: dst → 10.244.1.5:80 (pod on this node)
                    ├─ Routing: local pod, deliver via CNI bridge/veth
                    └─ No MASQUERADE needed (same node)

Scenario 2: Pod is on a DIFFERENT node

Client (.50) ──► Node-1:30080
                    │
                    ├─ PREROUTING → DNAT: dst → 10.244.2.8:80 (pod on Node-2)
                    ├─ Routing: not local → FORWARD chain
                    ├─ POSTROUTING: MASQUERADE (src = Node-1's IP)
                    └─ Packet sent to Node-2 via pod network
                              │
                    Node-2 receives: src=Node-1, dst=10.244.2.8:80
                              │
                    Pod responds to Node-1 (because MASQUERADE)
                    Node-1 reverses NAT → sends back to client

This is the EXACT same "return path problem" from nat-lab.md Phase 6!
MASQUERADE ensures the response goes back through Node-1 (the node
the client originally hit).
```

### The source IP trade-off

```
Default NodePort behavior (externalTrafficPolicy: Cluster):

Client IP: 203.0.113.5
  → Node-1:30080
    → DNAT to Pod on Node-2
    → MASQUERADE: src becomes Node-1's IP
    → Pod sees src=Node-1, NOT 203.0.113.5

The pod (and your app's access logs) never see the real client IP.
Same trade-off from nat-lab.md Phase 6 — full NAT loses the client IP.
```

---

## 6. Phase 5: ExternalTrafficPolicy

### policy: Cluster (default)

```
Traffic arrives at ANY node → DNAT to ANY pod → MASQUERADE applied.

Pros:
  - Even traffic distribution across all pods
  - Works even if the pod isn't on the receiving node

Cons:
  - Extra network hop when pod is on a different node
  - Client IP lost (MASQUERADE)
```

### policy: Local

```yaml
apiVersion: v1
kind: Service
metadata:
  name: web
spec:
  type: NodePort
  externalTrafficPolicy: Local
  ports:
  - port: 80
    nodePort: 30080
  selector:
    app: web
```

**What changes in iptables:**

```
With policy=Local, kube-proxy adds:
  - If this node has NO local pods → DROP the NodePort traffic
  - If this node HAS local pods → DNAT to local pods only, NO MASQUERADE

# The KUBE-XLB chain handles external traffic with local policy:
-A KUBE-XLB-ABCDEF -m comment --comment "no local endpoints" -j KUBE-MARK-DROP
# OR (if local pods exist):
-A KUBE-XLB-ABCDEF -j KUBE-SEP-AAA    # only local pod(s)
```

**Behavior comparison:**

```
                    policy=Cluster              policy=Local
                    ┌─────────────────┐         ┌─────────────────┐
Client IP visible?  │ NO (MASQUERADE) │         │ YES (no SNAT)   │
                    └─────────────────┘         └─────────────────┘
Traffic distribution│ Even across all │         │ Only to local   │
                    │ pods            │         │ pods (uneven)   │
                    └─────────────────┘         └─────────────────┘
Extra hop?          │ YES (cross-node)│         │ NO (local only) │
                    └─────────────────┘         └─────────────────┘
Node without pods?  │ Still receives  │         │ Health check    │
                    │ traffic         │         │ fails → LB skips│
                    └─────────────────┘         └─────────────────┘
```

---

## 7. Phase 6: NetworkPolicy and iptables

### What NetworkPolicy does

```
Without NetworkPolicy:
  Every pod can talk to every other pod (flat network, no isolation)

With NetworkPolicy:
  You define allow-lists per pod (ingress and egress rules)
  Everything not explicitly allowed is denied (for pods selected by a policy)
```

**NetworkPolicy is enforced by the CNI plugin, not kube-proxy.** Different
CNIs implement it differently:

```
┌──────────────────┬──────────────────────────────────────────────┐
│ CNI              │ How it enforces NetworkPolicy                │
├──────────────────┼──────────────────────────────────────────────┤
│ Calico           │ iptables rules in custom chains              │
│                  │ (cali-xxx chains in filter table)            │
│                  │                                              │
│ Cilium           │ eBPF programs (no iptables for policy)       │
│                  │                                              │
│ Flannel          │ Does NOT support NetworkPolicy alone         │
│                  │ (pair with Calico for policy: Canal)         │
│                  │                                              │
│ Weave            │ iptables rules + custom chains               │
│                  │                                              │
│ kube-router      │ iptables + ipset                             │
└──────────────────┴──────────────────────────────────────────────┘
```

### Example — allow frontend pods to reach api pods on port 8080

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-frontend-to-api
spec:
  podSelector:
    matchLabels:
      role: api
  policyTypes:
  - Ingress
  ingress:
  - from:
    - podSelector:
        matchLabels:
          role: frontend
    ports:
    - protocol: TCP
      port: 8080
```

**Calico's resulting iptables chains (on the node where "api" pods run):**

```bash
# On a node running Calico
iptables-save -t filter | grep "^:cali" | head -10

# Chains like:
# :cali-FORWARD - [0:0]
# :cali-fw-caliXXXXXX - [0:0]    (from-workload: traffic leaving a pod)
# :cali-tw-caliXXXXXX - [0:0]    (to-workload: traffic arriving at a pod)

# Calico hooks into FORWARD before kube-proxy's rules:
# -A FORWARD -j cali-FORWARD
```

The `cali-tw-*` (to-workload) chains enforce ingress NetworkPolicy by matching
source pod IPs and allowing only what the policy defines. All other traffic is
dropped.

```bash
# Test:
kubectl exec frontend-pod -- curl -s --max-time 3 http://api-pod:8080  # OK
kubectl exec other-pod   -- curl -s --max-time 3 http://api-pod:8080  # BLOCKED
```

---

## 8. Phase 7: Inspecting Rules on a Live Node

### Step 1 — Get baseline rule counts

```bash
# SSH into a K8s node (or: kubectl debug node/<name> -it --image=busybox)

# How many rules does kube-proxy manage?
iptables-save | wc -l
# Small cluster: 100–500 rules. Large cluster: 10,000+

# How many KUBE chains?
iptables-save | grep "^:KUBE" | wc -l

# How many services are programmed?
iptables-save | grep "^-A KUBE-SERVICES" | wc -l
```

### Step 2 — Trace a specific Service

```bash
# Get a service's ClusterIP
kubectl get svc web -o jsonpath='{.spec.clusterIP}'
# Example: 10.96.45.123

# Find the KUBE-SVC chain for this service
iptables-save -t nat | grep "10.96.45.123"
# -A KUBE-SERVICES -d 10.96.45.123/32 -p tcp --dport 80 -j KUBE-SVC-ABCDEF

# Follow the load balancing chain
iptables-save -t nat | grep "KUBE-SVC-ABCDEF"

# Follow each endpoint to find the DNAT rules with pod IPs
iptables-save -t nat | grep "KUBE-SEP-"
```

### Step 3 — Correlate with kubectl

```bash
# What kube-proxy thinks the endpoints are:
kubectl get endpoints web
# NAME   ENDPOINTS                                      AGE
# web    10.244.1.5:80,10.244.2.8:80,10.244.3.2:80    5m

# These should match the DNAT destinations in KUBE-SEP chains
```

### Step 4 — Watch rules change in real-time

```bash
# Terminal 1: watch the nat table rule count
watch -n 2 'iptables-save -t nat | wc -l'

# Terminal 2: scale the deployment
kubectl scale deployment web --replicas=5
# Watch Terminal 1 — rule count increases as new KUBE-SEP chains are added

kubectl scale deployment web --replicas=2
# Rule count decreases
```

### Step 5 — Check counters on service chains

```bash
# List with packet counters
iptables -t nat -L KUBE-SERVICES -v -n | head -20

# Check a specific service chain
iptables -t nat -L KUBE-SVC-ABCDEF -v -n
# If counters are 0 → no traffic has matched (service unused or broken)
# If counters are increasing → traffic is flowing
```

---

## 9. Phase 8: Debugging Service Routing

### "Service not reachable" — systematic workflow

```
1. Is the Service defined correctly?
   kubectl get svc <name>
   kubectl describe svc <name>
   → Check: ClusterIP assigned? Ports correct? Selector matches pods?

2. Are there endpoints?
   kubectl get endpoints <name>
   → If EMPTY: selector doesn't match any running pods
   → kubectl get pods -l <selector-labels>

3. Is kube-proxy running?
   ps aux | grep kube-proxy
   systemctl status kube-proxy
   # Or in k3s/k0s: embedded in the agent

4. Are iptables rules present?
   iptables-save -t nat | grep <ClusterIP>
   → If missing: kube-proxy isn't programming rules
   → Check kube-proxy logs: journalctl -u kube-proxy

5. Is the pod actually healthy?
   kubectl exec <pod> -- curl -s localhost:8080
   → If this fails: the app inside the pod is broken

6. Can you reach the pod IP directly?
   kubectl exec <debug-pod> -- curl -s <pod-ip>:8080
   → If this works but ClusterIP doesn't: kube-proxy/iptables issue
   → If this also fails: CNI/networking issue

7. Is DNS resolving?
   kubectl exec <pod> -- nslookup <service-name>
   → Check CoreDNS: kubectl logs -n kube-system -l k8s-app=kube-dns
```

### Common problems

**Problem 1: "I added a DROP rule but K8s still routes traffic"**

```
Why: kube-proxy's rules are in the nat table (PREROUTING).
     Your DROP rule is probably in the filter table (INPUT/FORWARD).

The packet flow:
  1. PREROUTING (nat) → kube-proxy DNAT fires FIRST
  2. Routing decision → packet is now destined to pod IP
  3. FORWARD (filter) → your DROP rule matches original dst,
                        but dst is already rewritten by DNAT!

Fix: Match on the DNAT'd destination (pod IP), not the Service IP.
Or better: use NetworkPolicy instead of manual iptables on K8s nodes.
```

**Problem 2: "NodePort works from inside the cluster but not from outside"**

```
Checklist:
  1. Cloud Security Group allows the NodePort range (30000–32767)?
  2. NACL allows inbound + outbound ephemeral ports?
  3. Node's iptables has a DROP rule blocking the NodePort?
     → iptables -L INPUT -v -n (look for DROP on the NodePort)
  4. Node firewall (ufw/firewalld) is blocking it?
     → ufw status
     → firewall-cmd --list-all
```

**Problem 3: "Service endpoints keep appearing and disappearing"**

```
Readiness probe failing intermittently:
  kubectl describe pod <pod> | grep -A5 Readiness
  kubectl get events --field-selector involvedObject.name=<pod>

When a pod fails its readiness probe:
  1. kubelet marks pod as "not ready"
  2. Endpoint controller removes pod from Endpoints
  3. kube-proxy removes the KUBE-SEP chain for that pod
  4. Traffic stops going to that pod

Watch it happen:
  # Terminal 1:
  kubectl get endpoints <svc> -w

  # Terminal 2 (on the node):
  watch -n 1 'iptables-save -t nat | grep KUBE-SEP | wc -l'
```

**Problem 4: "Connections hang after scaling down"**

```
When a pod terminates:
  1. Pod enters Terminating state
  2. Endpoint removed → kube-proxy removes DNAT rule
  3. BUT: existing connections in conntrack still point to the old pod IP
  4. Those connections hang until conntrack entry expires

Inspect:
  conntrack -L | grep <old-pod-ip>

Fix (if needed):
  conntrack -D -d <old-pod-ip>    # Drops ALL connections to that IP
```

---

## 10. Phase 9: Beyond iptables — IPVS and eBPF

### Why iptables hits a wall at scale

```
Problem with iptables at scale:

  100 Services × 10 pods each = ~3,000 iptables rules in nat table

  Every rule update:
    1. kube-proxy reads ALL rules (iptables-save)
    2. Modifies the ruleset
    3. Writes ALL rules back (iptables-restore)
    4. Kernel re-evaluates entire chain on EVERY packet

  At 10,000+ Services:
    - Rule updates take seconds
    - Packet latency increases (linear chain traversal O(n))
    - CPU spikes during updates
```

### IPVS mode

```bash
# Check if your cluster uses IPVS:
kubectl get configmap kube-proxy -n kube-system -o yaml | grep mode
# mode: "ipvs"   ← IPVS
# mode: ""        ← iptables (default)

# On a node using IPVS:
ipvsadm -Ln
# Shows virtual servers (Services) and real servers (pod endpoints)
```

```
┌──────────────────┬───────────────────────┬──────────────────────┐
│                  │ iptables mode         │ IPVS mode            │
├──────────────────┼───────────────────────┼──────────────────────┤
│ Rule lookup      │ O(n) linear chain     │ O(1) hash table      │
│ Rule updates     │ Full rewrite          │ Incremental add/del  │
│ Load balancing   │ Random (probability)  │ rr, wrr, lc, sh, etc │
│ Scale            │ Degrades at ~5K svc   │ Handles 10K+ svc     │
│ Debugging        │ iptables-save/grep    │ ipvsadm -Ln          │
│ Still uses       │ iptables for          │ iptables for SNAT,   │
│ iptables?        │ everything            │ MASQUERADE, marks    │
└──────────────────┴───────────────────────┴──────────────────────┘
```

### eBPF / Cilium (the future)

```
eBPF programs run INSIDE the kernel at packet hook points.
They can intercept and redirect packets BEFORE iptables sees them.

Cilium (CNI using eBPF):
  - Replaces kube-proxy entirely (--set kubeProxyReplacement=true)
  - Service routing: eBPF at socket level or XDP
  - NetworkPolicy: eBPF programs, not iptables chains
  - Observability: Hubble (flow visibility without tcpdump)

When to care:
  - Clusters with 1,000+ Services or 10,000+ pods
  - Need L7 policy (HTTP method/path matching)
  - Need detailed per-flow observability
  - Your homelab: iptables mode is fine
```

### Your iptables knowledge transfers directly

```
iptables concept           │  eBPF equivalent
───────────────────────────┼────────────────────────────
DNAT (Service → Pod)       │  bpf_redirect / socket-level LB
SNAT/MASQUERADE            │  bpf_snat
conntrack                  │  CT map (eBPF hash map)
FORWARD chain              │  tc ingress/egress hooks
filter INPUT/OUTPUT        │  socket-level BPF programs
LOG                        │  Hubble flow events
NetworkPolicy chains       │  Per-endpoint BPF programs
```

---

## 11. Quick Reference

### Inspection commands (run on a K8s node)

```bash
# ── Rule counts ──
iptables-save -t nat | wc -l
iptables-save -t nat | grep "^:KUBE" | wc -l

# ── Find rules for a specific Service ──
SVC_IP=$(kubectl get svc <name> -o jsonpath='{.spec.clusterIP}')
iptables-save -t nat | grep "$SVC_IP"

# ── See all Service chains ──
iptables-save -t nat | grep "^-A KUBE-SERVICES" | head -20

# ── See endpoints for a service chain ──
iptables-save -t nat | grep "KUBE-SVC-ABCDEF"
iptables-save -t nat | grep "KUBE-SEP-"

# ── Check NodePort rules ──
iptables-save -t nat | grep "KUBE-NODEPORTS"

# ── Check MASQUERADE rules ──
iptables -t nat -L KUBE-POSTROUTING -v -n

# ── Watch conntrack for service traffic ──
conntrack -E | grep <service-port>

# ── Check if IPVS mode is active ──
ipvsadm -Ln 2>/dev/null || echo "Not using IPVS"
```

### Who manages what in iptables

```
┌──────────────────────────────────────────────────────────────────────┐
│ Component        │ What it manages in iptables     │ Table/Chain     │
├──────────────────┼─────────────────────────────────┼─────────────────┤
│ kube-proxy       │ Service → Pod DNAT              │ nat/KUBE-*      │
│                  │ MASQUERADE for cross-node        │ nat/POSTROUTING │
│                  │                                  │                 │
│ CNI (Calico)     │ NetworkPolicy enforcement        │ filter/cali-*   │
│                  │ Pod routing rules                │ nat (sometimes) │
│                  │                                  │                 │
│ Docker           │ Container port mapping (-p)      │ nat/DOCKER      │
│                  │ Bridge MASQUERADE                │ nat/POSTROUTING │
│                  │ Container isolation              │ filter/DOCKER-* │
│                  │                                  │                 │
│ You (sysadmin)   │ Node hardening, egress control   │ filter/INPUT    │
│                  │ Custom rules (not NetworkPolicy) │ filter/FORWARD  │
└──────────────────┴─────────────────────────────────┴─────────────────┘

Rule of thumb:
  - Don't fight kube-proxy's rules — use NetworkPolicy instead
  - For node-level security → iptables INPUT chain (or cloud SG)
  - For pod-level security → NetworkPolicy
  - For container-level customization → DOCKER-USER chain
```

### Mapping to skills

| Skill | Where you practiced |
|-------|---------------------|
| Read kube-proxy's KUBE-* chain hierarchy | Phase 2 |
| Trace a ClusterIP DNAT to pod | Phase 3 |
| Explain NodePort same-node vs cross-node | Phase 4 |
| Explain client IP loss and how to preserve it | Phase 5 |
| Find which CNI chain enforces NetworkPolicy | Phase 6 |
| Debug "Service not reachable" systematically | Phase 8 |
| Know when iptables mode is replaced | Phase 9 |

---

**Related labs:**
- [Docker-Networking-iptables.md](Docker-Networking-iptables.md) — Docker's iptables patterns
- [nat-lab.md](nat-lab.md) — DNAT, SNAT, MASQUERADE fundamentals
- [containers-kube-lab.md](containers-kube-lab.md) — hands-on K8s cluster setup

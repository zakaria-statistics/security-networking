# Containers & Kubernetes Networking Lab: How Docker/K8s Manipulate iptables
> See what happens under the hood when you create Services, expose ports, and route traffic

## Table of Contents
1. [Overview](#1-overview) - Why K8s uses iptables and what to expect
2. [Phase 1: Docker and iptables](#2-phase-1-docker-and-iptables) - Container port mapping internals
3. [Phase 2: Kubernetes Networking Model](#3-phase-2-kubernetes-networking-model) - Pod, Service, and Node
4. [Phase 3: kube-proxy iptables Mode](#4-phase-3-kube-proxy-iptables-mode) - ClusterIP under the hood
5. [Phase 4: NodePort Deep Dive](#5-phase-4-nodeport-deep-dive) - How external traffic reaches pods
6. [Phase 5: LoadBalancer and ExternalTrafficPolicy](#6-phase-5-loadbalancer-and-externaltrafficpolicy) - Preserving client IP
7. [Phase 6: Inspecting iptables on a K8s Node](#7-phase-6-inspecting-iptables-on-a-k8s-node) - Hands-on exploration
8. [Phase 7: NetworkPolicy and iptables](#8-phase-7-networkpolicy-and-iptables) - Pod-level firewalling
9. [Phase 8: Debugging Service Routing](#9-phase-8-debugging-service-routing) - "Service not reachable"
10. [Phase 9: CNI and Beyond iptables](#10-phase-9-cni-and-beyond-iptables) - eBPF, IPVS, Cilium
11. [Quick Reference](#11-quick-reference) - Inspection commands and cheat sheet

## Overview

Docker and Kubernetes **auto-generate iptables rules** to route traffic between
containers, pods, services, and the outside world. Understanding these rules is
critical for debugging "Service not reachable" and "I added DROP but K8s ignores it."

**What you'll learn:**
- How Docker `-p 8080:80` creates DNAT rules (exactly like nat-lab.md Phase 5)
- How kube-proxy programs ClusterIP, NodePort, and LoadBalancer via iptables
- How to read the auto-generated chains without getting overwhelmed
- When iptables rules you add conflict with K8s-managed rules
- Why eBPF/IPVS are replacing iptables in modern clusters

**Prerequisite knowledge:**
- DNAT, SNAT, MASQUERADE from nat-lab.md
- Stateful filtering (ESTABLISHED,RELATED) from iptables-lab.md
- Cloud security layers from cloud-security-lab.md (for context)

**Lab environment:** Your existing K8s homelab (or any single/multi-node cluster).

---

## 2. Phase 1: Docker and iptables

### What happens when you run `docker run -p 8080:80`

Docker creates iptables rules that are **exactly** the DNAT + MASQUERADE
pattern you built manually in nat-lab.md.

```
docker run -p 8080:80 nginx

Docker does (automatically):
  1. Creates a veth pair (container ↔ docker0 bridge)
  2. Assigns container an IP on the docker0 subnet (e.g., 172.17.0.2)
  3. Adds iptables DNAT rule in PREROUTING
  4. Adds iptables MASQUERADE rule in POSTROUTING
  5. Adds FORWARD rules to allow traffic
```

### Inspect Docker's iptables rules

```bash
# Before starting any container — snapshot the rules
iptables-save > /tmp/before-docker.rules

# Start a container with port mapping
docker run -d --name web-test -p 8080:80 nginx

# Snapshot again
iptables-save > /tmp/after-docker.rules

# See exactly what Docker added
diff /tmp/before-docker.rules /tmp/after-docker.rules
```

### What you'll see (annotated)

**nat table — DOCKER chain:**
```
-A PREROUTING -m addrtype --dst-type LOCAL -j DOCKER
-A OUTPUT ! -d 127.0.0.0/8 -m addrtype --dst-type LOCAL -j DOCKER
-A POSTROUTING -s 172.17.0.0/16 ! -o docker0 -j MASQUERADE

# The DOCKER chain:
-A DOCKER ! -i docker0 -p tcp -m tcp --dport 8080 \
   -j DNAT --to-destination 172.17.0.2:80
```

**Mapping to what you know from nat-lab.md:**
```
┌──────────────────────────────────────────────────────────────────┐
│  nat-lab.md (manual)             │  Docker (automatic)           │
├──────────────────────────────────┼───────────────────────────────┤
│  PREROUTING DNAT to W:80        │  PREROUTING → DOCKER chain    │
│  --to-destination .110:80       │  --to-destination 172.17.0.2  │
│                                  │                               │
│  POSTROUTING MASQUERADE          │  POSTROUTING MASQUERADE       │
│  -s .110 -o eth0                │  -s 172.17.0.0/16 ! -o docker0│
│                                  │                               │
│  FORWARD allow + ESTABLISHED    │  DOCKER-USER + DOCKER chains  │
│                                  │  in FORWARD                   │
└──────────────────────────────────┴───────────────────────────────┘
```

### The DOCKER-USER chain (important!)

```
Docker inserts its FORWARD rules AFTER the DOCKER-USER chain:

FORWARD chain:
  1. -j DOCKER-USER        ← YOUR rules go here
  2. -j DOCKER-ISOLATION
  3. ... Docker's own rules

If you add iptables rules directly to FORWARD, Docker may overwrite them
on container restart. Use DOCKER-USER for persistent custom rules:

# Block a specific IP from reaching any container:
iptables -I DOCKER-USER -s 10.0.0.99 -j DROP

# Restrict container access to a specific port only:
iptables -I DOCKER-USER -i eth0 -p tcp ! --dport 8080 -j DROP
```

### Verify with conntrack

```bash
# From another machine, curl the Docker host
curl http://<docker-host>:8080

# On the Docker host — check conntrack
conntrack -L | grep 8080

# Expected:
# tcp  6 ESTABLISHED src=<client> dst=<docker-host> sport=XXXXX dport=8080
#                    src=172.17.0.2 dst=<client> sport=80 dport=XXXXX [ASSURED]
#                    mark=0 use=1
```

### Cleanup

```bash
docker rm -f web-test
# Docker auto-removes its iptables rules when the container stops
```

---

## 3. Phase 2: Kubernetes Networking Model

### The three network planes

```
┌─────────────────────────────────────────────────────────────────────┐
│                     Kubernetes Cluster                               │
│                                                                      │
│  1. Pod Network (CNI-managed)                                       │
│     Every pod gets a unique IP. Pods can reach any other pod         │
│     directly by IP — no NAT between pods.                            │
│     Range: e.g., 10.244.0.0/16 (Flannel) or 10.42.0.0/16 (k3s)   │
│                                                                      │
│  2. Service Network (kube-proxy-managed)                            │
│     Virtual IPs (ClusterIP) that load-balance to pod endpoints.      │
│     Range: e.g., 10.96.0.0/12                                      │
│     These IPs exist ONLY in iptables rules — no interface has them. │
│                                                                      │
│  3. Node Network (physical/cloud)                                   │
│     The actual IPs of your nodes. NodePort and LoadBalancer          │
│     expose services on these IPs.                                    │
│     Range: e.g., 192.168.11.0/24 (your homelab)                    │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

### How traffic flows for each Service type

**ClusterIP (default):**
```
Pod A (10.244.1.5) wants to reach Service "my-svc" (10.96.0.10:80)

1. Pod A sends packet: src=10.244.1.5 dst=10.96.0.10:80
2. Packet hits iptables on the node (OUTPUT chain if same node, PREROUTING if different)
3. kube-proxy's DNAT rules rewrite dst to a real pod endpoint:
   dst → 10.244.2.8:8080  (one of the service's backend pods)
4. Packet is routed to the destination pod via CNI
5. Response follows reverse path, conntrack reverses the DNAT

No interface owns 10.96.0.10 — it's a "virtual" IP that ONLY exists
in iptables DNAT rules. Try to ping it — it won't respond to ICMP.
```

**NodePort:**
```
External client (192.168.11.50) → Node (192.168.11.109):30080

1. Packet arrives: src=.50 dst=.109:30080
2. PREROUTING → KUBE-SERVICES → KUBE-NODEPORTS
3. DNAT rewrites dst to pod endpoint: dst → 10.244.2.8:8080
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
1. Cloud creates an external LB (AWS ELB, Azure LB, etc.)
2. LB health-checks all nodes on the NodePort
3. LB sends traffic to a healthy node's NodePort
4. From there, it's identical to NodePort flow above
```

---

## 4. Phase 3: kube-proxy iptables Mode

### The chain hierarchy

kube-proxy creates a tree of custom iptables chains:

```
nat table:
  PREROUTING
    └─ KUBE-SERVICES          (entry point — matches all Service ClusterIPs)
         ├─ KUBE-SVC-XXXXX    (per-service chain — load balancing)
         │    ├─ KUBE-SEP-AAA (Service EndPoint — DNAT to pod 1)
         │    ├─ KUBE-SEP-BBB (DNAT to pod 2)
         │    └─ KUBE-SEP-CCC (DNAT to pod 3)
         ├─ KUBE-SVC-YYYYY    (another service)
         │    └─ ...
         └─ KUBE-NODEPORTS    (matches NodePort traffic)
              └─ KUBE-SVC-XXXXX (same service chain, reused)

  POSTROUTING
    └─ KUBE-POSTROUTING       (MASQUERADE for traffic leaving the node)

filter table:
  FORWARD
    └─ KUBE-FORWARD            (allow forwarded service traffic)
  INPUT
    └─ KUBE-FIREWALL           (drop invalid packets)
```

### Example: A Service with 3 replicas

```bash
kubectl create deployment web --image=nginx --replicas=3
kubectl expose deployment web --port=80 --type=ClusterIP
```

**What kube-proxy creates:**

```
# Service ClusterIP: 10.96.45.123
# Pod endpoints: 10.244.1.5:80, 10.244.2.8:80, 10.244.3.2:80

# In KUBE-SERVICES:
-A KUBE-SERVICES -d 10.96.45.123/32 -p tcp --dport 80 -j KUBE-SVC-ABCDEF

# In KUBE-SVC-ABCDEF (load balancing via probability):
-A KUBE-SVC-ABCDEF -m statistic --mode random --probability 0.33333
   -j KUBE-SEP-AAA
-A KUBE-SVC-ABCDEF -m statistic --mode random --probability 0.50000
   -j KUBE-SEP-BBB
-A KUBE-SVC-ABCDEF
   -j KUBE-SEP-CCC

# In each KUBE-SEP (the actual DNAT):
-A KUBE-SEP-AAA -p tcp -j DNAT --to-destination 10.244.1.5:80
-A KUBE-SEP-BBB -p tcp -j DNAT --to-destination 10.244.2.8:80
-A KUBE-SEP-CCC -p tcp -j DNAT --to-destination 10.244.3.2:80
```

**Load balancing math:**
```
Pod 1: probability 0.333  → 33.3% of traffic
Pod 2: probability 0.500  → 50% of remaining 66.7% = 33.3%
Pod 3: no probability     → everything else = 33.3%

Each pod gets ~33% of traffic. With 4 pods it would be 0.25, 0.333, 0.5, 1.0
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
# In KUBE-SERVICES — catch NodePort traffic:
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
                    Node-2 receives: src=Node-1 dst=10.244.2.8:80
                              │
                    Pod responds to Node-1 (because MASQUERADE)
                    Node-1 reverses NAT → sends back to client

This is the EXACT SAME pattern as the "return path problem" in nat-lab.md Phase 6!
MASQUERADE ensures the response goes back through Node-1 (the node the client hit).
```

### The source IP problem

```
Default NodePort behavior (externalTrafficPolicy: Cluster):

Client IP: 203.0.113.5
  → Node-1:30080
    → DNAT to Pod on Node-2
    → MASQUERADE: src becomes Node-1's IP
    → Pod sees src=Node-1, NOT 203.0.113.5

The pod (and your app's access logs) never see the real client IP.
This is the same trade-off from nat-lab.md Phase 6 (full NAT = lose client IP).
```

---

## 6. Phase 5: LoadBalancer and ExternalTrafficPolicy

### externalTrafficPolicy: Cluster (default)

```
Traffic can arrive at ANY node, gets DNAT'd to ANY pod, MASQUERADE applied.

Pros:
  - Even traffic distribution across all pods
  - Works even if the pod isn't on the receiving node

Cons:
  - Extra network hop when pod is on a different node
  - Client IP lost (MASQUERADE)
  - Double NAT (LB + kube-proxy)
```

### externalTrafficPolicy: Local

```yaml
apiVersion: v1
kind: Service
metadata:
  name: web
spec:
  type: NodePort    # or LoadBalancer
  externalTrafficPolicy: Local
  ports:
  - port: 80
    nodePort: 30080
  selector:
    app: web
```

**What changes in iptables:**
```
With policy=Local, kube-proxy adds a rule:
  - If this node has NO local pods for this service → DROP the NodePort traffic
  - If this node HAS local pods → DNAT to local pods only, NO MASQUERADE

# The KUBE-SVC chain changes behavior:
-A KUBE-SVC-ABCDEF -m addrtype --src-type LOCAL -j KUBE-SVC-ABCDEF-local
-A KUBE-SVC-ABCDEF -j KUBE-XLB-ABCDEF    # XLB = external load balancing

# KUBE-XLB only DNATs to local endpoints:
-A KUBE-XLB-ABCDEF -m comment --comment "no local endpoints" -j KUBE-MARK-DROP
# (if no local pods exist on this node)
# OR:
-A KUBE-XLB-ABCDEF -j KUBE-SEP-AAA    # only local pod(s)
```

```
Behavior comparison:

                    policy=Cluster              policy=Local
                    ┌─────────────────┐         ┌─────────────────┐
Client IP visible?  │ NO (MASQUERADE) │         │ YES (no SNAT)   │
                    └─────────────────┘         └─────────────────┘
Traffic distribution│ Even across all  │         │ Only to local   │
                    │ pods             │         │ pods (uneven)   │
                    └─────────────────┘         └─────────────────┘
Extra hop?          │ YES (cross-node) │         │ NO (local only) │
                    └─────────────────┘         └─────────────────┘
Node without pods?  │ Still receives   │         │ Health check    │
                    │ traffic          │         │ fails → LB skips│
                    └─────────────────┘         └─────────────────┘
```

---

## 7. Phase 6: Inspecting iptables on a K8s Node

### Hands-on: Explore the rules

**Step 1 — Get baseline counts**

```bash
# SSH into a K8s node (or use kubectl debug node/<name>)

# How many rules does kube-proxy manage?
iptables-save | wc -l
# Typical: 100-500 rules for a small cluster, 10,000+ for large clusters

# How many KUBE chains exist?
iptables-save | grep "^:KUBE" | wc -l

# How many services are programmed?
iptables-save | grep "KUBE-SVC" | grep "^-A KUBE-SERVICES" | wc -l
```

**Step 2 — Trace a specific Service**

```bash
# Get a service's ClusterIP
kubectl get svc web -o jsonpath='{.spec.clusterIP}'
# Example: 10.96.45.123

# Find the KUBE-SVC chain for this service
iptables-save -t nat | grep "10.96.45.123"
# Output: -A KUBE-SERVICES -d 10.96.45.123/32 -p tcp --dport 80 -j KUBE-SVC-ABCDEF

# Follow the chain — see the load balancing
iptables-save -t nat | grep "KUBE-SVC-ABCDEF"

# Follow each endpoint
iptables-save -t nat | grep "KUBE-SEP-"
# Shows the DNAT rules with actual pod IPs
```

**Step 3 — Correlate with kubectl**

```bash
# What kube-proxy thinks the endpoints are:
kubectl get endpoints web
# NAME   ENDPOINTS                                      AGE
# web    10.244.1.5:80,10.244.2.8:80,10.244.3.2:80    5m

# These should match the DNAT destinations in KUBE-SEP chains
```

**Step 4 — Watch rules change in real-time**

```bash
# Terminal 1: watch the nat table rule count
watch -n 2 'iptables-save -t nat | wc -l'

# Terminal 2: scale the deployment
kubectl scale deployment web --replicas=5

# Watch Terminal 1 — rule count increases as new KUBE-SEP chains are added
# Scale back down:
kubectl scale deployment web --replicas=2
# Rule count decreases
```

**Step 5 — Check counters on service rules**

```bash
# List kube-proxy's NAT rules with packet counters
iptables -t nat -L KUBE-SERVICES -v -n | head -20

# Check a specific service chain
iptables -t nat -L KUBE-SVC-ABCDEF -v -n
# pkts bytes target ...
# If counters are 0, no traffic has matched (service unused or broken)
# If counters are increasing, traffic is flowing through
```

---

## 8. Phase 7: NetworkPolicy and iptables

### What NetworkPolicy does

NetworkPolicy is the Kubernetes-native way to firewall pods.

```
Without NetworkPolicy:
  Every pod can talk to every other pod (flat network, no isolation)

With NetworkPolicy:
  You define allow-lists per pod (ingress and egress rules)
  Everything not explicitly allowed is denied (for pods selected by a policy)
```

### How it maps to iptables

NetworkPolicy is enforced by the **CNI plugin**, not kube-proxy.
Different CNIs implement it differently:

```
┌──────────────┬──────────────────────────────────────────────┐
│ CNI          │ How it enforces NetworkPolicy                │
├──────────────┼──────────────────────────────────────────────┤
│ Calico       │ iptables rules in custom chains              │
│              │ (cali-xxx chains in filter table)            │
│              │                                              │
│ Cilium       │ eBPF programs (no iptables for policy)       │
│              │                                              │
│ Flannel      │ Does NOT support NetworkPolicy alone         │
│              │ (pair with Calico for policy: Canal)         │
│              │                                              │
│ Weave        │ iptables rules + custom chains               │
│              │                                              │
│ kube-router  │ iptables + ipset                             │
└──────────────┴──────────────────────────────────────────────┘
```

### Example: Calico's iptables chains

```bash
# On a node running Calico, inspect filter table:
iptables-save -t filter | grep "^:cali" | head -10

# You'll see chains like:
# :cali-FORWARD - [0:0]
# :cali-INPUT - [0:0]
# :cali-OUTPUT - [0:0]
# :cali-fw-caliXXXXXX - [0:0]     (per-endpoint chains)
# :cali-tw-caliXXXXXX - [0:0]     (to-workload chains)

# Calico's FORWARD chain:
# -A FORWARD -j cali-FORWARD
# Calico hooks into FORWARD before any other rules
```

### NetworkPolicy example with iptables inspection

```yaml
# Allow only pods with label "role=frontend" to reach pods with "role=api" on port 8080
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-frontend-to-api
  namespace: default
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

```bash
# Apply the policy
kubectl apply -f network-policy.yaml

# On the node where an "api" pod runs, inspect Calico's rules:
iptables-save -t filter | grep "cali-tw" | head -20
# You'll see rules that match source pod IPs and allow TCP 8080
# All other traffic to the "api" pod is dropped

# Test:
# From a "frontend" pod:
kubectl exec frontend-pod -- curl -s --max-time 3 http://api-pod:8080  # WORKS

# From a random pod:
kubectl exec other-pod -- curl -s --max-time 3 http://api-pod:8080     # BLOCKED
```

---

## 9. Phase 8: Debugging Service Routing

### "Service not reachable" — systematic diagnosis

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
   # On the node:
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

**Problem 1: "I added an iptables DROP rule but K8s still routes traffic"**

```
Why: kube-proxy's rules are in the nat table (PREROUTING).
Your DROP rule is probably in the filter table (INPUT/FORWARD).

The packet flow:
  1. PREROUTING (nat) → kube-proxy DNAT fires FIRST
  2. Routing decision → packet is now destined to pod IP
  3. FORWARD (filter) → your DROP rule matches original dst, but dst is already rewritten!

Fix: Match on the DNAT'd destination (pod IP), not the Service IP.
Or better: use NetworkPolicy instead of manual iptables on K8s nodes.
```

**Problem 2: "NodePort works from inside the cluster but not from outside"**

```
Checklist:
  1. Cloud Security Group allows the NodePort range (30000-32767)?
  2. NACL allows inbound + outbound ephemeral ports?
  3. Node's iptables (outside kube-proxy) has a DROP rule blocking it?
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
  5. Pod recovers → endpoint re-added → KUBE-SEP re-created

Watch it happen:
  # Terminal 1:
  kubectl get endpoints <svc> -w

  # Terminal 2 (on the node):
  watch -n 1 'iptables-save -t nat | grep KUBE-SEP | wc -l'
```

**Problem 4: "Connections hang after scaling down"**

```
When a pod is terminated:
  1. Pod enters Terminating state
  2. Endpoint removed → kube-proxy removes DNAT rule
  3. BUT: existing connections in conntrack still point to the old pod IP
  4. Those connections may hang until conntrack entry expires

Inspect:
  conntrack -L | grep <old-pod-ip>

Fix (if needed):
  conntrack -D -d <old-pod-ip>    # Delete stale entries
  # Be careful: this drops ALL connections to that IP
```

---

## 10. Phase 9: CNI and Beyond iptables

### Why iptables is being replaced

```
Problem with iptables at scale:

  100 Services × 10 pods each = ~3,000 iptables rules in nat table

  Every rule update:
    1. kube-proxy reads ALL rules (iptables-save)
    2. Modifies the ruleset
    3. Writes ALL rules back (iptables-restore)
    4. Kernel re-evaluates the entire chain on every packet

  At 10,000+ Services:
    - Rule updates take seconds
    - Packet latency increases (linear chain traversal)
    - CPU usage spikes during updates
```

### IPVS mode (kube-proxy alternative)

```bash
# Check if your cluster uses IPVS:
kubectl get configmap kube-proxy -n kube-system -o yaml | grep mode
# mode: "ipvs"   ← IPVS
# mode: ""        ← iptables (default)

# On a node using IPVS:
ipvsadm -Ln
# Shows virtual servers (Services) and real servers (Pod endpoints)
```

```
┌──────────────────┬──────────────────────────────────────────────┐
│                  │ iptables mode         │ IPVS mode            │
├──────────────────┼───────────────────────┼──────────────────────┤
│ Rule lookup      │ O(n) linear chain     │ O(1) hash table      │
│ Rule updates     │ Full rewrite          │ Incremental add/del  │
│ Load balancing   │ Random (probability)  │ rr, wrr, lc, sh, etc│
│ Scale            │ Degrades at ~5K svc   │ Handles 10K+ svc    │
│ Debugging        │ iptables-save/grep    │ ipvsadm -Ln          │
│ Still uses       │ iptables for everything│ iptables for SNAT,  │
│ iptables?        │                       │ MASQUERADE, marks    │
└──────────────────┴───────────────────────┴──────────────────────┘
```

### eBPF / Cilium (the future)

```
eBPF (extended Berkeley Packet Filter):
  - Programs that run INSIDE the kernel at various hook points
  - Can intercept and redirect packets BEFORE iptables even sees them
  - No iptables chains to traverse — direct kernel-level routing

Cilium (CNI using eBPF):
  - Replaces kube-proxy entirely (--set kubeProxyReplacement=true)
  - Service routing: eBPF program at socket level or XDP
  - NetworkPolicy: eBPF programs, not iptables chains
  - Observability: Hubble (flow visibility without tcpdump)

When to care:
  - Clusters with 1,000+ Services or 10,000+ pods
  - Need for advanced L7 policy (HTTP method/path matching)
  - Need for detailed flow observability
  - Your homelab: iptables mode is fine, but understanding eBPF helps in interviews
```

### Mapping to iptables concepts

```
Even with eBPF/Cilium, the CONCEPTS are the same:

iptables concept           │  eBPF equivalent
───────────────────────────┼────────────────────────
DNAT (Service → Pod)       │  bpf_redirect / socket-level LB
SNAT/MASQUERADE            │  bpf_snat
conntrack                  │  CT map (eBPF hash map)
FORWARD chain              │  tc ingress/egress hooks
filter INPUT/OUTPUT        │  socket-level BPF programs
LOG                        │  Hubble flow events
NetworkPolicy chains       │  Per-endpoint BPF programs

Your iptables knowledge translates 1:1 to understanding what eBPF does.
The "what" is the same — only the "how" (implementation) changes.
```

---

## 11. Quick Reference

### Inspection commands (run on a K8s node)

```bash
# ── How many rules does kube-proxy manage? ──
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
iptables-save -t nat | grep "KUBE-POSTROUTING" -A5

# ── Watch conntrack for service traffic ──
conntrack -E | grep <service-port>

# ── Check if IPVS mode is active ──
ipvsadm -Ln 2>/dev/null || echo "Not using IPVS"

# ── Docker-specific ──
iptables-save -t nat | grep DOCKER
iptables -L DOCKER-USER -v -n
```

### The big picture: iptables in the K8s stack

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
│ kubelet          │ (none directly)                  │                 │
│                  │                                  │                 │
│ You (sysadmin)   │ Node hardening, egress control   │ filter/INPUT    │
│                  │ Custom rules in DOCKER-USER      │ filter/FORWARD  │
└──────────────────┴─────────────────────────────────┴─────────────────┘

Rule of thumb:
  - Don't fight kube-proxy's rules — use NetworkPolicy instead
  - For node-level security → iptables INPUT chain (or cloud SG)
  - For pod-level security → NetworkPolicy
  - For container-level customization → DOCKER-USER chain
```

### Mapping to roadmap checklist

After this lab you can:

| Checklist Item | Where You Practiced |
|----------------|---------------------|
| Explain how Docker manipulates iptables | Phase 1 |
| Explain how Kubernetes manipulates iptables | Phases 2-5 |
| Debug "Service not reachable" | Phase 8 |
| Inspect kube-proxy rules on a live node | Phase 6 |
| Understand NetworkPolicy enforcement | Phase 7 |
| Know when/why eBPF replaces iptables | Phase 9 |
| Build hardened nodes without breaking cluster networking | Phase 8 (Problem 1) |

**Previous labs:**
- [iptables-lab.md](iptables-lab.md) — Stateful firewall basics
- [nat-lab.md](nat-lab.md) — NAT, DNAT, MASQUERADE
- [cloud-security-lab.md](cloud-security-lab.md) — SG, NACL, layered security
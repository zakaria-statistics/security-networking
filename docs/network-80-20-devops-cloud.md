# Network 80/20 for DevOps and Cloud

This is the core 20% of networking knowledge that handles most cloud/DevOps incidents.
`iptables` is included as a first-class concept, not an optional detail.

## The Real 20% Concepts

## 1) DNS and Service Discovery
- Know: Resolver path, A/AAAA/CNAME, TTL and cache behavior.
- Why: Many "service down" incidents are stale or wrong DNS.
- Check:
  - `dig <name> +short`
  - `dig <name>`

## 2) CIDR, Subnets, and IP Planning
- Know: Private CIDRs, subnet sizing, overlap impact.
- Why: Overlap breaks VPC peering, VPN, cluster networking.
- Check:
  - `ip -br a`
  - `ipcalc <cidr>`

## 3) Routing and Return Path
- Know: Longest-prefix match, default route, asymmetric routing.
- Why: Request goes out, reply never returns.
- Check:
  - `ip route`
  - `traceroute <ip>`

## 4) TCP/UDP Ports and Listening Sockets
- Know: Process bind address, open/listening ports, TCP handshake basics.
- Why: App is up but unreachable on the expected port/interface.
- Check:
  - `ss -lntup`
  - `nc -vz <host> <port>`
  - `curl -v http://<host>:<port>/health`

## 5) `iptables` Packet Filtering (Core Linux 20%)
- Know: `INPUT`, `OUTPUT`, `FORWARD` chains, first-match behavior, default policy, state tracking (`ESTABLISHED,RELATED`).
- Why: Most Linux host/node traffic failures are rule-order or missing return-traffic rules.
- Cloud mapping: Host firewall on VM nodes, Kubernetes node dataplane, container bridges.
- Check:
  - `iptables -S`
  - `iptables -L -n -v --line-numbers`
- Typical fixes: Insert rule in correct order, allow return traffic, tighten overly broad allow rules.

## 6) NAT with `iptables` (`SNAT`/`DNAT`/`MASQUERADE`)
- Know: `nat` table and `PREROUTING`, `POSTROUTING`, `OUTPUT`.
- Why: Private workloads fail egress/ingress if translation is wrong.
- Cloud mapping: NAT Gateway/Cloud NAT + host-level NAT on Linux nodes.
- Check:
  - `iptables -t nat -S`
  - `ip route get 8.8.8.8`
  - `curl ifconfig.me`
- Typical fixes: Correct SNAT on egress, DNAT target mapping, avoid port exhaustion.

## 7) Cloud Firewalls and LBs (Layered Controls)
- Know: SG/NSG/NACL behavior and LB health checks.
- Why: Host `iptables` can be correct but cloud-layer policy still blocks traffic.
- Check:
  - Validate SG/NSG/NACL + route table + target group health together.
  - `curl -I https://<service>/health`

## 8) TLS and Endpoint Identity
- Know: Cert chain, SAN/hostname, SNI, expiry.
- Why: TLS errors are often misread as pure network failures.
- Check:
  - `openssl s_client -connect <host>:443 -servername <host>`
  - `curl -vk https://<host>`

## 9) Observability and Proof
- Know: Where packet stops: DNS, route, firewall, NAT, LB, app.
- Why: Prevents guessing and shortens MTTR.
- Check:
  - `tcpdump -ni any host <ip>`
  - `mtr -rw <host>`
  - Flow logs / LB logs / node metrics

## 80/20 Incident Flow (Use in Order)
1. DNS returns expected IP.
2. Route exists and return path is valid.
3. Target port is listening.
4. `iptables` filter rules allow request and return traffic.
5. `iptables` NAT rules are correct for ingress/egress.
6. Cloud firewall + LB health checks pass.
7. TLS handshake validates cert and hostname.
8. Use packet capture/flow logs to prove the exact drop point.

## High-Value Command Set
```bash
# DNS
dig <name> +short

# Routes and sockets
ip route
ss -lntup
nc -vz <host> <port>

# iptables (filter + nat)
iptables -S
iptables -L -n -v --line-numbers
iptables -t nat -S

# path and packet proof
traceroute <ip>
tcpdump -ni any host <ip>

# TLS
openssl s_client -connect <host>:443 -servername <host>
```

## Learn First (Priority)
1. DNS
2. CIDR/subnets
3. Routing/return path
4. Ports/sockets
5. `iptables` filter chains
6. `iptables` NAT
7. Cloud SG/NSG/NACL + LB checks
8. TLS basics
9. Packet capture + flow logs

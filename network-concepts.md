# Networking Concepts Demystified
> Clarifying the fuzzy, overloaded, and confusing terms in networking

## Table of Contents
1. [Physical vs Virtual](#1-physical-vs-virtual) - What's real hardware vs software abstraction
2. [Interface, Port, Socket](#2-interface-port-socket) - Three words, six meanings each
3. [Host, Node, Endpoint, Machine](#3-host-node-endpoint-machine) - Naming the "thing on the network"
4. [Routing vs Forwarding vs Bridging](#4-routing-vs-forwarding-vs-bridging) - How packets move between networks
5. [Protocol, Service, Daemon](#5-protocol-service-daemon) - Rules vs software vs running process
6. [Address Types and Scopes](#6-address-types-and-scopes) - IP, MAC, loopback, broadcast, multicast
7. [Network vs Subnet vs VLAN vs VPC](#7-network-vs-subnet-vs-vlan-vs-vpc) - Boundaries and segmentation
8. [NAT, Proxy, Gateway, Firewall](#8-nat-proxy-gateway-firewall) - Middleboxes that touch your traffic
9. [Layers and Encapsulation](#9-layers-and-encapsulation) - Why OSI/TCP-IP layers matter practically
10. [Names That Lie](#10-names-that-lie) - Misleading conventions in networking
11. [Virtual Networking Zoo](#11-virtual-networking-zoo) - veth, bridge, tap, tun, vxlan, macvlan

---

## 1. Physical vs Virtual

The #1 source of confusion: the same word ("interface", "network", "switch") can
mean hardware you can touch OR a software construct that behaves the same way.

### The rule

```
Physical = electrons moving through copper/fiber/radio waves
Virtual  = software pretending to be that physical thing
           (kernel data structures, not hardware)

The behavior is identical. The packet doesn't know the difference.
```

### Examples

```
┌──────────────────────┬─────────────────────────┬───────────────────────────┐
│ Concept              │ Physical                │ Virtual                    │
├──────────────────────┼─────────────────────────┼───────────────────────────┤
│ Network interface    │ eth0 (NIC card)         │ veth0, docker0, lo        │
│ Switch               │ Cisco switch on rack    │ Linux bridge (brctl)      │
│ Router               │ Box with multiple NICs  │ Linux with ip_forward=1   │
│ Network              │ Cables + switches       │ VPC, overlay (VXLAN)      │
│ Cable                │ Cat6 cable              │ veth pair (virtual cable) │
│ NIC                  │ PCI network card        │ virtio-net (KVM), SR-IOV  │
│ Firewall             │ Palo Alto appliance     │ iptables, nftables, NSG   │
└──────────────────────┴─────────────────────────┴───────────────────────────┘
```

### Why this matters

```
When someone says "add a network interface":
  - On bare metal: plug in a NIC card, assign it in the OS
  - On a VM: add a virtual NIC in the hypervisor
  - In Kubernetes: the CNI creates a veth pair
  - In Docker: docker network connect
  - In cloud: attach an ENI (AWS) or NIC (Azure)

All of these result in: a new device in `ip link show`.
The commands to configure them are IDENTICAL regardless of physical/virtual.
```

### How to tell what's physical vs virtual

```bash
# List all interfaces — physical and virtual
ip link show

# Check if an interface is virtual
ls -la /sys/class/net/<iface>/device 2>/dev/null
# Physical: shows a symlink to PCI device (e.g., ../../../0000:00:03.0)
# Virtual:  "No such file" — it's software-only

# Or check the type
ethtool -i <iface> | grep driver
# Physical: e1000, ixgbe, mlx5_core, etc.
# Virtual:  veth, bridge, tun, vxlan
```

---

## 2. Interface, Port, Socket

Three of the most overloaded words in all of networking.

### "Interface"

```
Meaning 1 — Network interface (Layer 2/3)
  A named attachment point to a network. Has a MAC address.
  Examples: eth0, ens18, wlan0, docker0, lo
  View: ip link show

Meaning 2 — Loopback interface
  A special software interface that loops back to the same machine.
  lo = 127.0.0.1. Traffic never leaves the host.
  Used by: local DNS resolvers, databases, inter-process communication

Meaning 3 — API/software interface
  "The interface between two systems" — not a network device at all.
  Example: "REST API interface", "CLI interface"
```

### "Port"

```
Meaning 1 — TCP/UDP port number (Layer 4)
  A 16-bit number (0-65535) identifying a specific service on a host.
  NOT a physical thing. It's a field in the TCP/UDP header.
  Port 80 = HTTP, Port 22 = SSH, Port 443 = HTTPS
  View: ss -tlnp

Meaning 2 — Physical port (Layer 1)
  The hole in a switch/router/server where you plug a cable.
  "Plug into port 24 on the switch."

Meaning 3 — Docker port mapping
  docker run -p 8080:80  → "map host port 8080 to container port 80"
  This creates a DNAT iptables rule. "Port" here means TCP port number.

Meaning 4 — Kubernetes port (in a Service spec)
  port: 80          → the Service's port (ClusterIP listens here)
  targetPort: 8080  → the container's port (where the app runs)
  nodePort: 30080   → the node's port (external access)
  Three different "ports" in one YAML block.
```

### "Socket"

```
Meaning 1 — Network socket (Layer 4)
  A unique connection identified by: (protocol, src_ip, src_port, dst_ip, dst_port)
  Created when a program calls socket() + connect() or accept()
  View: ss -tnp (active sockets)

Meaning 2 — Unix domain socket (IPC, no network)
  A file on disk used for inter-process communication on the SAME host.
  Example: /var/run/docker.sock, /var/run/mysqld/mysqld.sock
  View: ss -xlnp (unix sockets)

Meaning 3 — Physical socket
  "CPU socket" — the slot on the motherboard. Nothing to do with networking.
```

### Quick disambiguation

```
"Open port 80"     = allow TCP connections to port number 80
"Plug into port 3" = physical cable into switch port 3
"Socket file"       = unix domain socket (local IPC)
"Socket connection" = TCP/UDP network connection (5-tuple)
"Interface eth0"   = network device (has MAC + IP)
"API interface"    = software boundary (not a network device)
```

---

## 3. Host, Node, Endpoint, Machine

All roughly mean "a thing on the network" — but the context changes the meaning.

```
┌──────────────┬─────────────────────────────────────────────────────────┐
│ Term         │ What it usually means                                   │
├──────────────┼─────────────────────────────────────────────────────────┤
│ Host         │ Any device with an IP address.                          │
│              │ "Host" in /etc/hosts means "a machine I can reach."     │
│              │ In Docker: "the host" = the machine running Docker.     │
│              │ In networking: any device that is NOT a router/switch.  │
│              │                                                         │
│ Node         │ Kubernetes: a worker machine (VM or bare metal).        │
│              │ General: any device in a network graph.                  │
│              │ "Node" emphasizes being part of a cluster/topology.     │
│              │                                                         │
│ Endpoint     │ The final destination of traffic.                       │
│              │ In K8s: a pod IP:port backing a Service.                │
│              │ In API: the URL you call (https://api.example.com/v1).  │
│              │ In VPN: the remote side of the tunnel.                  │
│              │                                                         │
│ Machine      │ A physical or virtual computer.                         │
│              │ "Machine" avoids the ambiguity of host/node/server.     │
│              │                                                         │
│ Server       │ A machine that SERVES something (web server, DB server).│
│              │ Or: the role in client-server communication.             │
│              │ Confusing because: a "server" can also be a "client"    │
│              │ (e.g., your web server is a client to the database).    │
│              │                                                         │
│ Instance     │ Cloud term for a VM. "EC2 instance" = a virtual machine.│
│              │ Avoids saying "server" (which implies a role).           │
│              │                                                         │
│ Peer         │ The other side of a connection. Your host talks to      │
│              │ its "peer." Used in BGP, VPN, P2P contexts.             │
│              │                                                         │
│ Target       │ In iptables: the action (ACCEPT, DROP, DNAT).           │
│              │ In load balancing: a backend server receiving traffic.   │
│              │ In security: a machine being tested/attacked.            │
└──────────────┴─────────────────────────────────────────────────────────┘
```

### The "host" confusion in Docker

```
"host network" = the Docker container uses the host machine's network stack directly
                 (no bridge, no NAT, no port mapping)

"host port"    = port on the machine running Docker (not inside a container)

"hostname"     = the name assigned to a machine (what `hostname` command returns)
                 Containers get their own hostname (container ID by default)

docker run --network host     → container shares host's network namespace
docker run -p 8080:80         → maps HOST port 8080 to CONTAINER port 80
docker run --hostname myapp   → sets the container's hostname (cosmetic)
```

---

## 4. Routing vs Forwarding vs Bridging

Three different ways packets move, often confused.

### Routing (Layer 3 — IP addresses)

```
Routing = deciding WHERE to send a packet based on its destination IP.
The routing table maps destination networks to next hops.

ip route show:
  default via 192.168.1.1 dev eth0          → "anything unknown, send to gateway"
  10.244.0.0/16 via 10.244.1.1 dev flannel  → "pod network, send via flannel"
  192.168.1.0/24 dev eth0                   → "local subnet, send directly"

A router is any device that:
  1. Has ip_forward=1
  2. Receives a packet NOT destined for itself
  3. Looks up the destination in its routing table
  4. Sends the packet out the correct interface

Linux is a router if you enable: sysctl -w net.ipv4.ip_forward=1
```

### Forwarding (Layer 3 — the action of passing packets through)

```
Forwarding = the ACT of sending a packet that's not for you to the next hop.
Routing determines WHERE. Forwarding is the execution.

In iptables:
  FORWARD chain = packets passing THROUGH this machine (not for INPUT, not from OUTPUT)

  Packet for 10.244.2.5 arrives at a node with ip_forward=1:
    → routing says "send via flannel interface"
    → FORWARD chain evaluates rules
    → packet exits via the flannel interface

  If ip_forward=0: the kernel silently DROPs the packet (never reaches FORWARD chain)
```

### Bridging (Layer 2 — MAC addresses)

```
Bridging = connecting two network segments at Layer 2.
A bridge looks at MAC addresses, NOT IP addresses.
It's like a virtual switch.

Example: docker0 bridge
  ┌─────────────────────────────────────┐
  │  docker0 bridge (Layer 2 switch)    │
  │                                     │
  │  vethABC ──── container-1           │
  │  vethDEF ──── container-2           │
  │  vethGHI ──── container-3           │
  └─────────────────────────────────────┘

  Container-1 sends a packet to container-2:
    1. Packet arrives at docker0 bridge via vethABC
    2. Bridge looks at destination MAC address
    3. Bridge forwards to vethDEF (learned which MAC is on which port)
    4. No routing needed — same Layer 2 segment

Bridging vs routing:
  Bridge: "I know which MAC is on which port" (Layer 2, same network)
  Router: "I know which network is via which interface" (Layer 3, across networks)
```

### Combined example

```
Container-1 (on docker0) pings 8.8.8.8:

1. Container sends to docker0 bridge (Layer 2 — bridging)
2. docker0 has an IP — packet hits the host's routing table (Layer 3 — routing)
3. Routing says: default via eth0
4. FORWARD chain: matches → ACCEPT (Layer 3 — forwarding)
5. POSTROUTING: MASQUERADE → src rewritten (NAT)
6. Packet exits eth0 toward the gateway

Bridging got the packet from container to host.
Routing decided it should go to the internet.
Forwarding passed it through the iptables FORWARD chain.
NAT rewrote the source address.
```

---

## 5. Protocol, Service, Daemon

### Protocol

```
A protocol is a set of RULES for communication. It's not software.
It's a specification document that says "messages must look like THIS."

Layer 4 protocols:
  TCP = reliable, ordered, connection-oriented (SYN → SYN-ACK → ACK)
  UDP = unreliable, unordered, connectionless (fire and forget)

Layer 7 protocols:
  HTTP  = rules for web requests/responses (GET /path, 200 OK)
  SSH   = rules for encrypted remote shell sessions
  DNS   = rules for name → IP resolution queries
  SMTP  = rules for sending email

A protocol defines the format. Software implements it.
nginx implements HTTP. OpenSSH implements SSH. Neither IS the protocol.
```

### Service

```
"Service" is the most overloaded word in computing:

In systemd:
  A unit file that manages a daemon.
  systemctl status nginx.service → is nginx running?

In Kubernetes:
  A virtual IP (ClusterIP) + port that load-balances to pods.
  kubectl get svc → shows Services

In networking:
  A process listening on a port.
  "SSH service" = sshd daemon listening on port 22
  "Web service" = nginx listening on port 80

In cloud:
  Anything the cloud provider offers.
  "Azure App Service" "AWS S3 Service"

In architecture:
  A discrete component in a microservices system.
  "The auth service handles authentication."
```

### Daemon

```
A daemon is a background process with no terminal attached.
Named after the Greek concept (helper spirit), NOT "demon."

Naming convention: often ends in 'd'
  sshd    = SSH daemon
  nginx   = web daemon (exception to the 'd' convention)
  dockerd = Docker daemon
  kubelet = Kubernetes node agent (not called a daemon, but behaves like one)
  systemd = init daemon (manages all other daemons)

Daemon vs service:
  Daemon  = the running process
  Service = the systemd unit that manages the daemon

  systemctl start nginx    ← tells the SERVICE to start the DAEMON
  ps aux | grep nginx      ← shows the DAEMON process
  ss -tlnp | grep :80      ← shows the DAEMON listening on a port
```

---

## 6. Address Types and Scopes

### IP address scopes

```
┌───────────────────┬───────────────────────────────────────────────────┐
│ Range             │ What it is                                        │
├───────────────────┼───────────────────────────────────────────────────┤
│ 127.0.0.0/8       │ Loopback — never leaves the machine.             │
│                   │ 127.0.0.1 = "myself." Used for local services.   │
│                   │                                                   │
│ 10.0.0.0/8        │ Private (RFC 1918). Not routable on internet.    │
│ 172.16.0.0/12     │ Private. Used in VPCs, home networks, labs.      │
│ 192.168.0.0/16    │ Private. Your home router probably uses this.    │
│                   │                                                   │
│ 169.254.0.0/16    │ Link-local. Auto-assigned when DHCP fails.       │
│                   │ Only valid on the local network segment.          │
│                   │ AWS uses 169.254.169.254 for metadata service.   │
│                   │                                                   │
│ 0.0.0.0           │ "All interfaces" when binding a socket.          │
│                   │ ss -tlnp showing 0.0.0.0:80 = listening on all.  │
│                   │ In routing: 0.0.0.0/0 = "any destination" (default)│
│                   │                                                   │
│ 255.255.255.255   │ Broadcast — sent to ALL hosts on the local net.  │
│                   │                                                   │
│ 224.0.0.0/4       │ Multicast — sent to a GROUP of hosts.            │
│                   │ Used by: OSPF, mDNS, IGMP                        │
│                   │                                                   │
│ Everything else   │ Public — routable on the internet.                │
│                   │ Assigned by IANA → RIRs → ISPs → you.           │
└───────────────────┴───────────────────────────────────────────────────┘
```

### MAC address

```
48-bit address burned into the NIC (Layer 2).
Format: aa:bb:cc:dd:ee:ff

First 3 bytes (OUI) = manufacturer (e.g., 00:50:56 = VMware)
Last 3 bytes = unique per device

Virtual MACs:
  Hypervisors generate random MACs for virtual NICs.
  Docker containers get random MACs on their veth interfaces.
  You can set them manually: ip link set dev eth0 address xx:xx:xx:xx:xx:xx

When does MAC matter?
  Same Layer 2 segment: MAC is used to deliver frames between hosts.
  Different segment: MAC changes at every hop, IP stays the same.

  Host A → Switch → Router → Switch → Host B
  Frame at A: src_mac=A dst_mac=Router   src_ip=A dst_ip=B
  Frame at B: src_mac=Router dst_mac=B   src_ip=A dst_ip=B
              ↑ MAC changed              ↑ IP unchanged
```

### The 0.0.0.0 confusion

```
0.0.0.0 means DIFFERENT things depending on context:

In ss/netstat output:
  0.0.0.0:80 = listening on ALL interfaces (accessible from outside)
  127.0.0.1:80 = listening ONLY on loopback (local only)

  This is why "service listening on 127.0.0.1" can't be reached from outside.
  Common cloud debugging issue.

In routing:
  0.0.0.0/0 = "match any destination" (the default route)
  ip route add default via 192.168.1.1 = ip route add 0.0.0.0/0 via 192.168.1.1

In iptables:
  -s 0.0.0.0/0 = "any source" (usually omitted, it's the default)
  -d 0.0.0.0/0 = "any destination"
```

---

## 7. Network vs Subnet vs VLAN vs VPC

All ways to create boundaries — but at different levels.

```
┌──────────────┬─────────────────────────────────────────────────────────┐
│ Term         │ What boundary it creates                                │
├──────────────┼─────────────────────────────────────────────────────────┤
│ Network      │ The broadest term. Any group of connected devices.      │
│              │ "The office network" "the 10.0.0.0/8 network"           │
│              │ Can be physical, virtual, or both.                       │
│              │                                                         │
│ Subnet       │ A subdivision of a network. Defined by CIDR mask.       │
│              │ 10.0.0.0/16 split into:                                 │
│              │   10.0.1.0/24 (public subnet, 254 hosts)               │
│              │   10.0.2.0/24 (private subnet, 254 hosts)              │
│              │ Hosts in the same subnet can reach each other directly  │
│              │ (Layer 2). Across subnets requires a router (Layer 3).  │
│              │                                                         │
│ VLAN         │ Virtual LAN. A Layer 2 boundary enforced by switches.   │
│              │ Same physical switch, but ports are logically separated.│
│              │ VLAN 10 and VLAN 20 can't talk without a router.       │
│              │ Tags: 802.1Q adds a VLAN ID to Ethernet frames.        │
│              │ You might see: eth0.10 (VLAN 10 on eth0).              │
│              │                                                         │
│ VPC          │ Virtual Private Cloud. A cloud provider's isolated      │
│              │ network. Your own private address space in the cloud.    │
│              │ Contains subnets, route tables, gateways.               │
│              │ Think of it as: your own data center network, virtual.   │
│              │                                                         │
│ VPN          │ Virtual Private Network. An encrypted tunnel between     │
│              │ two networks. Makes remote networks feel local.          │
│              │ NOT the same as VPC — VPN connects, VPC isolates.       │
│              │                                                         │
│ Namespace    │ Linux network namespace. A completely isolated           │
│ (netns)      │ network stack: its own interfaces, routes, iptables.    │
│              │ Each Docker container runs in its own network namespace. │
│              │ ip netns list — shows namespaces                         │
└──────────────┴─────────────────────────────────────────────────────────┘
```

### CIDR notation demystified

```
IP address: 192.168.1.0/24

The /24 means: first 24 bits are the network part, rest is host part.

/24 = 255.255.255.0   = 256 IPs (254 usable hosts)
/16 = 255.255.0.0     = 65,536 IPs
/8  = 255.0.0.0       = 16,777,216 IPs
/32 = 255.255.255.255 = exactly 1 IP (a single host)
/0  = 0.0.0.0         = all IPs (used in "default route" or "any")

Quick math:
  Hosts in a subnet = 2^(32 - prefix) - 2
  /24 → 2^8 - 2  = 254 hosts
  /28 → 2^4 - 2  = 14 hosts
  /30 → 2^2 - 2  = 2 hosts (point-to-point links)

  -2 because: first IP = network address, last IP = broadcast address
  Cloud providers often reserve more (e.g., AWS reserves 5 per subnet)
```

---

## 8. NAT, Proxy, Gateway, Firewall

Four things that sit between you and the destination, often confused.

```
┌──────────────┬──────────────────────────────────────────────────────────┐
│ Term         │ What it does                                             │
├──────────────┼──────────────────────────────────────────────────────────┤
│ NAT          │ Rewrites IP addresses in packet headers.                 │
│              │ The application never knows. Transparent to Layer 7.     │
│              │ SNAT: rewrites source IP (outbound — hide internal IPs)  │
│              │ DNAT: rewrites dest IP (inbound — port forwarding)       │
│              │ Operates at Layer 3/4. Doesn't understand HTTP.          │
│              │                                                          │
│ Proxy        │ Terminates the connection and creates a NEW one.         │
│              │ The proxy UNDERSTANDS the protocol (HTTP, SOCKS, etc).   │
│              │ Two separate connections: client→proxy, proxy→backend.   │
│              │ Can inspect/modify content, add headers, cache.          │
│              │ Operates at Layer 7 (or Layer 4 for SOCKS/TCP proxy).   │
│              │                                                          │
│ Gateway      │ The "exit door" from your network to another network.    │
│              │ "Default gateway" = the router you send traffic to       │
│              │ when the destination is not on your local network.       │
│              │ In cloud: Internet Gateway (IGW), NAT Gateway, API GW.  │
│              │ It's a role, not a specific technology.                  │
│              │                                                          │
│ Firewall     │ Decides whether to allow or block traffic.               │
│              │ Does NOT modify the packet (unlike NAT).                 │
│              │ Does NOT create new connections (unlike proxy).          │
│              │ Just says YES or NO based on rules.                      │
│              │ iptables filter table = firewall.                        │
│              │ iptables nat table = NOT a firewall, it's NAT.          │
└──────────────┴──────────────────────────────────────────────────────────┘
```

### NAT vs Proxy — the key difference

```
NAT (transparent, Layer 3/4):
  Client → [NAT box rewrites IP headers] → Server
  One connection, modified in-flight.
  Server sees NAT box's IP, not client's.
  NAT doesn't understand HTTP, DNS, etc.

Proxy (terminates, Layer 7):
  Client → [Proxy] → NEW connection → Server
  Two connections. Proxy reads and understands the content.
  Proxy can: cache, filter URLs, add X-Forwarded-For, do TLS termination.

  nginx as reverse proxy:
    Client ──TCP──► nginx ──NEW TCP──► backend
    nginx reads the HTTP request, can route based on URL path.
    This is NOT NAT. It's proxying.

  iptables DNAT:
    Client ──TCP──► iptables ──same TCP, rewritten──► backend
    iptables doesn't read HTTP. It just changes the destination IP.
    This IS NAT.
```

### "Gateway" is a role, not a thing

```
These are all "gateways":
  - Your home router (default gateway for your LAN)
  - A NAT gateway in AWS (default route for private subnets)
  - An API gateway (reverse proxy for microservices)
  - An Internet Gateway in a VPC (connects VPC to internet)
  - A VPN gateway (connects two networks via encrypted tunnel)
  - A payment gateway (API for processing payments — not networking at all)

"Gateway" just means: the door you go through to reach another network/system.
Context tells you what kind.
```

---

## 9. Layers and Encapsulation

### Why layers matter practically

```
You don't need to memorize all 7 OSI layers. You need these:

Layer 2 (Data Link) — Ethernet frames, MAC addresses
  Tools: ip link, bridge, arp, tcpdump -e
  Scope: local segment only (switches, bridges)
  Problem examples: "ARP table full", "MAC flapping", "VLAN mismatch"

Layer 3 (Network) — IP packets, routing
  Tools: ip addr, ip route, ping, traceroute, iptables
  Scope: across networks (routers)
  Problem examples: "no route to host", "wrong subnet", "NAT misconfigured"

Layer 4 (Transport) — TCP/UDP, ports, connections
  Tools: ss, netstat, conntrack, tcpdump with port filters
  Scope: end-to-end between processes
  Problem examples: "connection refused", "connection timeout", "port not open"

Layer 7 (Application) — HTTP, DNS, SSH, TLS
  Tools: curl, dig, nslookup, openssl s_client
  Scope: application logic
  Problem examples: "404 not found", "SSL handshake failed", "DNS NXDOMAIN"
```

### Encapsulation — packets inside packets

```
When you send an HTTP request, the data is wrapped in layers:

Application layer:    GET /index.html HTTP/1.1\r\nHost: example.com
                      ↓ wrapped in
Transport layer:      [TCP header: src_port=54321, dst_port=80] + HTTP data
                      ↓ wrapped in
Network layer:        [IP header: src=10.0.1.4, dst=93.184.216.34] + TCP segment
                      ↓ wrapped in
Data Link layer:      [Eth header: src_mac=aa:bb, dst_mac=cc:dd] + IP packet
                      ↓ sent as
Physical layer:       electrical signals / light pulses / radio waves

At each hop, the outer layer (Ethernet) is STRIPPED and RE-WRAPPED:
  - MAC addresses change at every router hop
  - IP addresses stay the same (unless NAT rewrites them)
  - TCP ports stay the same (unless NAT rewrites them)
  - HTTP data is untouched

tcpdump shows you layers 2-4. curl shows you layer 7.
```

### Where iptables operates

```
iptables works at Layer 3 and Layer 4:

Layer 3 matches:
  -s 10.0.0.0/24          (source IP)
  -d 192.168.1.0/24       (destination IP)
  -i eth0                  (incoming interface)
  -o docker0               (outgoing interface)

Layer 4 matches:
  -p tcp --dport 80       (TCP destination port)
  -p udp --sport 53       (UDP source port)
  -m state --state NEW    (connection state — conntrack)
  -m multiport --dports 80,443  (multiple ports)

Layer 7 — iptables does NOT understand:
  HTTP URLs, DNS queries, TLS certificates
  For Layer 7 filtering, you need a proxy (nginx, HAProxy) or
  advanced tools (Cilium L7 policy, WAF)
```

---

## 10. Names That Lie

Networking terms that are misleading or don't mean what you'd expect.

```
┌─────────────────────────┬──────────────────────────────────────────────┐
│ Name                    │ Why it lies                                  │
├─────────────────────────┼──────────────────────────────────────────────┤
│ "Localhost"             │ Not just 127.0.0.1. It's the entire         │
│                         │ 127.0.0.0/8 range (16M addresses).          │
│                         │ 127.0.0.1 and 127.42.42.42 are both local.  │
│                         │                                              │
│ "Security Group"        │ Not a group of secured things.               │
│                         │ It's a firewall ruleset. AWS naming.         │
│                         │                                              │
│ "Subnet mask"           │ Not a mask you apply to a subnet.            │
│                         │ It DEFINES the subnet. /24 = 255.255.255.0  │
│                         │                                              │
│ "Default route"         │ Not the first route checked.                 │
│                         │ It's the LAST resort — matched when nothing  │
│                         │ more specific matches. Most specific wins.   │
│                         │                                              │
│ "Promiscuous mode"      │ Not a security vulnerability (by itself).    │
│                         │ An interface mode where the NIC accepts ALL  │
│                         │ frames, not just those addressed to its MAC. │
│                         │ Used by: tcpdump, bridges, packet sniffers.  │
│                         │                                              │
│ "Stateless" (NACL)      │ Doesn't mean "no state exists."             │
│                         │ Means: each packet is evaluated on its own.  │
│                         │ Inbound and outbound are separate decisions. │
│                         │                                              │
│ "Stateful" (SG)         │ Doesn't mean "it remembers everything."     │
│                         │ Means: if inbound is allowed, return traffic │
│                         │ is auto-allowed. Tracked per-connection.     │
│                         │                                              │
│ "Transparent proxy"     │ Not invisible. It intercepts traffic without │
│                         │ the client explicitly configuring it.        │
│                         │ Still terminates and re-creates connections. │
│                         │                                              │
│ "Bridge mode"           │ In home routers: means "act as a switch,    │
│                         │ disable NAT and routing." In Linux: means    │
│                         │ "act as a Layer 2 switch" (opposite vibe).   │
│                         │                                              │
│ "Loopback"              │ Nothing loops. Traffic to 127.0.0.1 goes    │
│                         │ into the kernel and comes right back out     │
│                         │ without touching any wire.                   │
│                         │                                              │
│ "eth0"                  │ Not always Ethernet. Cloud VMs show eth0     │
│                         │ for virtual NICs that have no Ethernet cable.│
│                         │ Modern Linux often uses: ens18, enp0s3, etc. │
│                         │ The naming is just convention.               │
│                         │                                              │
│ "Firewall rule"         │ In iptables nat table, rules do NAT, not    │
│                         │ firewalling. Only filter table rules are     │
│                         │ actually "firewall rules."                   │
│                         │                                              │
│ "Port forwarding"       │ Not forwarding a port. It's DNAT — rewriting│
│                         │ the destination IP:port in packet headers.   │
│                         │ The "port" doesn't move anywhere.            │
│                         │                                              │
│ ClusterIP (K8s)         │ Not a real IP on any interface. It's a      │
│                         │ virtual IP that ONLY exists in iptables DNAT │
│                         │ rules. You can't ping it. You can't ARP it. │
└─────────────────────────┴──────────────────────────────────────────────┘
```

---

## 11. Virtual Networking Zoo

Quick reference for Linux virtual network devices.

```
┌──────────┬──────────────────────────────────────────────────────────────┐
│ Device   │ What it is and when you'll see it                           │
├──────────┼──────────────────────────────────────────────────────────────┤
│ lo       │ Loopback. Always exists. IP 127.0.0.1.                      │
│          │ Traffic never leaves the host.                               │
│          │                                                              │
│ veth     │ Virtual Ethernet pair — two ends of a virtual cable.         │
│          │ One end in a container's network namespace, other on bridge. │
│          │ Docker and K8s create these for every container.             │
│          │ ip link show type veth                                       │
│          │                                                              │
│ bridge   │ Virtual switch. Connects multiple interfaces at Layer 2.     │
│          │ docker0 is a bridge. CNIs create cni0 or similar.           │
│          │ ip link show type bridge                                     │
│          │ bridge link show                                             │
│          │                                                              │
│ tun      │ Layer 3 tunnel device. Carries IP packets.                   │
│          │ Used by: VPNs (OpenVPN), WireGuard (wg0 is a tun).         │
│          │ You write IP packets to it, kernel routes them.              │
│          │                                                              │
│ tap      │ Layer 2 tunnel device. Carries Ethernet frames.              │
│          │ Used by: VMs (QEMU/KVM connects VMs via tap devices).       │
│          │ Like tun but includes MAC addresses.                         │
│          │                                                              │
│ vxlan    │ Virtual Extensible LAN. Overlay network over UDP.            │
│          │ Encapsulates Layer 2 frames inside UDP packets.              │
│          │ Used by: Flannel (VXLAN mode), cloud networks.              │
│          │ Lets VMs/containers on different hosts share a Layer 2 net. │
│          │                                                              │
│ macvlan  │ Assigns a new MAC address to a virtual interface on a       │
│          │ physical NIC. Containers get their own MAC and appear as     │
│          │ separate physical devices on the network.                    │
│          │ No bridge needed. Better performance than bridge mode.       │
│          │                                                              │
│ ipvlan   │ Like macvlan but all virtual interfaces share the host's    │
│          │ MAC address. Uses IP-level routing instead of MAC-level.     │
│          │ Some cloud environments block multiple MACs per NIC.         │
│          │ ipvlan works around that.                                    │
│          │                                                              │
│ dummy    │ A do-nothing interface. Used to assign IPs that are always  │
│          │ "up" regardless of physical link state.                      │
│          │ Used for: loopback-like IPs, kube-proxy dummy interfaces.   │
│          │                                                              │
│ wireguard│ WireGuard VPN interface (wg0). A modern tun device with     │
│ (wg)     │ built-in encryption. Simpler than OpenVPN tun/tap.          │
└──────────┴──────────────────────────────────────────────────────────────┘
```

### How to explore what's on your system

```bash
# List all interfaces with type
ip -d link show

# Show only bridges
ip link show type bridge

# Show only veth pairs
ip link show type veth

# Show bridge members (which veths are plugged into which bridge)
bridge link show

# Show all network namespaces (containers/pods each have one)
ip netns list
# Or for Docker:
ls /var/run/docker/netns/

# Enter a namespace and inspect it
ip netns exec <name> ip addr show
ip netns exec <name> ip route show
ip netns exec <name> iptables -L -v -n
```

---

## Quick Disambiguation Table

When you're confused by a term, check here:

```
"I hear..."          "In this context it means..."

"open port 80"     → allow TCP connections to destination port 80
"port 3 on switch" → physical jack on hardware
"host"             → a machine with an IP (or "the Docker host machine")
"endpoint"         → K8s: pod IP:port | API: URL | VPN: remote side
"interface"        → network device (ip link show) or software API boundary
"gateway"          → your default router OR a cloud/API middlebox
"bridge"           → Layer 2 virtual switch (NOT a router)
"service"          → K8s: virtual LB | systemd: unit file | general: running app
"socket"           → network: IP:port connection | unix: local IPC file
"route"            → a rule mapping destination → next hop
"forward"          → iptables: FORWARD chain (passing through, not for me)
"NAT"              → rewriting IP addresses in packet headers
"proxy"            → terminating and re-creating connections
"stateless"        → each packet evaluated independently (no memory)
"stateful"         → return traffic auto-allowed (connection tracked)
"namespace"        → isolated network stack (own IPs, routes, iptables)
```

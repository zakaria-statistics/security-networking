# Docker iptables Lab (v27+)
> Observe every rule Docker writes to the kernel — from daemon start to port publishing to network isolation

## Table of Contents
1. [Lab Environment](#1-lab-environment) - What you need
2. [Phase 1: Baseline — Before Docker Touches Anything](#2-phase-1-baseline--before-docker-touches-anything) - Clean-slate snapshot
3. [Phase 2: Daemon Start — The v27 Chain Structure](#3-phase-2-daemon-start--the-v27-chain-structure) - Six new chains
4. [Phase 3: Run a Container — Watch the Packet Path](#4-phase-3-run-a-container--watch-the-packet-path) - Masquerade and egress ACCEPT
5. [Phase 4: Publish a Port — DNAT and the DOCKER Chain](#5-phase-4-publish-a-port--dnat-and-the-docker-chain) - How `-p` changes the DOCKER chain
6. [Phase 5: Two Networks — DOCKER-INTERNAL Isolation](#6-phase-5-two-networks--docker-internal-isolation) - Replaced DOCKER-ISOLATION-STAGE-1/2
7. [Phase 6: ICC Disabled — Same Network, Still Blocked](#7-phase-6-icc-disabled--same-network-still-blocked) - Per-bridge DROP rule
8. [Phase 7: Conntrack — How Return Traffic Finds Its Way Back](#8-phase-7-conntrack--how-return-traffic-finds-its-way-back) - State tracking inspection
9. [Phase 8: DOCKER-USER Chain — Rules That Survive Restart](#9-phase-8-docker-user-chain--rules-that-survive-restart) - Your safe namespace
10. [Phase 9: Live Packet Trace with LOG](#10-phase-9-live-packet-trace-with-log) - Watch a packet move through chains
11. [Cleanup](#11-cleanup)

---

## 1. Lab Environment

```
┌─────────────────────────────────────────────────────────┐
│  Linux host with Docker Engine v27+ installed           │
│                                                         │
│  eth0:    your host IP (e.g., 192.168.11.109)           │
│  docker0: 172.17.0.1 (created when Docker starts)       │
│  br-xxxx: custom network bridges (created in Phase 5)   │
└─────────────────────────────────────────────────────────┘
```

**Convention:** All commands run as root (`H#`).

> **Check your Docker version before starting:**
> ```bash
> H# docker version --format '{{.Server.Version}}'
> ```
> This lab is written for v27+. You should see `27.x.x` or higher.

> **Check your interface name:**
> ```bash
> H# ip -br a
> ```

---

## 2. Phase 1: Baseline — Before Docker Touches Anything

Capture a rule count before Docker starts so you can clearly see what it adds.

### Step 1 — Stop Docker and flush all rules

```bash
H# systemctl stop docker docker.socket
H# iptables -F && iptables -X
H# iptables -t nat -F && iptables -t nat -X
H# iptables -P INPUT ACCEPT
H# iptables -P FORWARD ACCEPT
H# iptables -P OUTPUT ACCEPT
```

### Step 2 — Confirm empty state

```bash
H# iptables-save | wc -l
```

**Expected:** 8–10 lines (only default chain declarations).

```bash
H# ip link show type bridge
```

**Expected:** No output — `docker0` doesn't exist yet.

---

## 3. Phase 2: Daemon Start — The v27 Chain Structure

### Step 1 — Start Docker and count rules

```bash
H# systemctl start docker
H# iptables-save | wc -l
```

**Compare to Phase 1.** You should see ~20+ more lines.

### Step 2 — List all chains Docker created

```bash
H# iptables-save | grep "^:"
```

**v27 adds exactly 6 filter chains:**
```
:DOCKER
:DOCKER-BRIDGE
:DOCKER-CT
:DOCKER-FORWARD
:DOCKER-INTERNAL
:DOCKER-USER
```

> **Pre-v27 had:** `DOCKER`, `DOCKER-ISOLATION-STAGE-1`, `DOCKER-ISOLATION-STAGE-2`, `DOCKER-USER`
> The isolation stages are gone. Isolation is now handled by `DOCKER-INTERNAL`.

### Step 3 — Read FORWARD — the two entry points

```bash
H# iptables -L FORWARD -n -v --line-numbers
```

**Expected:**
```
1  DOCKER-USER     all  *  *  0.0.0.0/0  0.0.0.0/0
2  DOCKER-FORWARD  all  *  *  0.0.0.0/0  0.0.0.0/0
```

Every packet that passes through the host hits these two chains — no exceptions.

### Step 4 — Read DOCKER-FORWARD — the dispatch chain

```bash
H# iptables -L DOCKER-FORWARD -n -v --line-numbers
```

**Expected (4 rules):**
```
1  DOCKER-CT       all  *       *       (handles return traffic)
2  DOCKER-INTERNAL all  *       *       (handles cross-network isolation)
3  DOCKER-BRIDGE   all  *       *       (handles inbound to containers)
4  ACCEPT          all  docker0 *       (handles container egress)
```

**Read rules 3 and 4 together carefully:**
- Rule 3: calls `DOCKER-BRIDGE` for ALL traffic (no interface filter here)
- Rule 4: `ACCEPT` only if `in=docker0` — container egress

Rules are evaluated in order. If rule 3 terminates a packet (via DROP in DOCKER), rule 4 never fires for that packet. If rule 3 returns without terminating, rule 4 fires next.

### Step 5 — Read DOCKER-CT — return traffic handler

```bash
H# iptables -L DOCKER-CT -n -v --line-numbers
```

**Expected:**
```
1  ACCEPT  all  *  docker0  ctstate RELATED,ESTABLISHED
```

Notice the interface scope: `out=docker0`. This chain only handles return traffic going **into** containers.

**Question to answer:** Why does DOCKER-CT only cover `out=docker0`? What happens to return traffic for connections initiated by external clients to a published port?

*(Answer: External→Container connections are tracked too. The conntrack state is stored when the DNAT fires. Return packets from the container to the client also go through DOCKER-CT. But DOCKER-CT's rule checks `out=docker0` which is the direction going TO the container — covering cases like container egress return traffic from the internet back to the container.)*

### Step 6 — Read DOCKER-BRIDGE and DOCKER

```bash
H# iptables -L DOCKER-BRIDGE -n -v --line-numbers
H# iptables -L DOCKER -n -v --line-numbers
```

**DOCKER-BRIDGE:**
```
1  DOCKER  all  *  docker0   ← only for out=docker0 (inbound to containers)
```

**DOCKER:**
```
1  DROP  all  !docker0  docker0   ← external inbound default deny
```

**Key observation on the DROP rule:** It requires `in=!docker0` AND `out=docker0`. This means:
- External → Container (`eth0 → docker0`): **matches DROP** ✗
- Container → Container (`docker0 → docker0`): `in=docker0` fails `!docker0` → **does NOT match** ✓
- Container → External (`docker0 → eth0`): `out=eth0` fails `docker0` → **does NOT match** ✓

### Step 7 — Read DOCKER-INTERNAL

```bash
H# iptables -L DOCKER-INTERNAL -n -v --line-numbers
```

**Expected:** Empty (no rules yet — no custom networks created).

This chain gets populated when you create multiple Docker networks in Phase 5.

### Step 8 — Inspect the nat table

```bash
H# iptables -t nat -L -n -v
```

**Key rules to locate:**

```
PREROUTING:
  DOCKER  all  addrtype LOCAL   ← traffic to local IPs enters DOCKER chain

OUTPUT:
  DOCKER  all  !127.0.0.0/8 addrtype LOCAL   ← locally-generated traffic too

POSTROUTING:
  MASQUERADE  172.17.0.0/16  !docker0   ← containers going external get SNAT

nat/DOCKER:
  (empty — no containers with published ports yet)
```

---

## 4. Phase 3: Run a Container — Watch the Packet Path

### Step 1 — Snapshot DOCKER chain before

```bash
H# iptables -L DOCKER -n -v --line-numbers
```

Only the DROP rule should be present.

### Step 2 — Run a container (no port publishing)

```bash
H# docker run -d --name test1 nginx:alpine
H# docker inspect test1 --format '{{.NetworkSettings.IPAddress}}'
# e.g., 172.17.0.2
```

### Step 3 — Check if DOCKER chain changed

```bash
H# iptables -L DOCKER -n -v --line-numbers
```

**Expected:** No change. Running without `-p` adds nothing to DOCKER.

Docker only adds rules to DOCKER when you publish a port.

### Step 4 — Test outbound from the container

```bash
H# docker exec test1 wget -qO- http://1.1.1.1 --timeout=3 && echo "SUCCESS"
```

**Trace this packet's journey:**
```
src=172.17.0.2, dst=1.1.1.1
  │
  ▼ FORWARD → DOCKER-FORWARD
  DOCKER-CT:      out=eth0 (not docker0) → miss
  DOCKER-INTERNAL: empty → miss
  DOCKER-BRIDGE:  out=eth0 (not docker0) → miss
  Final ACCEPT:   in=docker0 ✓ → ACCEPT
  │
  ▼ POSTROUTING
  MASQUERADE: src=172.17.0.0/16 ✓, out=eth0 (not docker0) ✓
  src rewritten → 192.168.11.109
```

### Step 5 — Watch the MASQUERADE counter increment

```bash
H# iptables -t nat -L POSTROUTING -n -v
```

Run the `wget` again, then re-check — the `pkts` counter on the MASQUERADE rule should increment.

### Step 6 — Verify the final ACCEPT in DOCKER-FORWARD increments

```bash
H# iptables -L DOCKER-FORWARD -n -v
```

Run `wget` again. Rule 4 (the `ACCEPT in=docker0`) should show increasing `pkts`.

---

## 5. Phase 4: Publish a Port — DNAT and the DOCKER Chain

### Step 1 — Run a container with a published port

```bash
H# docker run -d -p 8080:80 --name web nginx:alpine
H# docker inspect web --format '{{.NetworkSettings.IPAddress}}'
# e.g., 172.17.0.3
```

### Step 2 — Inspect nat/DOCKER — the DNAT rule

```bash
H# iptables -t nat -L DOCKER -n -v --line-numbers
```

**You should see:**
```
1  DNAT  tcp  !docker0  *  0.0.0.0/0  0.0.0.0/0  tcp dpt:8080 to:172.17.0.3:80
```

**Anatomy:**
```
! -i docker0    = NOT from docker0 (external traffic only)
-p tcp          = TCP protocol
--dport 8080    = arriving on port 8080
DNAT            = rewrite destination
to:172.17.0.3:80 = send to the container's IP:port
```

> **Why `! -i docker0`?**
> If a container tried to reach `host:8080`, DNAT would rewrite it back to the same container — a loop. The negation prevents this.

### Step 3 — Inspect filter/DOCKER — the ACCEPT before the DROP

```bash
H# iptables -L DOCKER -n -v --line-numbers
```

**The DOCKER chain now has two rules:**
```
1  ACCEPT  tcp  !docker0  docker0  dst=172.17.0.3  dpt=80   ← published port
2  DROP    all  !docker0  docker0                            ← default deny
```

**Order matters.** Rule 1 is inserted before Rule 2. Traffic to port 80 on this container is accepted; everything else is dropped.

### Step 4 — Test inbound

> **docker-proxy handles `localhost` access:** `curl localhost:8080` is intercepted by Docker's userspace proxy — iptables DNAT never fires, so `pkts` counters stay at zero. Use this only as a basic connectivity check. To drive the iptables path, use the host's real IP (see warning below).

```bash
H# curl http://localhost:8080
```

### Step 5 — Trace the full inbound path

```
src=<client>, dst=<host>:8080
  │
  ▼ nat / PREROUTING → nat/DOCKER
  DNAT fires: dst → 172.17.0.3:80
  │
  ▼ ROUTING DECISION
  "172.17.0.3 is not local, forward via docker0"
  │
  ▼ filter / FORWARD → DOCKER-USER → DOCKER-FORWARD
  DOCKER-CT:      out=docker0, ctstate=NEW → miss
  DOCKER-INTERNAL: empty → miss
  DOCKER-BRIDGE:  out=docker0 → jump to DOCKER
    DOCKER rule 1: ACCEPT dst=172.17.0.3 dport=80 ✓
  Verdict: ACCEPT
  │
  ▼ nat / POSTROUTING
  MASQUERADE: out=docker0 → rule says "! -o docker0" → NO masquerade
  │
  ▼ Container nginx (172.17.0.3:80)
```

**Verify:** Check `pkts` on `DOCKER-CT` (should NOT increment for new connections), and on `DOCKER` rule 1 (SHOULD increment).

> **Warning — `curl localhost` won't increment `pkts`**
>
> The `OUTPUT` DOCKER rule explicitly excludes loopback:
> ```
> OUTPUT: DOCKER all !127.0.0.0/8 addrtype LOCAL
> ```
> Traffic to `127.0.0.1:8080` never reaches the DNAT rule — it is intercepted by **docker-proxy**, a userspace process Docker spawns per published port:
> ```bash
> ps aux | grep docker-proxy
> # docker-proxy -proto tcp -host-ip 0.0.0.0 -host-port 8080 -container-ip 172.17.0.3 -container-port 80
> ```
> docker-proxy listens on the host socket and forwards at the application layer, invisible to iptables counters.
>
> To actually trigger the DNAT rule and increment `pkts`, use the host's real IP:
> ```bash
> iptables -t nat -Z DOCKER          # reset counters
> curl http://192.168.11.109:8080    # arrives on eth0, hits PREROUTING → DOCKER chain
> iptables -t nat -L DOCKER -n -v --line-numbers   # pkts now > 0
> ```

### Step 6 — Find the hairpin MASQUERADE

```bash
H# iptables -t nat -L POSTROUTING -n -v
```

Look for:
```
MASQUERADE  tcp  *  *  172.17.0.3  172.17.0.3  dpt:80
```

**When this fires:** When the container itself tries to reach `localhost:8080`. The packet leaves the container, hits DNAT (becomes `172.17.0.3:80`), then MASQUERADE rewrites the source — otherwise the container would reject a packet coming from itself to itself.

> **With `userland-proxy=true` (default):** This rule won't appear. docker-proxy handles hairpin traffic in userspace and iptables never sees it. Set `"userland-proxy": false` in `/etc/docker/daemon.json` to make the MASQUERADE rule appear.

---

## 6. Phase 5: Two Networks — Isolation in Docker 29

### Step 1 — Create two custom networks

```bash
H# docker network create --subnet 10.10.0.0/24 frontend
H# docker network create --subnet 10.20.0.0/24 backend
```

### Step 2 — Get the bridge interface names

```bash
H# ip link show type bridge
H# docker network ls
```

Custom network bridges are named `br-<first 12 chars of network ID>`.

### Step 3 — Understand what DOCKER-INTERNAL actually does (Docker 29)

```bash
H# iptables -L DOCKER-INTERNAL -n -v --line-numbers
```

**After creating `frontend` and `backend`, this chain is empty.** DOCKER-INTERNAL is NOT used for cross-network isolation between regular networks.

DOCKER-INTERNAL is exclusively for networks created with the `--internal` flag:

```bash
H# docker network create --internal isolated-net
H# docker run -d --name test --network isolated-net nginx
H# iptables -L DOCKER-INTERNAL -n -v --line-numbers
```

**Now it populates — two rules per internal network:**
```
1  DROP  all  *   br-<isolated>   !<subnet>   0.0.0.0/0   ← block ingress from outside subnet
2  DROP  all  br-<isolated>  *   0.0.0.0/0   !<subnet>   ← block egress to outside subnet
```

This enforces no external routing for `--internal` networks — containers can only talk within the same network.

> **vs pre-v27:** The old DOCKER-ISOLATION-STAGE-1 and STAGE-2 chains used a two-step match to drop cross-bridge traffic. In Docker 27+, those chains are gone. Regular network isolation no longer uses DROP rules in iptables.

### Step 4 — How regular cross-network isolation actually works (Docker 29)

```bash
H# iptables -L DOCKER-FORWARD -n -v --line-numbers
```

**Expected output:**
```
1  DOCKER-CT       all  *          *              ← conntrack fast path
2  DOCKER-INTERNAL all  *          *              ← --internal enforcement
3  DOCKER-BRIDGE   all  *          *              ← dispatch to DOCKER chain
4  ACCEPT          all  docker0    *              ← default bridge egress
5  ACCEPT          all  br-frontend *             ← frontend egress
6  ACCEPT          all  br-backend  *             ← backend egress
7  ACCEPT          all  br-isolated br-isolated   ← isolated-net intra only (no wildcard out)
```

Rules 4-6 ACCEPT traffic **from** each bridge outbound. There are no DROP rules between `br-frontend` and `br-backend`. Cross-network isolation for regular networks relies on **routing** — containers on `10.10.0.0/24` have no route to `10.20.0.0/24` unless the host forwards it, and Docker does not install cross-bridge routes.

`--internal` networks get a restricted DOCKER-FORWARD rule (only `br-isolated → br-isolated`) — no wildcard outbound ACCEPT — combined with the DOCKER-INTERNAL DROP rules.

### Step 5 — Check DOCKER-CT and DOCKER-BRIDGE got new rules

```bash
H# iptables -L DOCKER-CT -n -v
H# iptables -L DOCKER-BRIDGE -n -v
```

Each new bridge gets:
- A RELATED,ESTABLISHED ACCEPT in `DOCKER-CT`
- A dispatch rule to the `DOCKER` chain in `DOCKER-BRIDGE`
- An egress ACCEPT in `DOCKER-FORWARD` (omitted for `--internal` networks)

### Step 6 — Trace a packet: frontend → backend (regular networks)

```
src=10.10.0.2 (app), dst=10.20.0.2 (db)
  │
  ▼ FORWARD → DOCKER-USER → DOCKER-FORWARD
  DOCKER-CT:      new connection → miss
  DOCKER-INTERNAL: no rule for br-frontend/br-backend → miss
  DOCKER-BRIDGE:  out=br-backend → jump to DOCKER chain
    DOCKER chain: no DNAT for 10.20.0.2 → return
  DOCKER-FORWARD rule 5: in=br-frontend → ACCEPT
  │
  ▼ Packet forwarded — iptables does NOT block it
```

Cross-network reachability between regular custom networks depends on the container having a route to the destination subnet, not iptables DROP rules.

### Step 7 — Trace a packet: internal network → external

```
src=172.18.0.2 (test), dst=8.8.8.8
  │
  ▼ FORWARD → DOCKER-USER → DOCKER-FORWARD
  DOCKER-CT:      new connection → miss
  DOCKER-INTERNAL rule 2: in=br-isolated, dst !172.18.0.0/16 → DROP ✓
  Packet dies here.
```

### Step 8 — Break isolation (understand the escape)

Connecting a container to both networks bypasses DOCKER-INTERNAL:

```bash
H# docker network connect backend app
H# docker exec app ping -c 3 $DB_IP
```

**This works** — the packet never crosses bridges; `app` is now directly on the backend bridge.

```bash
H# docker network disconnect backend app
```

---

## 7. Phase 6: ICC Disabled — Same Network, Still Blocked

### Step 1 — Create a network with ICC off

> **Name collision:** Phase 5 already created `isolated-net` for the `--internal` demo. This phase uses `icc-net` to avoid a conflict.

```bash
H# docker network create \
    --opt com.docker.network.bridge.enable_icc=false \
    --subnet 10.30.0.0/24 \
    icc-net
```

### Step 2 — Find where Docker added the rules

With ICC disabled, Docker does NOT write to DOCKER-INTERNAL. Rules are added to **DOCKER-FORWARD** and the **DOCKER** chain:

```bash
H# iptables -L DOCKER-FORWARD -n -v --line-numbers
H# iptables -L DOCKER -n -v --line-numbers
```

**DOCKER-FORWARD gets two new rules for the bridge:**
```
DROP    all  br-<icc>   br-<icc>    ← same-bridge traffic → DROP (ICC enforcement)
ACCEPT  all  br-<icc>  !br-<icc>   ← egress to external → allowed
```

> **Not DOCKER-INTERNAL.** ICC=false rules live in **DOCKER-FORWARD** (and DOCKER), not DOCKER-INTERNAL. DOCKER-INTERNAL is exclusively for `--internal` networks.

**DOCKER chain gets one new rule:**
```
DROP    all  !br-<icc>  br-<icc>   ← no external ingress (no published ports)
```

Compare rules per network type:

| Network type | DOCKER-FORWARD | DOCKER chain |
|---|---|---|
| Regular | `ACCEPT br-X → *` | `DROP !br-X → br-X` |
| `--internal` | `ACCEPT br-X → br-X` only | `DROP !br-X → br-X` + DOCKER-INTERNAL egress/ingress DROPs |
| `icc=false` | `DROP br-X → br-X`, `ACCEPT br-X → !br-X` | `DROP !br-X → br-X` |

### Step 3 — Run two containers on the ICC-disabled network

```bash
H# docker run -d --network icc-net --name iso1 nginx:alpine
H# docker run -d --network icc-net --name iso2 nginx:alpine

H# ISO1=$(docker inspect iso1 --format '{{(index .NetworkSettings.Networks "icc-net").IPAddress}}')
H# ISO2=$(docker inspect iso2 --format '{{(index .NetworkSettings.Networks "icc-net").IPAddress}}')
```

### Step 4 — Confirm containers cannot reach each other

```bash
H# docker exec iso1 ping -c 3 $ISO2
```

**Expected:** 100% packet loss.

### Step 5 — Confirm outbound still works

```bash
H# docker exec iso1 wget -qO- http://1.1.1.1 --timeout=3 && echo "outbound OK"
```

**This works because:** Container egress (`in=br-icc, out=eth0`) doesn't match the same-bridge DROP rule in DOCKER-FORWARD (which requires both `in` AND `out` to equal `br-icc`). The egress ACCEPT rule in DOCKER-FORWARD (`in=br-icc, out=!br-icc`) catches it instead.

---

## 8. Phase 7: Conntrack — How Return Traffic Finds Its Way Back

### Step 1 — Make a request from a container

```bash
H# docker exec test1 wget -qO/dev/null http://1.1.1.1 --timeout=5 &
```

### Step 2 — List the conntrack entry

```bash
H# conntrack -L | grep 1.1.1.1
```

**You should see:**
```
tcp  6  86400  ESTABLISHED
  src=172.17.0.2  dst=1.1.1.1       sport=34521  dport=80   ← original direction
  src=1.1.1.1     dst=192.168.11.109 sport=80     dport=34521  ← reply direction
  [ASSURED]
```

**Reading the entry:**
- **Original:** container's view — `172.17.0.2:34521 → 1.1.1.1:80`
- **Reply:** after MASQUERADE — `1.1.1.1:80 → 192.168.11.109:34521`

When the reply arrives from `1.1.1.1` going to `192.168.11.109:34521`, the kernel looks up this conntrack entry and reverses the MASQUERADE, delivering the packet to `172.17.0.2:34521`.

### Step 3 — Watch state transitions

```bash
H# watch -n 1 'conntrack -L | grep 1.1.1.1'
```

Observe: `SYN_SENT` → `ESTABLISHED` → `TIME_WAIT` → entry removed.

### Step 4 — Conntrack for a published port

```bash
H# curl http://192.168.11.109:8080 &
H# conntrack -L | grep "172.17.0.3"
```

> **Why not `localhost`?** `curl localhost:8080` goes through docker-proxy (userspace), bypassing iptables entirely. Conntrack would only show docker-proxy's own connection to the container — not the DNAT mapping you want to observe. The host's real IP routes through PREROUTING → DNAT, creating a proper conntrack entry.

The DNAT mapping is stored here. When the container responds, conntrack reverses the DNAT.

### Step 5 — Force-clear a stale entry

```bash
H# conntrack -L | grep 172.17.0.3
H# conntrack -D --dst 172.17.0.3
```

This is how you fix "connection hangs after container restart" — conntrack still has entries pointing to the old container's IP.

---

## 9. Phase 8: DOCKER-USER Chain — Rules That Survive Restart

### Step 1 — Understand why DOCKER-USER exists

Docker modifies `DOCKER`, `DOCKER-CT`, `DOCKER-BRIDGE`, `DOCKER-FORWARD`, `DOCKER-INTERNAL` on every container/network change. Rules you add to any of those chains will disappear.

`DOCKER-USER` is the one chain Docker **never touches**. It's called first from FORWARD, before Docker's own chains.

```bash
H# iptables -L FORWARD -n -v --line-numbers
# Rule 1: DOCKER-USER  ← your rules, evaluated first
# Rule 2: DOCKER-FORWARD
```

### Step 2 — Add a rule to DOCKER-USER

Block a source IP from reaching your containers:

```bash
H# iptables -I DOCKER-USER -s 10.0.0.99 -j DROP
```

### Step 3 — Verify it appears before Docker's rules

```bash
H# iptables -L DOCKER-USER -n -v --line-numbers
```

```
1  DROP  all  src=10.0.0.99   ← your rule
```

### Step 4 — Restart Docker and confirm the rule survived

```bash
H# systemctl restart docker
H# iptables -L DOCKER-USER -n -v --line-numbers
```

**Your rule is still there.** Docker rebuilt all its own chains but left DOCKER-USER untouched.

### Step 5 — Clean up

```bash
H# iptables -D DOCKER-USER -s 10.0.0.99 -j DROP
```

---

## 10. Phase 9: Live Packet Trace with LOG

Add LOG targets to watch packets move through the v27 chains in real time.

### Step 1 — Add LOG rules at key checkpoints

```bash
# Log at nat/PREROUTING (before DNAT)
H# iptables -t nat -I PREROUTING 1 -p tcp --dport 8080 \
    -j LOG --log-prefix "[PRE] " --log-level 4

# Log at DOCKER-FORWARD entry (after DNAT, before dispatch)
H# iptables -I DOCKER-FORWARD 1 -p tcp --dport 80 \
    -j LOG --log-prefix "[FWD] " --log-level 4

# Log at DOCKER-CT (to see which packets get the established fast-path)
H# iptables -I DOCKER-CT 1 -p tcp \
    -j LOG --log-prefix "[CT] " --log-level 4

# Log at final ACCEPT (container egress)
H# iptables -I DOCKER-FORWARD 5 -i docker0 -p tcp \
    -j LOG --log-prefix "[EGR] " --log-level 4
```

### Step 2 — Watch logs in one terminal

```bash
H# journalctl -f -k | grep -E "\[PRE\]|\[FWD\]|\[CT\]|\[EGR\]"
```

### Step 3 — Send a request in another terminal

> **If you restarted Docker** (e.g. to test `userland-proxy=false`), containers are gone. Recreate before continuing:
> ```bash
> docker run -d --restart unless-stopped -p 8080:80 --name web nginx:alpine
> ```
> `--restart unless-stopped` survives future Docker restarts automatically.

> **docker-proxy blocks all host-originated traffic from hitting iptables.** With `userland-proxy=true` (default), docker-proxy binds to `0.0.0.0:8080` — any connection from the host to any of its own IPs (including the real IP) is accepted at the socket layer before the FORWARD chain is reached. The LOG rules will not fire.
>
> **Two options to make LOG rules visible:**
>
> **Option A — Disable userland-proxy (recommended for this phase):**
> ```bash
> # /etc/docker/daemon.json
> { "userland-proxy": false }
> systemctl restart docker
> docker run -d --restart unless-stopped -p 8080:80 --name web nginx:alpine
> curl http://192.168.11.109:8080    # now goes through PREROUTING → FORWARD
> ```
>
> **Option B — Send from another machine on the LAN:**
> ```bash
> curl http://192.168.11.109:8080    # run from a different host
> ```

### Step 4 — Read the log output

**First request — single SYN, all three fire together:**
```
[PRE]  IN=eth0  SRC=192.168.11.50  DST=192.168.11.109  DPT=8080  SYN
         ↑ before DNAT — destination is still the host

[FWD]  IN=eth0  OUT=docker0  SRC=192.168.11.50  DST=172.17.0.3  DPT=80  SYN
         ↑ after DNAT — destination is now the container; forwarding via docker0

[CT]   IN=eth0  OUT=docker0  SRC=192.168.11.50  DST=172.17.0.3  DPT=80  SYN
         ↑ same SYN packet entering DOCKER-CT; LOG fires but ACCEPT misses (ctstate=NEW)
           packet falls through to DOCKER-BRIDGE → DOCKER → ACCEPT rule for published port
```

**Return direction (response or RST from container):**
```
[CT]   IN=docker0  OUT=eth0  SRC=172.17.0.3  DST=192.168.11.50  SPT=80  ...
         ↑ DOCKER-CT LOG fires again — no interface filter on the LOG rule
           DOCKER-CT ACCEPT rule (out=docker0) misses here (out=eth0 for return direction)
           packet falls through; egress ACCEPT in DOCKER-FORWARD catches it
```

**`[EGR]` never appears** in this test — that rule only fires for container-initiated egress (e.g. `docker exec web wget ...`), not for replies to inbound connections.

**Key observations:**
1. `[PRE]` and `[FWD]` together show DNAT in action — destination rewrites between them
2. `[CT]` fires on **every** packet entering DOCKER-CT (LOG is at position 1, before the ACCEPT rule) — not only on ESTABLISHED connections
3. The DOCKER-CT **ACCEPT** rule (`out=docker0 ctstate ESTABLISHED`) is what provides the fast-path for established connections — it fires silently; the LOG just shows the chain was entered
4. `[EGR]` requires a separate container-egress test to observe

### Step 5 — Clean up LOG rules

```bash
H# iptables -t nat -D PREROUTING 1
H# iptables -D DOCKER-FORWARD 1   # [FWD] rule
H# iptables -D DOCKER-CT 1        # [CT] rule
H# iptables -D DOCKER-FORWARD 4   # [EGR] rule (position shifted after deletion above)
```

Or restart Docker to restore a clean state:
```bash
H# systemctl restart docker
```

---

## 11. Cleanup

```bash
# Stop all containers
H# docker stop $(docker ps -q) 2>/dev/null
H# docker rm $(docker ps -aq) 2>/dev/null

# Remove custom networks
H# docker network rm frontend backend isolated-net icc-net 2>/dev/null

# Restart Docker to restore clean chain state
H# systemctl restart docker

# Verify only default rules remain
H# iptables -L -n -v
H# iptables -t nat -L -n -v
```

---

## Summary: What Each Phase Proved

| Phase | Concept | Key Command |
|-------|---------|-------------|
| 2 | v27 creates 6 chains, not 4 | `iptables-save \| grep "^:"` |
| 3 | Egress allowed by final ACCEPT in DOCKER-FORWARD (in=docker0) | `iptables -L DOCKER-FORWARD -n -v` |
| 4 | `-p` inserts ACCEPT before DROP in DOCKER chain | `iptables -L DOCKER -n -v` |
| 5 | DOCKER-INTERNAL replaced DOCKER-ISOLATION-STAGE-1/2 | `iptables -L DOCKER-INTERNAL -n -v` |
| 6 | ICC=false adds same-bridge DROP to DOCKER-FORWARD | `iptables -L DOCKER-FORWARD -n -v` |
| 7 | Conntrack stores NAT mappings for return traffic | `conntrack -L` |
| 8 | DOCKER-USER survives daemon restart | `iptables -L DOCKER-USER -n -v` |
| 9 | LOG shows DOCKER-CT fast-path on established connections | `journalctl -f -k` |

---

**Related docs:**
- [Docker-Networking-iptables.md](Docker-Networking-iptables.md) — the theory behind every rule you observed
- [nat-lab.md](nat-lab.md) — DNAT and MASQUERADE fundamentals

# Network Security Lab - State Tracking

> Learn by capturing and comparing network states

## Concept

```
S0 (Baseline)  →  S1 (Firewall)  →  S2 (NAT)  →  S3 (Hardened)
     │                 │                │              │
     └─── compare ─────┴─── compare ────┴── compare ───┘
```

Each state captures:
| Component | What it shows |
|-----------|---------------|
| **Interfaces** | IPs, MACs, link status |
| **Routes** | Where traffic goes |
| **ip_forward** | Is routing enabled? |
| **iptables filter** | What's ALLOWED/BLOCKED |
| **iptables nat** | SNAT/DNAT/MASQUERADE rules |
| **Listening ports** | What services are exposed |
| **UFW status** | Simplified firewall view |
| **conntrack** | Active connections |

## Workflow

### 1. Capture baseline (fresh VM)
```bash
chmod +x capture-state.sh compare-states.sh
sudo ./capture-state.sh S0 "Fresh VM - no changes"
```

### 2. Make a change (example: enable firewall)
```bash
sudo ufw enable
sudo ufw default deny incoming
sudo ufw allow ssh
```

### 3. Capture new state
```bash
sudo ./capture-state.sh S1 "UFW enabled - SSH only"
```

### 4. Compare states
```bash
./compare-states.sh S0 S1
```

### 5. Git commit milestone
```bash
git add states/
git commit -m "S1: Basic firewall - deny incoming, allow SSH"
git tag S1
```

## States Directory

```
states/
├── S0/
│   ├── README.md           # Human-readable summary
│   ├── interfaces.txt
│   ├── routes.txt
│   ├── iptables-filter.rules
│   ├── iptables-nat.rules
│   └── listening.txt
├── S1/
│   └── ...
└── S2/
    └── ...
```

## Planned States

| State | Description | Key Changes |
|-------|-------------|-------------|
| S0 | Baseline | Fresh VM, default rules |
| S1 | Basic Firewall | UFW/iptables deny incoming |
| S2 | Allow Services | SSH, HTTP, HTTPS allowed |
| S3 | Rate Limiting | Brute-force protection |
| S4 | NAT Gateway | IP forwarding, MASQUERADE |
| S5 | Port Forward | DNAT to internal services |
| S6 | Hardened | SSH hardened, fail2ban |

## Quick Commands

```bash
# Capture current state
sudo ./capture-state.sh S0 "description"

# Compare two states
./compare-states.sh S0 S1

# View a state
cat states/S0/README.md

# See all states
ls -la states/

# Git log with tags
git log --oneline --decorate
```

## Understanding the Diff Output

```diff
- -A INPUT -j ACCEPT        # Was allowing all INPUT
+ -A INPUT -j DROP          # Now dropping by default
+ -A INPUT -p tcp --dport 22 -j ACCEPT  # Except SSH
```

- Lines starting with `-` = removed (was in old state)
- Lines starting with `+` = added (new in current state)

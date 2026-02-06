#!/bin/bash
# Capture network state snapshot
# Usage: ./capture-state.sh S0 "Baseline - fresh VM"

STATE_NAME="${1:-S0}"
DESCRIPTION="${2:-No description}"
STATE_DIR="states/$STATE_NAME"

mkdir -p "$STATE_DIR"

echo "=== Capturing State: $STATE_NAME ===" | tee "$STATE_DIR/README.md"
echo "Description: $DESCRIPTION" | tee -a "$STATE_DIR/README.md"
echo "Timestamp: $(date)" | tee -a "$STATE_DIR/README.md"
echo "" >> "$STATE_DIR/README.md"

# --- NETWORK INTERFACES ---
echo "## Interfaces" >> "$STATE_DIR/README.md"
echo '```' >> "$STATE_DIR/README.md"
ip -br addr >> "$STATE_DIR/README.md"
echo '```' >> "$STATE_DIR/README.md"
ip addr > "$STATE_DIR/interfaces.txt"

# --- ROUTING ---
echo "" >> "$STATE_DIR/README.md"
echo "## Routing Table" >> "$STATE_DIR/README.md"
echo '```' >> "$STATE_DIR/README.md"
ip route >> "$STATE_DIR/README.md"
echo '```' >> "$STATE_DIR/README.md"
ip route > "$STATE_DIR/routes.txt"

# --- IP FORWARDING ---
echo "" >> "$STATE_DIR/README.md"
echo "## IP Forwarding" >> "$STATE_DIR/README.md"
echo '```' >> "$STATE_DIR/README.md"
echo "net.ipv4.ip_forward = $(cat /proc/sys/net/ipv4/ip_forward)" >> "$STATE_DIR/README.md"
echo '```' >> "$STATE_DIR/README.md"

# --- IPTABLES FILTER ---
echo "" >> "$STATE_DIR/README.md"
echo "## iptables - FILTER (Allow/Block)" >> "$STATE_DIR/README.md"
echo '```' >> "$STATE_DIR/README.md"
iptables -L -v -n >> "$STATE_DIR/README.md"
echo '```' >> "$STATE_DIR/README.md"
iptables -S > "$STATE_DIR/iptables-filter.rules"

# --- IPTABLES NAT ---
echo "" >> "$STATE_DIR/README.md"
echo "## iptables - NAT (SNAT/DNAT/MASQUERADE)" >> "$STATE_DIR/README.md"
echo '```' >> "$STATE_DIR/README.md"
iptables -t nat -L -v -n >> "$STATE_DIR/README.md"
echo '```' >> "$STATE_DIR/README.md"
iptables -t nat -S > "$STATE_DIR/iptables-nat.rules"

# --- LISTENING PORTS ---
echo "" >> "$STATE_DIR/README.md"
echo "## Listening Services" >> "$STATE_DIR/README.md"
echo '```' >> "$STATE_DIR/README.md"
ss -tulnp 2>/dev/null | head -20 >> "$STATE_DIR/README.md"
echo '```' >> "$STATE_DIR/README.md"
ss -tulnp > "$STATE_DIR/listening.txt" 2>/dev/null

# --- UFW STATUS ---
echo "" >> "$STATE_DIR/README.md"
echo "## UFW Status" >> "$STATE_DIR/README.md"
echo '```' >> "$STATE_DIR/README.md"
ufw status verbose 2>/dev/null >> "$STATE_DIR/README.md" || echo "UFW not active" >> "$STATE_DIR/README.md"
echo '```' >> "$STATE_DIR/README.md"

# --- CONNTRACK ---
echo "" >> "$STATE_DIR/README.md"
echo "## Active Connections (conntrack)" >> "$STATE_DIR/README.md"
echo '```' >> "$STATE_DIR/README.md"
conntrack -L 2>/dev/null | head -10 >> "$STATE_DIR/README.md" || echo "conntrack not available" >> "$STATE_DIR/README.md"
echo '```' >> "$STATE_DIR/README.md"

echo ""
echo "State captured in: $STATE_DIR/"
echo ""
echo "Files created:"
ls -la "$STATE_DIR/"

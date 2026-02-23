#!/bin/bash
# Compare two network states
# Usage: ./compare-states.sh S0 S1

STATE_A="${1:-S0}"
STATE_B="${2:-S1}"

echo "=========================================="
echo "Comparing: $STATE_A → $STATE_B"
echo "=========================================="

# --- FILTER RULES DIFF ---
echo ""
echo "### FILTER TABLE CHANGES (Allow/Block)"
echo "--- $STATE_A"
echo "+++ $STATE_B"
diff "states/$STATE_A/iptables-filter.rules" "states/$STATE_B/iptables-filter.rules" 2>/dev/null || echo "Cannot compare"

# --- NAT RULES DIFF ---
echo ""
echo "### NAT TABLE CHANGES (SNAT/DNAT/MASQUERADE)"
echo "--- $STATE_A"
echo "+++ $STATE_B"
diff "states/$STATE_A/iptables-nat.rules" "states/$STATE_B/iptables-nat.rules" 2>/dev/null || echo "Cannot compare"

# --- ROUTES DIFF ---
echo ""
echo "### ROUTING CHANGES"
echo "--- $STATE_A"
echo "+++ $STATE_B"
diff "states/$STATE_A/routes.txt" "states/$STATE_B/routes.txt" 2>/dev/null || echo "Cannot compare"

# --- INTERFACES DIFF ---
echo ""
echo "### INTERFACE CHANGES"
echo "--- $STATE_A"
echo "+++ $STATE_B"
diff "states/$STATE_A/interfaces.txt" "states/$STATE_B/interfaces.txt" 2>/dev/null || echo "Cannot compare"

# --- LISTENING PORTS DIFF ---
echo ""
echo "### LISTENING SERVICES CHANGES"
echo "--- $STATE_A"
echo "+++ $STATE_B"
diff "states/$STATE_A/listening.txt" "states/$STATE_B/listening.txt" 2>/dev/null || echo "Cannot compare"

echo ""
echo "=========================================="
echo "Legend: - removed | + added"
echo "=========================================="

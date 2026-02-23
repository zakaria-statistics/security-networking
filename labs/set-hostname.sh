#!/bin/bash
# Usage: ./set-hostname.sh <role>
# Example: ./set-hostname.sh m   → sets hostname to 192-168-11-104-m
#          ./set-hostname.sh w   → sets hostname to 192-168-11-108-w

ROLE="$1"

if [[ -z "$ROLE" ]]; then
  echo "Usage: $0 <role>  (e.g., m for master, w for worker)"
  exit 1
fi

# Auto-detect the primary IP (excludes loopback)
IP=$(hostname -I | awk '{print $1}')

if [[ -z "$IP" ]]; then
  echo "Error: Could not detect IP address"
  exit 1
fi

# Replace dots with dashes so the full hostname shows in the prompt
# (bash \h truncates at the first dot)
NEW_HOSTNAME="$(echo "$IP" | tr '.' '-')-${ROLE}"

echo "Setting hostname to: $NEW_HOSTNAME"
sudo hostnamectl set-hostname "$NEW_HOSTNAME"

# Update /etc/hosts so sudo doesn't complain
sudo sed -i "s/127\.0\.1\.1.*/127.0.1.1 $NEW_HOSTNAME/" /etc/hosts

echo "Done. New hostname: $(hostname)"

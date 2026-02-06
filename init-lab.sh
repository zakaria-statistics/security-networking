#!/bin/bash
# Initialize git repo for security lab with proper structure

cd /root/claude/system-network-security

# Initialize git if not already
if [ ! -d ".git" ]; then
    git init
    echo "Git repo initialized"
else
    echo "Git repo already exists"
fi

# Create directory structure
mkdir -p docs
mkdir -p scripts
mkdir -p configs
mkdir -p notes

# Move guides to docs/
mv -f security-lab-guide.md docs/ 2>/dev/null
mv -f iptables-packet-flow.md docs/ 2>/dev/null

# Create .gitignore
cat > .gitignore << 'EOF'
# Sensitive files
*.pem
*.key
*credentials*
*secret*
.env

# Backup files
*.backup
*.bak
*~

# Temporary files
*.tmp
*.log
*.pcap

# OS files
.DS_Store
Thumbs.db
EOF

# Create README
cat > README.md << 'EOF'
# System & Network Security Lab

> Hands-on security practice environment

## Structure

```
.
├── docs/           # Guides and documentation
├── scripts/        # Reusable scripts
├── configs/        # iptables, nftables, firewall configs
├── notes/          # Personal notes and observations
└── README.md
```

## Milestones

- [ ] **v0.1** - Basic firewall (UFW/iptables)
- [ ] **v0.2** - Network scanning (nmap)
- [ ] **v0.3** - Intrusion detection (fail2ban)
- [ ] **v0.4** - System hardening
- [ ] **v0.5** - NAT/routing practice
- [ ] **v0.6** - Penetration testing basics

## VM Info

- **IP:** 192.168.11.106
- **User:** ubuntu
- **Template:** 9000 (ubuntu-cloud-template)

## Quick Commands

```bash
# Save current iptables
./scripts/save-iptables.sh

# View git log with graph
git log --oneline --graph

# Create milestone tag
git tag -a v0.1 -m "Basic firewall configured"
```
EOF

echo "Structure created!"
echo ""
echo "Next: Run initial commit"

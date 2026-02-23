# System & Network Security Lab Guide
> Hands-on security practice for Ubuntu VM

## Table of Contents
1. [Network Security](#1-network-security) - iptables/nftables firewall configuration
2. [Security Scanning](#2-security-scanning) - nmap, port scanning, vulnerability assessment
3. [Intrusion Detection](#3-intrusion-detection) - fail2ban, log monitoring
4. [System Hardening](#4-system-hardening) - SSH, users, services lockdown
5. [Penetration Testing Basics](#5-penetration-testing-basics) - vulnerable targets, exploitation
6. [Quick Reference](#6-quick-reference) - common commands cheatsheet

---

## 1. Network Security

### 1.1 Understanding Linux Firewalls

```
iptables (legacy) → nftables (modern replacement)
                         ↓
              Both use Netfilter framework in kernel
```

**Check current firewall status:**
```bash
# Check if ufw is active (Ubuntu's frontend)
sudo ufw status

# Check iptables rules
sudo iptables -L -n -v

# Check nftables rules
sudo nft list ruleset
```

### 1.2 UFW (Uncomplicated Firewall) - Beginner Friendly

```bash
# Enable UFW
sudo ufw enable

# Default policies
sudo ufw default deny incoming
sudo ufw default allow outgoing

# Allow specific services
sudo ufw allow ssh          # Port 22
sudo ufw allow http         # Port 80
sudo ufw allow https        # Port 443
sudo ufw allow 8080/tcp     # Custom port

# Allow from specific IP
sudo ufw allow from 192.168.11.0/24 to any port 22

# Deny specific port
sudo ufw deny 23            # Block telnet

# Check status with rules
sudo ufw status numbered

# Delete a rule
sudo ufw delete 2           # Delete rule #2

# Reset all rules
sudo ufw reset
```

### 1.3 iptables - The Classic Approach

**Chain types:**
- `INPUT` - incoming traffic to this machine
- `OUTPUT` - outgoing traffic from this machine
- `FORWARD` - traffic passing through (routing)

```bash
# View current rules
sudo iptables -L -n -v --line-numbers

# Flush all rules (start fresh)
sudo iptables -F

# Set default policies
sudo iptables -P INPUT DROP
sudo iptables -P FORWARD DROP
sudo iptables -P OUTPUT ACCEPT

# Allow loopback
sudo iptables -A INPUT -i lo -j ACCEPT

# Allow established connections
sudo iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# Allow SSH
sudo iptables -A INPUT -p tcp --dport 22 -j ACCEPT

# Allow HTTP/HTTPS
sudo iptables -A INPUT -p tcp --dport 80 -j ACCEPT
sudo iptables -A INPUT -p tcp --dport 443 -j ACCEPT

# Allow ping (ICMP)
sudo iptables -A INPUT -p icmp --icmp-type echo-request -j ACCEPT

# Block specific IP
sudo iptables -A INPUT -s 10.10.10.50 -j DROP

# Log dropped packets
sudo iptables -A INPUT -j LOG --log-prefix "IPTables-Dropped: "

# Save rules (persist across reboot)
sudo apt install iptables-persistent
sudo netfilter-persistent save
```

### 1.4 nftables - Modern Replacement

```bash
# Install nftables
sudo apt install nftables

# Create a basic firewall script
sudo nano /etc/nftables.conf
```

**Basic nftables configuration:**
```nft
#!/usr/sbin/nft -f

flush ruleset

table inet filter {
    chain input {
        type filter hook input priority 0; policy drop;

        # Allow loopback
        iif lo accept

        # Allow established/related
        ct state established,related accept

        # Allow SSH
        tcp dport 22 accept

        # Allow HTTP/HTTPS
        tcp dport { 80, 443 } accept

        # Allow ICMP
        ip protocol icmp accept

        # Log and drop everything else
        log prefix "nftables dropped: " drop
    }

    chain forward {
        type filter hook forward priority 0; policy drop;
    }

    chain output {
        type filter hook output priority 0; policy accept;
    }
}
```

```bash
# Apply nftables rules
sudo nft -f /etc/nftables.conf

# Enable on boot
sudo systemctl enable nftables

# View current ruleset
sudo nft list ruleset
```

### 1.5 Practice Exercises - Network Security

```bash
# Exercise 1: Create a whitelist-only firewall
# - Allow only your IP to SSH
# - Block everything else

# Exercise 2: Rate limiting
sudo iptables -A INPUT -p tcp --dport 22 -m state --state NEW -m recent --set
sudo iptables -A INPUT -p tcp --dport 22 -m state --state NEW -m recent --update --seconds 60 --hitcount 4 -j DROP

# Exercise 3: Port knocking concept
# Research: knockd daemon for port knocking
```

---

## 2. Security Scanning

### 2.1 Install Scanning Tools

```bash
sudo apt update
sudo apt install -y nmap nikto netcat-openbsd tcpdump wireshark-common
```

### 2.2 Nmap - Network Mapper

**Basic scanning:**
```bash
# Ping scan - discover live hosts
nmap -sn 192.168.11.0/24

# Quick scan - top 100 ports
nmap -F 192.168.11.106

# Full port scan
nmap -p- 192.168.11.106

# Service/version detection
nmap -sV 192.168.11.106

# OS detection
sudo nmap -O 192.168.11.106

# Aggressive scan (OS, version, scripts, traceroute)
sudo nmap -A 192.168.11.106

# Stealth SYN scan
sudo nmap -sS 192.168.11.106

# UDP scan (slow)
sudo nmap -sU --top-ports 100 192.168.11.106
```

**Advanced scanning:**
```bash
# Scan specific ports
nmap -p 22,80,443,8080 192.168.11.106

# Scan port range
nmap -p 1-1000 192.168.11.106

# Skip host discovery (scan even if ping blocked)
nmap -Pn 192.168.11.106

# Output to file
nmap -oN scan_results.txt 192.168.11.106
nmap -oX scan_results.xml 192.168.11.106

# Timing templates (0=paranoid, 5=insane)
nmap -T4 192.168.11.106
```

**Nmap Scripting Engine (NSE):**
```bash
# List available scripts
ls /usr/share/nmap/scripts/

# Vulnerability scanning
nmap --script vuln 192.168.11.106

# HTTP enumeration
nmap --script http-enum 192.168.11.106

# SSH brute force (careful!)
nmap --script ssh-brute --script-args userdb=users.txt,passdb=passwords.txt 192.168.11.106

# SSL/TLS analysis
nmap --script ssl-enum-ciphers -p 443 192.168.11.106

# SMB vulnerabilities
nmap --script smb-vuln* 192.168.11.106
```

### 2.3 Netcat - Swiss Army Knife

```bash
# Port scanning
nc -zv 192.168.11.106 20-100

# Banner grabbing
nc -v 192.168.11.106 22
nc -v 192.168.11.106 80

# Simple listener (for testing)
nc -lvnp 4444

# Connect to listener
nc 192.168.11.106 4444

# Transfer file
# Receiver: nc -lvnp 4444 > received_file
# Sender:   nc 192.168.11.106 4444 < file_to_send
```

### 2.4 Tcpdump - Packet Capture

```bash
# Capture all traffic on interface
sudo tcpdump -i eth0

# Capture specific port
sudo tcpdump -i eth0 port 22

# Capture specific host
sudo tcpdump -i eth0 host 192.168.11.1

# Save to file
sudo tcpdump -i eth0 -w capture.pcap

# Read pcap file
tcpdump -r capture.pcap

# Verbose output
sudo tcpdump -i eth0 -vvv

# Show packet contents in hex/ASCII
sudo tcpdump -i eth0 -X
```

### 2.5 Vulnerability Assessment

```bash
# Nikto - web server scanner
nikto -h http://192.168.11.106

# Lynis - system audit
sudo apt install lynis
sudo lynis audit system

# OpenVAS/GVM (full vulnerability scanner - heavy)
# Install: https://greenbone.github.io/docs/latest/
```

### 2.6 Practice Exercises - Scanning

```bash
# Exercise 1: Scan your own VM from Proxmox host
# From Proxmox: nmap -A 192.168.11.106

# Exercise 2: Set up a web server and scan it
sudo apt install nginx
sudo systemctl start nginx
nmap --script http-enum localhost

# Exercise 3: Capture SSH login packets
sudo tcpdump -i eth0 port 22 -w ssh_traffic.pcap
# Then SSH from another machine and analyze
```

---

## 3. Intrusion Detection

### 3.1 Fail2ban - Brute Force Protection

```bash
# Install fail2ban
sudo apt install fail2ban

# Check status
sudo systemctl status fail2ban

# Configuration
sudo cp /etc/fail2ban/jail.conf /etc/fail2ban/jail.local
sudo nano /etc/fail2ban/jail.local
```

**Key jail.local settings:**
```ini
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5
banaction = iptables-multiport

[sshd]
enabled = true
port    = ssh
filter  = sshd
logpath = /var/log/auth.log
maxretry = 3
bantime = 24h
```

```bash
# Restart fail2ban
sudo systemctl restart fail2ban

# Check jail status
sudo fail2ban-client status
sudo fail2ban-client status sshd

# Manually ban/unban IP
sudo fail2ban-client set sshd banip 10.10.10.50
sudo fail2ban-client set sshd unbanip 10.10.10.50

# View banned IPs
sudo fail2ban-client get sshd banned

# Check fail2ban log
sudo tail -f /var/log/fail2ban.log
```

### 3.2 Log Monitoring

**Important log files:**
```bash
# Authentication logs
sudo tail -f /var/log/auth.log

# System logs
sudo tail -f /var/log/syslog

# Kernel messages
sudo dmesg | tail -50

# Failed login attempts
sudo grep "Failed password" /var/log/auth.log
sudo grep "Invalid user" /var/log/auth.log

# Successful logins
sudo grep "Accepted" /var/log/auth.log

# Last logins
last
lastb  # failed logins

# Currently logged in
who
w
```

**Log analysis tools:**
```bash
# Install logwatch
sudo apt install logwatch
sudo logwatch --detail high --mailto root --range today

# GoAccess for web logs
sudo apt install goaccess
sudo goaccess /var/log/nginx/access.log -o report.html --log-format=COMBINED
```

### 3.3 AIDE - File Integrity Monitoring

```bash
# Install AIDE
sudo apt install aide

# Initialize database
sudo aideinit

# Copy database
sudo cp /var/lib/aide/aide.db.new /var/lib/aide/aide.db

# Run check
sudo aide --check

# Update database after legitimate changes
sudo aide --update
sudo cp /var/lib/aide/aide.db.new /var/lib/aide/aide.db
```

### 3.4 rkhunter - Rootkit Detection

```bash
# Install rkhunter
sudo apt install rkhunter

# Update database
sudo rkhunter --update

# Run scan
sudo rkhunter --check

# Check logs
sudo cat /var/log/rkhunter.log
```

### 3.5 Practice Exercises - Intrusion Detection

```bash
# Exercise 1: Trigger fail2ban
# From another machine, try wrong SSH passwords 5+ times
# Watch: sudo tail -f /var/log/fail2ban.log

# Exercise 2: Monitor auth.log in real-time
sudo tail -f /var/log/auth.log
# SSH from Proxmox and watch the entries

# Exercise 3: AIDE detection
sudo touch /etc/test_file
sudo aide --check  # Should detect new file
```

---

## 4. System Hardening

### 4.1 SSH Hardening

```bash
sudo nano /etc/ssh/sshd_config
```

**Recommended settings:**
```bash
# Disable root login
PermitRootLogin no

# Disable password authentication (use keys only)
PasswordAuthentication no
PubkeyAuthentication yes

# Change default port (security through obscurity)
Port 2222

# Allow only specific users
AllowUsers ubuntu admin

# Disable empty passwords
PermitEmptyPasswords no

# Limit authentication attempts
MaxAuthTries 3

# Set login grace time
LoginGraceTime 30

# Disable X11 forwarding if not needed
X11Forwarding no

# Use strong ciphers only
Ciphers aes256-gcm@openssh.com,aes128-gcm@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com
KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org
```

```bash
# Test config before restarting
sudo sshd -t

# Restart SSH
sudo systemctl restart sshd

# Generate SSH key (on client)
ssh-keygen -t ed25519 -C "security-lab"

# Copy key to server
ssh-copy-id -i ~/.ssh/id_ed25519.pub ubuntu@192.168.11.106
```

### 4.2 User Management

```bash
# List all users
cat /etc/passwd

# List users with login shells
grep -v '/nologin\|/false' /etc/passwd

# Check sudo users
getent group sudo

# Create new user
sudo adduser secadmin

# Add to sudo group
sudo usermod -aG sudo secadmin

# Remove user
sudo deluser --remove-home olduser

# Lock user account
sudo passwd -l username

# Unlock user account
sudo passwd -u username

# Set password expiry
sudo chage -M 90 username  # Max 90 days
sudo chage -l username     # View policy

# Check for users with no password
sudo awk -F: '($2 == "") {print $1}' /etc/shadow
```

### 4.3 File Permissions

```bash
# Find world-writable files
sudo find / -type f -perm -002 -ls 2>/dev/null

# Find world-writable directories
sudo find / -type d -perm -002 -ls 2>/dev/null

# Find SUID files (run as owner)
sudo find / -type f -perm -4000 -ls 2>/dev/null

# Find SGID files (run as group)
sudo find / -type f -perm -2000 -ls 2>/dev/null

# Find files with no owner
sudo find / -nouser -o -nogroup 2>/dev/null

# Secure sensitive files
sudo chmod 600 /etc/shadow
sudo chmod 644 /etc/passwd
sudo chmod 700 /root
```

### 4.4 Service Lockdown

```bash
# List all running services
systemctl list-units --type=service --state=running

# List enabled services
systemctl list-unit-files --type=service --state=enabled

# Disable unnecessary services
sudo systemctl disable --now cups       # Printing
sudo systemctl disable --now avahi-daemon   # mDNS
sudo systemctl disable --now bluetooth  # Bluetooth

# Check listening ports
sudo ss -tulnp
sudo netstat -tulnp

# Remove unnecessary packages
sudo apt remove telnetd rsh-server
```

### 4.5 Kernel Hardening (sysctl)

```bash
sudo nano /etc/sysctl.d/99-security.conf
```

**Security settings:**
```bash
# Disable IP forwarding
net.ipv4.ip_forward = 0

# Disable ICMP redirects
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0

# Enable SYN flood protection
net.ipv4.tcp_syncookies = 1

# Disable source routing
net.ipv4.conf.all.accept_source_route = 0

# Log martian packets
net.ipv4.conf.all.log_martians = 1

# Ignore ICMP broadcasts
net.ipv4.icmp_echo_ignore_broadcasts = 1

# Enable ASLR
kernel.randomize_va_space = 2

# Restrict dmesg
kernel.dmesg_restrict = 1

# Restrict kernel pointers
kernel.kptr_restrict = 2
```

```bash
# Apply settings
sudo sysctl -p /etc/sysctl.d/99-security.conf
```

### 4.6 Automatic Security Updates

```bash
# Install unattended-upgrades
sudo apt install unattended-upgrades

# Enable automatic updates
sudo dpkg-reconfigure --priority=low unattended-upgrades

# Check configuration
cat /etc/apt/apt.conf.d/20auto-upgrades
```

### 4.7 Practice Exercises - Hardening

```bash
# Exercise 1: Harden SSH
# - Change port to 2222
# - Disable root login
# - Set MaxAuthTries to 3

# Exercise 2: Audit permissions
sudo find /home -perm -002 -ls

# Exercise 3: Create hardening script
# Combine all sysctl settings into one script
```

---

## 5. Penetration Testing Basics

### 5.1 Set Up Vulnerable Targets

**DVWA (Damn Vulnerable Web Application):**
```bash
# Install dependencies
sudo apt install apache2 mariadb-server php php-mysqli php-gd libapache2-mod-php git

# Clone DVWA
cd /var/www/html
sudo git clone https://github.com/digininja/DVWA.git
sudo chown -R www-data:www-data DVWA

# Configure database
sudo mysql -u root <<EOF
CREATE DATABASE dvwa;
CREATE USER 'dvwa'@'localhost' IDENTIFIED BY 'p@ssw0rd';
GRANT ALL PRIVILEGES ON dvwa.* TO 'dvwa'@'localhost';
FLUSH PRIVILEGES;
EOF

# Configure DVWA
cd /var/www/html/DVWA/config
sudo cp config.inc.php.dist config.inc.php
sudo nano config.inc.php
# Set: $_DVWA[ 'db_password' ] = 'p@ssw0rd';

# Restart Apache
sudo systemctl restart apache2

# Access: http://192.168.11.106/DVWA/setup.php
# Click "Create / Reset Database"
# Login: admin / password
```

**Metasploitable (alternative - VM):**
```bash
# Download Metasploitable 2 from Rapid7
# Import as separate VM in Proxmox
# Default creds: msfadmin:msfadmin
```

### 5.2 Basic Exploitation Concepts

**SQL Injection:**
```bash
# In DVWA login or search field:
' OR '1'='1
' OR '1'='1' --
' UNION SELECT 1,2,3 --
' UNION SELECT user(),database(),version() --
```

**Command Injection:**
```bash
# In ping field (DVWA):
; ls -la
| cat /etc/passwd
&& whoami
```

**XSS (Cross-Site Scripting):**
```html
<!-- In comment/input fields -->
<script>alert('XSS')</script>
<img src=x onerror=alert('XSS')>
```

### 5.3 Metasploit Framework

```bash
# Install Metasploit
curl https://raw.githubusercontent.com/rapid7/metasploit-omnibus/master/config/templates/metasploit-framework-wrappers/msfupdate.erb > msfinstall
chmod +x msfinstall
sudo ./msfinstall

# Start Metasploit
msfconsole

# Basic commands
msf6> search ssh
msf6> use auxiliary/scanner/ssh/ssh_version
msf6> show options
msf6> set RHOSTS 192.168.11.106
msf6> run

# Port scanning with Metasploit
msf6> use auxiliary/scanner/portscan/tcp
msf6> set RHOSTS 192.168.11.106
msf6> run
```

### 5.4 Password Attacks

```bash
# Install hydra
sudo apt install hydra

# SSH brute force (against your own systems only!)
hydra -l ubuntu -P /usr/share/wordlists/rockyou.txt ssh://192.168.11.106

# HTTP form brute force
hydra -l admin -P passwords.txt 192.168.11.106 http-post-form "/login:user=^USER^&pass=^PASS^:Invalid"

# Create wordlist
# Install wordlist
sudo apt install wordlists
sudo gunzip /usr/share/wordlists/rockyou.txt.gz
```

### 5.5 Practice Exercises - Pentesting

```bash
# Exercise 1: Full reconnaissance
# - Port scan the target
# - Identify services
# - Research vulnerabilities

# Exercise 2: DVWA challenges
# - Complete all DVWA modules on "Low" security
# - Document your payloads

# Exercise 3: Write a simple port scanner
cat > scanner.py << 'EOF'
#!/usr/bin/env python3
import socket
import sys

target = sys.argv[1] if len(sys.argv) > 1 else "127.0.0.1"
ports = range(1, 1025)

print(f"Scanning {target}")
for port in ports:
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.settimeout(0.5)
    result = sock.connect_ex((target, port))
    if result == 0:
        print(f"Port {port}: Open")
    sock.close()
EOF
chmod +x scanner.py
python3 scanner.py 192.168.11.106
```

---

## 6. Quick Reference

### Common Security Commands

| Task | Command |
|------|---------|
| Check listening ports | `sudo ss -tulnp` |
| View firewall rules | `sudo iptables -L -n -v` |
| Check fail2ban status | `sudo fail2ban-client status` |
| View auth logs | `sudo tail -f /var/log/auth.log` |
| List running services | `systemctl list-units --type=service --state=running` |
| Check open files by process | `sudo lsof -i -P` |
| Network connections | `netstat -an` or `ss -an` |
| Process tree | `ps auxf` |
| Last logins | `last` |
| Failed logins | `lastb` |

### Important Files

| File | Purpose |
|------|---------|
| `/etc/ssh/sshd_config` | SSH server configuration |
| `/etc/fail2ban/jail.local` | Fail2ban rules |
| `/var/log/auth.log` | Authentication logs |
| `/var/log/syslog` | System logs |
| `/etc/passwd` | User accounts |
| `/etc/shadow` | Password hashes |
| `/etc/sudoers` | Sudo permissions |

### Security Audit Checklist

- [ ] SSH: Root login disabled
- [ ] SSH: Password auth disabled (key only)
- [ ] Firewall: Enabled with default deny
- [ ] Fail2ban: Enabled for SSH
- [ ] Updates: Automatic security updates enabled
- [ ] Users: No unnecessary accounts
- [ ] Services: Only required services running
- [ ] Permissions: No world-writable sensitive files
- [ ] Logging: Auth logs being monitored

---

## Next Steps

1. **Start with basics** - Configure UFW and fail2ban first
2. **Practice scanning** - Scan your own VM from Proxmox
3. **Set up DVWA** - Practice web security
4. **Document everything** - Keep notes on what you learn
5. **Build a lab** - Add more VMs for network scenarios

**Useful Resources:**
- [OWASP Top 10](https://owasp.org/www-project-top-ten/)
- [HackTheBox](https://www.hackthebox.com/)
- [TryHackMe](https://tryhackme.com/)
- [OverTheWire Wargames](https://overthewire.org/wargames/)

# Security Audit — Azure Cloud Lab Setup

> Audit of `azure-cloud-lab-setup.md` for NSG misconfigurations, exposed services, IAM/RBAC gaps, and Azure best-practice violations.

## Table of Contents
1. [Critical Findings](#critical-findings) — Immediate risk to data confidentiality/integrity
2. [High Findings](#high-findings) — Significant exposure or missing controls
3. [Medium Findings](#medium-findings) — Visibility, governance, and hardening gaps
4. [Low Findings](#low-findings) — Minor improvements and hygiene
5. [Summary Matrix](#summary-matrix)

---

## Critical Findings

### C1. MySQL Deployed with No Authentication Hardening
- **Section:** 12 (VM — db-vm), lines 521–527
- **Issue:** Cloud-init installs MySQL and binds it to `0.0.0.0` but never:
  - Sets a root password
  - Runs `mysql_secure_installation` (removes anonymous users, test DB, remote root login)
  - Creates an application-specific database user with least-privilege grants
- **Impact:** Any host that can reach port 3306 (the entire `10.0.1.0/24` subnet) gets unauthenticated root access to MySQL. A compromised `web-vm` means full database control.
- **Fix:**
  ```bash
  # Add to cloud-init after mysql starts:
  mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '<strong-password>';"
  mysql -e "DELETE FROM mysql.user WHERE User='';"
  mysql -e "DROP DATABASE IF EXISTS test;"
  mysql -e "CREATE USER 'webapp'@'10.0.1.%' IDENTIFIED BY '<app-password>';"
  mysql -e "GRANT SELECT, INSERT, UPDATE, DELETE ON appdb.* TO 'webapp'@'10.0.1.%';"
  mysql -e "FLUSH PRIVILEGES;"
  ```

### C2. MySQL Bound to All Interfaces (`0.0.0.0`)
- **Section:** 12, line 525
- **Issue:** `bind-address = 0.0.0.0` makes MySQL listen on every interface. While NSGs restrict network access, this violates least-privilege at the service layer. If the NSG is ever loosened or bypassed (e.g., via a VNet peering misconfiguration), MySQL is exposed.
- **Fix:** Bind to the private IP only:
  ```bash
  sed -i "s/bind-address.*/bind-address = 10.0.2.4/" /etc/mysql/mysql.conf.d/mysqld.cnf
  ```

---

## High Findings

### H1. No TLS/HTTPS — All HTTP Traffic in Plaintext
- **Section:** 4, 7 (NSG rules), lines 166–176, 326–337
- **Issue:** Only port 80 is opened. All traffic between users and `web-vm` is unencrypted, including any form data, session tokens, or API calls.
- **Fix:** Use Let's Encrypt / Azure Application Gateway with TLS termination. At minimum add a redirect from 80 → 443 and open port 443 in both NSGs.

### H2. No Outbound (Egress) Restrictions
- **Section:** All NSGs (4, 5, 7, 8)
- **Issue:** No outbound NSG rules are defined. Azure's default allows all outbound traffic. A compromised VM can freely exfiltrate data, download malware, or establish C2 channels.
- **Fix:** Add explicit outbound deny-all with selective allows:
  ```bash
  # Allow DNS + HTTPS outbound, deny rest
  az network nsg rule create ... --name AllowDNSOut --direction Outbound --destination-port-ranges 53 --priority 100 --access Allow
  az network nsg rule create ... --name AllowHTTPSOut --direction Outbound --destination-port-ranges 443 --priority 200 --access Allow
  az network nsg rule create ... --name DenyAllOut --direction Outbound --destination-port-ranges '*' --priority 4000 --access Deny
  ```

### H3. SSH Exposed to Internet (Even with IP Restriction)
- **Section:** 4, 7 (NSG rules), lines 148–159, 309–322
- **Issue:** Port 22 is open to the internet, restricted only by `MY_IP`. This IP can change (DHCP, VPN, travel), and `ifconfig.me` resolution (line 80) is an external dependency that could return an incorrect value if behind a corporate NAT/proxy.
- **Fix:** Use Azure Bastion or JIT VM Access to eliminate port 22 exposure entirely. If SSH must stay:
  - Use Azure JIT VM Access (opens port 22 only on-demand for a time window)
  - Add an NSG deny-all for port 22 at a lower priority as a safety net

### H4. iptables Default Policy is ACCEPT
- **Section:** 11 (web-vm cloud-init), lines 465–491; noted in Section 15
- **Issue:** The OS firewall accepts all traffic by default. If an NSG rule is accidentally added or a new service starts listening, it's immediately reachable. This is partially addressed in Exercise 3, but the base deployment is insecure.
- **Fix:** Set default DROP in cloud-init:
  ```bash
  iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  iptables -A INPUT -i lo -j ACCEPT
  iptables -A INPUT -p tcp --dport 22 -j ACCEPT
  iptables -A INPUT -p tcp --dport 80 -j ACCEPT
  iptables -P INPUT DROP
  iptables -P FORWARD DROP
  apt-get install -y iptables-persistent
  netfilter-persistent save
  ```

### H5. Shared SSH Key Across Both VMs
- **Section:** 11, 12 (VM creation), lines 473, 520
- **Issue:** `--generate-ssh-keys` reuses `~/.ssh/id_rsa` if it already exists. Both VMs share the same key. Compromise of one key grants access to both VMs.
- **Fix:** Generate per-VM keys or use Azure Key Vault for SSH key management:
  ```bash
  ssh-keygen -t ed25519 -f ~/.ssh/web-vm-key -N ""
  ssh-keygen -t ed25519 -f ~/.ssh/db-vm-key -N ""
  # Use --ssh-key-values ~/.ssh/web-vm-key.pub for each VM
  ```

---

## Medium Findings

### M1. NSG Flow Logs Not Enabled
- **Section:** Noted in Section 15 but not implemented
- **Issue:** No visibility into allowed/denied traffic. Cannot detect scanning, brute-force attempts, or data exfiltration.
- **Fix:** Enable NSG flow logs → Log Analytics workspace for analysis and alerting.

### M2. Microsoft Defender for Cloud Not Enabled
- **Section:** Noted in Section 15 but not implemented
- **Issue:** No vulnerability scanning, threat detection, or security recommendations for the VMs.
- **Fix:** Enable at minimum the free tier: `az security pricing create --name VirtualMachines --tier Free`

### M3. DB Access Allowed from Entire Public Subnet, Not Specific Host
- **Section:** 5, 8 (private NSG rules), lines 210–216, 365–377
- **Issue:** Source address is `10.0.1.0/24` (entire public subnet) rather than `10.0.1.4/32` (web-vm only). Any future VM added to the public subnet automatically gets MySQL and SSH access to `db-vm`.
- **Fix:** Restrict source to `10.0.1.4/32` or use Application Security Groups (ASGs) to group VMs by role.

### M4. No Azure Diagnostic Settings or Activity Log Export
- **Issue:** No audit trail for resource modifications. An attacker who gains Azure control-plane access can modify NSGs undetected.
- **Fix:** Configure diagnostic settings on the resource group to send Activity Log to a Log Analytics workspace or Storage Account.

### M5. No Disk Encryption with Customer-Managed Keys
- **Section:** Noted in Section 15
- **Issue:** VMs use platform-managed encryption only. No control over key rotation or revocation.
- **Fix:** Use Azure Disk Encryption with Key Vault-managed keys for sensitive workloads.

### M6. `destination-address-prefixes '*'` Is Overly Broad
- **Section:** All NSG rules throughout (lines 159, 175, 216, 232, etc.)
- **Issue:** Every rule uses `'*'` as the destination prefix. Rules should target specific subnet CIDRs or the VM's private IP to limit lateral movement if a rule is cloned or repurposed.
- **Fix:** Use specific destination CIDRs (e.g., `10.0.1.0/24` for public subnet rules, `10.0.2.0/24` for private).

---

## Low Findings

### L1. Predictable Admin Username
- **Section:** 1 (Variables), line 79
- **Issue:** `ADMIN_USER="azurelab"` is easily guessable. Combined with SSH exposure, this reduces brute-force search space.
- **Fix:** Use a non-obvious username or rely entirely on key-based auth with password auth disabled.

### L2. No Resource Locks
- **Issue:** No `CanNotDelete` or `ReadOnly` locks on the resource group. Accidental `az group delete` destroys everything.
- **Fix:** `az lock create --name no-delete --resource-group "$RG" --lock-type CanNotDelete`

### L3. No Auto-Shutdown on VMs
- **Issue:** VMs run 24/7. Extends attack surface window and incurs unnecessary cost.
- **Fix:** `az vm auto-shutdown --resource-group "$RG" --name "$VM_NAME" --time 1900`

### L4. No RBAC Scoping or Service Principal
- **Issue:** The guide assumes the user runs with their full Azure CLI credentials (likely Owner or Contributor on the subscription). No mention of creating a scoped service principal or using a dedicated resource group role assignment.
- **Fix:** Create a service principal with Contributor scoped to the resource group only:
  ```bash
  az ad sp create-for-rbac --name "lab-deployer" --role Contributor --scopes /subscriptions/<sub-id>/resourceGroups/cloud-sec-lab
  ```

---

## Summary Matrix

| ID  | Severity | Finding | Section |
|-----|----------|---------|---------|
| C1  | Critical | MySQL no auth hardening (no root password, no user isolation) | 12 |
| C2  | Critical | MySQL bound to 0.0.0.0 instead of private IP | 12 |
| H1  | High     | No TLS — HTTP plaintext only | 4, 7 |
| H2  | High     | No outbound/egress NSG restrictions | All NSGs |
| H3  | High     | SSH exposed to internet (IP-restricted but fragile) | 4, 7 |
| H4  | High     | iptables default ACCEPT policy | 11 |
| H5  | High     | Shared SSH key across both VMs | 11, 12 |
| M1  | Medium   | NSG flow logs not enabled | 15 |
| M2  | Medium   | Microsoft Defender not enabled | 15 |
| M3  | Medium   | DB access from entire subnet, not specific host | 5, 8 |
| M4  | Medium   | No diagnostic settings / Activity Log export | — |
| M5  | Medium   | No customer-managed disk encryption | 15 |
| M6  | Medium   | Overly broad destination-address-prefixes '*' | All NSGs |
| L1  | Low      | Predictable admin username | 1 |
| L2  | Low      | No resource locks | — |
| L3  | Low      | No VM auto-shutdown | — |
| L4  | Low      | No RBAC scoping / runs with full CLI creds | — |

# Azure Lab Security Review — Agent Team Prompt

Read azure-cloud-lab-setup.md and create a team called `azure-review` 
with 2 parallel agents. After they finish, redo 
azure-cloud-lab-setup.md.

---

## Agent 1 — Architecture Reviewer
**Name:** `arch-reviewer`
**Model:** Sonnet

Review the Azure lab architecture:
- Identify gaps or missing components
- Suggest improvements to the overall design
- Create a excalidraw diagram of the architecture
- Document findings in review-architecture.md

---

## Agent 2 — Security Auditor
**Name:** `security-checker`
**Model:** Sonnet

Audit the Azure lab for security issues:
- Check for missing NSG rules or misconfigured policies
- Identify exposed services or ports
- Review IAM/RBAC configurations
- Flag anything that violates Azure security best practices
- Document findings in review-security.md

---

## Lead Synthesis (you opus)
After both agents report back, redo  
azure-cloud-lab-setup.md with:
1. Improved architecture with exaclidraw diagram
2. Security issues found with severity (critical/high/medium/low)
3. Recommended fixes with priority order
4. Final improved version of the lab setup

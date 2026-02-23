# iptables Lab — Debug Log
> Tracking issues encountered during lab exercises and their mitigations

## Table of Contents
1. [Port Knocking Timeout](#1-port-knocking-timeout) - Knock sequence fails due to timing

---

## 1. Port Knocking Timeout

**Phase:** 8 — Port Knocking

**Symptom:**
SSH connection times out after performing the knock sequence (ports 7000 → 8000 → 9000).

**Root Cause:**
The `recent` module enforces strict time windows:
- `--seconds 10` between each knock stage
- `--seconds 15` after the final knock to allow SSH

Typing each `nc` command manually introduces enough delay to exceed these windows. Packet counters confirmed KNOCK2 and KNOCK3 never matched (0 pkts).

**Diagnosis method:**
```bash
iptables -L -v -n --line-numbers
```
Check `pkts` counters on each KNOCK chain — 0 pkts means the stage was never reached.

**Mitigation:**
Chain all knocks and SSH on a single line so they execute back-to-back:
```bash
nc -zw1 <target> 7000; nc -zw1 <target> 8000; nc -zw1 <target> 9000; ssh user@<target>
```

**Lesson:**
Port knocking is time-sensitive by design. The tight `--seconds` windows are a security feature — they make brute-forcing the sequence harder. Always script knock sequences rather than typing them manually.

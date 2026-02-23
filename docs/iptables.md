IPTables Basics: Tables, Chains, and Rules
iptables is a powerful command-line utility for configuring the Linux kernel's built-in firewall (Netfilter) to filter network packets, allowing administrators to control traffic flow by defining tables, chains, and rules to either allow, drop, or reject incoming, outgoing, and forwarded network traffic, serving as a fundamental tool for system security and Network Address Translation (NAT).

![alt text](<Screenshot 2026-02-01 145901.png>)

Figure 1: iptables processing flowchart

Key Concepts:

Tables: Collections of chains, with filter, nat, and mangle being common ones for different packet processing tasks.
Chains: Ordered lists of rules within a table (e.g., INPUT, OUTPUT, FORWARD in the filter table).
Rules: Conditions that match packets (e.g., by IP, port, protocol).
Targets: Actions to take on a matched packet (e.g., ACCEPT, DROP, REJECT, or JUMP to another chain).
Policy: The default action for a chain if no rules match (e.g., ACCEPT or DROP).

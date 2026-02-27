root@k8s-cp:~# iptables -L
Chain INPUT (policy ACCEPT)
target     prot opt source               destination         
KUBE-PROXY-FIREWALL  all  --  anywhere             anywhere             ctstate NEW /* kubernetes load balancer firewall */
KUBE-NODEPORTS  all  --  anywhere             anywhere             /* kubernetes health check service ports */
KUBE-EXTERNAL-SERVICES  all  --  anywhere             anywhere             ctstate NEW /* kubernetes externally-visible service portals */
KUBE-FIREWALL  all  --  anywhere             anywhere            

Chain FORWARD (policy ACCEPT)
target     prot opt source               destination         
KUBE-PROXY-FIREWALL  all  --  anywhere             anywhere             ctstate NEW /* kubernetes load balancer firewall */
KUBE-FORWARD  all  --  anywhere             anywhere             /* kubernetes forwarding rules */
KUBE-SERVICES  all  --  anywhere             anywhere             ctstate NEW /* kubernetes service portals */
KUBE-EXTERNAL-SERVICES  all  --  anywhere             anywhere             ctstate NEW /* kubernetes externally-visible service portals */
FLANNEL-FWD  all  --  anywhere             anywhere             /* flanneld forward */

Chain OUTPUT (policy ACCEPT)
target     prot opt source               destination         
KUBE-PROXY-FIREWALL  all  --  anywhere             anywhere             ctstate NEW /* kubernetes load balancer firewall */
KUBE-SERVICES  all  --  anywhere             anywhere             ctstate NEW /* kubernetes service portals */
KUBE-FIREWALL  all  --  anywhere             anywhere            

Chain FLANNEL-FWD (1 references)
target     prot opt source               destination         
ACCEPT     all  --  10.244.0.0/16        anywhere             /* flanneld forward */
ACCEPT     all  --  anywhere             10.244.0.0/16        /* flanneld forward */

Chain KUBE-EXTERNAL-SERVICES (2 references)
target     prot opt source               destination         

Chain KUBE-FIREWALL (2 references)
target     prot opt source               destination         
DROP       all  -- !localhost/8          localhost/8          /* block incoming localnet connections */ ! ctstate RELATED,ESTABLISHED,DNAT

Chain KUBE-FORWARD (1 references)
target     prot opt source               destination         
DROP       all  --  anywhere             anywhere             ctstate INVALID nfacct-name  ct_state_invalid_dropped_pkts
ACCEPT     all  --  anywhere             anywhere             /* kubernetes forwarding rules */
ACCEPT     all  --  anywhere             anywhere             /* kubernetes forwarding conntrack rule */ ctstate RELATED,ESTABLISHED

Chain KUBE-KUBELET-CANARY (0 references)
target     prot opt source               destination         

Chain KUBE-NODEPORTS (1 references)
target     prot opt source               destination         

Chain KUBE-PROXY-CANARY (0 references)
target     prot opt source               destination         

Chain KUBE-PROXY-FIREWALL (3 references)
target     prot opt source               destination         

Chain KUBE-SERVICES (2 references)
target     prot opt source               destination
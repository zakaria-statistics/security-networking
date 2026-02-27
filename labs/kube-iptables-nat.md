root@k8s-cp:~# iptables -t nat -L
Chain PREROUTING (policy ACCEPT)
target     prot opt source               destination         
KUBE-SERVICES  all  --  anywhere             anywhere             /* kubernetes service portals */

Chain INPUT (policy ACCEPT)
target     prot opt source               destination         

Chain OUTPUT (policy ACCEPT)
target     prot opt source               destination         
KUBE-SERVICES  all  --  anywhere             anywhere             /* kubernetes service portals */

Chain POSTROUTING (policy ACCEPT)
target     prot opt source               destination         
KUBE-POSTROUTING  all  --  anywhere             anywhere             /* kubernetes postrouting rules */
FLANNEL-POSTRTG  all  --  anywhere             anywhere             /* flanneld masq */

Chain FLANNEL-POSTRTG (1 references)
target     prot opt source               destination         
RETURN     all  --  anywhere             anywhere             /* flanneld masq */
RETURN     all  --  k8s-cp/24            k8s-cp/16            /* flanneld masq */
RETURN     all  --  k8s-cp/16            k8s-cp/24            /* flanneld masq */
RETURN     all  -- !10.244.0.0/16        10.244.0.0/24        /* flanneld masq */
MASQUERADE  all  --  10.244.0.0/16       !base-address.mcast.net/4  /* flanneld masq */ random-fully
MASQUERADE  all  -- !10.244.0.0/16        10.244.0.0/16        /* flanneld masq */ random-fully

Chain KUBE-KUBELET-CANARY (0 references)
target     prot opt source               destination         

Chain KUBE-MARK-MASQ (11 references)
target     prot opt source               destination         
MARK       all  --  anywhere             anywhere             MARK or 0x4000

Chain KUBE-NODEPORTS (1 references)
target     prot opt source               destination         

Chain KUBE-POSTROUTING (1 references)
target     prot opt source               destination         
RETURN     all  --  anywhere             anywhere            
MARK       all  --  anywhere             anywhere             MARK xor 0x4000
MASQUERADE  all  --  anywhere             anywhere             /* kubernetes service traffic requiring SNAT */ random-fully

Chain KUBE-PROXY-CANARY (0 references)
target     prot opt source               destination         

Chain KUBE-SEP-FVQSBIWR5JTECIVC (1 references)
target     prot opt source               destination         
KUBE-MARK-MASQ  all  --  10.244.0.5           anywhere             /* kube-system/kube-dns:metrics */
DNAT       tcp  --  anywhere             anywhere             /* kube-system/kube-dns:metrics */ tcp to:10.244.0.5:9153

Chain KUBE-SEP-LASJGFFJP3UOS6RQ (1 references)
target     prot opt source               destination         
KUBE-MARK-MASQ  all  --  10.244.0.5           anywhere             /* kube-system/kube-dns:dns-tcp */
DNAT       tcp  --  anywhere             anywhere             /* kube-system/kube-dns:dns-tcp */ tcp to:10.244.0.5:53

Chain KUBE-SEP-LPGSDLJ3FDW46N4W (1 references)
target     prot opt source               destination         
KUBE-MARK-MASQ  all  --  10.244.0.5           anywhere             /* kube-system/kube-dns:dns */
DNAT       udp  --  anywhere             anywhere             /* kube-system/kube-dns:dns */ udp to:10.244.0.5:53

Chain KUBE-SEP-PUHFDAMRBZWCPADU (1 references)
target     prot opt source               destination         
KUBE-MARK-MASQ  all  --  10.244.0.4           anywhere             /* kube-system/kube-dns:metrics */
DNAT       tcp  --  anywhere             anywhere             /* kube-system/kube-dns:metrics */ tcp to:10.244.0.4:9153

Chain KUBE-SEP-SF3LG62VAE5ALYDV (1 references)
target     prot opt source               destination         
KUBE-MARK-MASQ  all  --  10.244.0.4           anywhere             /* kube-system/kube-dns:dns-tcp */
DNAT       tcp  --  anywhere             anywhere             /* kube-system/kube-dns:dns-tcp */ tcp to:10.244.0.4:53

Chain KUBE-SEP-T6FTDWJB3J5OEA23 (1 references)
target     prot opt source               destination         
KUBE-MARK-MASQ  all  --  192.168.11.170       anywhere             /* default/kubernetes:https */
DNAT       tcp  --  anywhere             anywhere             /* default/kubernetes:https */ tcp to:192.168.11.170:6443

Chain KUBE-SEP-WXWGHGKZOCNYRYI7 (1 references)
target     prot opt source               destination         
KUBE-MARK-MASQ  all  --  10.244.0.4           anywhere             /* kube-system/kube-dns:dns */
DNAT       udp  --  anywhere             anywhere             /* kube-system/kube-dns:dns */ udp to:10.244.0.4:53

Chain KUBE-SERVICES (2 references)
target     prot opt source               destination         
KUBE-SVC-NPX46M4PTMTKRN6Y  tcp  --  anywhere             10.96.0.1            /* default/kubernetes:https cluster IP */
KUBE-SVC-TCOU7JCQXEZGVUNU  udp  --  anywhere             10.96.0.10           /* kube-system/kube-dns:dns cluster IP */
KUBE-SVC-ERIFXISQEP7F7OF4  tcp  --  anywhere             10.96.0.10           /* kube-system/kube-dns:dns-tcp cluster IP */
KUBE-SVC-JD5MR3NA4I4DYORP  tcp  --  anywhere             10.96.0.10           /* kube-system/kube-dns:metrics cluster IP */
KUBE-NODEPORTS  all  --  anywhere             anywhere             /* kubernetes service nodeports; NOTE: this must be the last rule in this chain */ ADDRTYPE match dst-type LOCAL

Chain KUBE-SVC-ERIFXISQEP7F7OF4 (1 references)
target     prot opt source               destination         
KUBE-MARK-MASQ  tcp  -- !10.244.0.0/16        10.96.0.10           /* kube-system/kube-dns:dns-tcp cluster IP */
KUBE-SEP-SF3LG62VAE5ALYDV  all  --  anywhere             anywhere             /* kube-system/kube-dns:dns-tcp -> 10.244.0.4:53 */ statistic mode random probability 0.50000000000
KUBE-SEP-LASJGFFJP3UOS6RQ  all  --  anywhere             anywhere             /* kube-system/kube-dns:dns-tcp -> 10.244.0.5:53 */

Chain KUBE-SVC-JD5MR3NA4I4DYORP (1 references)
target     prot opt source               destination         
KUBE-MARK-MASQ  tcp  -- !10.244.0.0/16        10.96.0.10           /* kube-system/kube-dns:metrics cluster IP */
KUBE-SEP-PUHFDAMRBZWCPADU  all  --  anywhere             anywhere             /* kube-system/kube-dns:metrics -> 10.244.0.4:9153 */ statistic mode random probability 0.50000000000
KUBE-SEP-FVQSBIWR5JTECIVC  all  --  anywhere             anywhere             /* kube-system/kube-dns:metrics -> 10.244.0.5:9153 */

Chain KUBE-SVC-NPX46M4PTMTKRN6Y (1 references)
target     prot opt source               destination         
KUBE-MARK-MASQ  tcp  -- !10.244.0.0/16        10.96.0.1            /* default/kubernetes:https cluster IP */
KUBE-SEP-T6FTDWJB3J5OEA23  all  --  anywhere             anywhere             /* default/kubernetes:https -> 192.168.11.170:6443 */

Chain KUBE-SVC-TCOU7JCQXEZGVUNU (1 references)
target     prot opt source               destination         
KUBE-MARK-MASQ  udp  -- !10.244.0.0/16        10.96.0.10           /* kube-system/kube-dns:dns cluster IP */
KUBE-SEP-WXWGHGKZOCNYRYI7  all  --  anywhere             anywhere             /* kube-system/kube-dns:dns -> 10.244.0.4:53 */ statistic mode random probability 0.50000000000
KUBE-SEP-LPGSDLJ3FDW46N4W  all  --  anywhere             anywhere             /* kube-system/kube-dns:dns -> 10.244.0.5:53 */
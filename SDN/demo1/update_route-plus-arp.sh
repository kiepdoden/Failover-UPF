#!/bin/bash

ip_n3=$1
ip_n3_old=$2

# ===== Cleanup old flows =====
ovs-ofctl del-flows br-ovs "ip,udp,nw_dst=$ip_n3"
ovs-ofctl del-flows br-ovs "ip,udp,nw_dst=$ip_n3_old"
ovs-ofctl del-flows br-ovs "ip,udp,nw_src=$ip_n3"
ovs-ofctl del-flows br-ovs "ip,udp,nw_src=$ip_n3_old"

ovs-ofctl del-flows br-ovs "arp,arp_tpa=$ip_n3"
ovs-ofctl del-flows br-ovs "arp,arp_tpa=$ip_n3_old"
ovs-ofctl del-flows br-ovs "arp,arp_spa=$ip_n3"
ovs-ofctl del-flows br-ovs "arp,arp_spa=$ip_n3_old"

# ===== UDP NAT =====
# DNAT: client -> UPF
ovs-ofctl add-flow br-ovs \
"ip,udp,nw_dst=$ip_n3_old,actions=mod_nw_dst:$ip_n3,output:2"

# SNAT: UPF -> client
ovs-ofctl add-flow br-ovs \
"ip,udp,nw_src=$ip_n3,actions=mod_nw_src:$ip_n3_old,output:1"

# ===== ARP NAT =====
# ARP request: IP ảo -> IP thật
ovs-ofctl add-flow br-ovs \
"arp,arp_op=1,arp_tpa=$ip_n3_old,actions=set_field:$ip_n3->arp_tpa,output:2"

# ARP reply: IP thật -> IP ảo
ovs-ofctl add-flow br-ovs \
"arp,arp_op=2,arp_spa=$ip_n3,actions=set_field:$ip_n3_old->arp_spa,output:1"

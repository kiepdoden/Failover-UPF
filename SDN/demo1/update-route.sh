ip_n3=$1
ip_n3_old=$2

ovs-ofctl del-flows br-ovs "ip,udp,nw_dst=$ip_n3"
ovs-ofctl del-flows br-ovs "ip,udp,nw_dst=$ip_n3_old"

ovs-ofctl add-flow br-ovs "ip,udp,nw_dst=$ip_n3_old,actions=mod_nw_dst:$ip_n3,output:2"

ovs-ofctl add-flow br-ovs "ip,udp,nw_src=$ip_n3,actions=mod_nw_src:$ip_n3_old,output:1"
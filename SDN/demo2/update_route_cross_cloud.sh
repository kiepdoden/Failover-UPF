#!/usr/bin/env bash
set -euo pipefail

# Called by Flask:
#   bash update_route_cross_cloud.sh <payload_new_n3> <old_n3>
#
# Example:
#   bash update_route_cross_cloud.sh 10.60.41.4 192.168.40.11
#
# By default, EFFECTIVE_TARGET = payload_new_n3.
# If AZURE_TRANSPORT_IP is set, EFFECTIVE_TARGET = AZURE_TRANSPORT_IP.
#
# For the new ens5 direction:
#   AZURE_TRANSPORT_IP=10.60.0.20
#
# This script uses:
#   - OVS cleanup only
#   - route via ens5
#   - iptables OUTPUT DNAT only
#   - no POSTROUTING SNAT

payload_n3="${1:?missing payload new N3 IP}"
ip_n3_old="${2:?missing old N3 IP}"

BRIDGE="${BRIDGE:-br-ovs}"
OF_VERSION="${OF_VERSION:-OpenFlow13}"

# AWS gNB host side.
# This should be the source IP used by nr-gnb for cross-cloud mode.
GNB_IP="${GNB_IP:-192.168.0.197}"
GTP_PORT="${GTP_PORT:-2152}"

# Cross-cloud transport path.
CROSS_DEV="${CROSS_DEV:-ens5}"
CROSS_GW="${CROSS_GW:-192.168.0.1}"

# If set, override controller's N3 and send to Azure mgmt/relay endpoint.
# If unset, use payload_n3 exactly like the old script.
EFFECTIVE_TARGET="${AZURE_TRANSPORT_IP:-$payload_n3}"
EFFECTIVE_TARGET_PORT="${AZURE_TRANSPORT_PORT:-$GTP_PORT}"

# Cookies used by previous scripts.
INSIDE_COOKIE="${INSIDE_COOKIE:-0x5101}"
CROSS_COOKIE_OLD="${CROSS_COOKIE_OLD:-0x5201}"
CROSS_COOKIE_ENS6="${CROSS_COOKIE_ENS6:-0x6201}"
COOKIE_MASK="0xffffffffffffffff"

COMMENT_DNAT="${COMMENT_DNAT:-upf-migrate-cross-output-dnat}"

echo "[cross-ens5] payload_new_n3=$payload_n3"
echo "[cross-ens5] old_n3=$ip_n3_old"
echo "[cross-ens5] effective_target=$EFFECTIVE_TARGET:$EFFECTIVE_TARGET_PORT"
echo "[cross-ens5] GNB_IP=$GNB_IP GTP_PORT=$GTP_PORT"
echo "[cross-ens5] route via $CROSS_GW dev $CROSS_DEV"
echo "[cross-ens5] mode=OUTPUT DNAT only, no POSTROUTING SNAT"

delete_nat_rules_by_comment() {
    local chain="$1"
    local comment="$2"

    while true; do
        line_no="$(iptables -t nat -L "$chain" --line-numbers -n 2>/dev/null | awk -v c="$comment" '$0 ~ c {print $1; exit}')"
        if [ -z "${line_no:-}" ]; then
            break
        fi
        iptables -t nat -D "$chain" "$line_no"
    done
}

echo "[cross-ens5] cleanup old OVS migration flows"

for cookie in "$INSIDE_COOKIE" "$CROSS_COOKIE_OLD" "$CROSS_COOKIE_ENS6"; do
    ovs-ofctl -O "$OF_VERSION" del-flows "$BRIDGE" "cookie=$cookie/$COOKIE_MASK" 2>/dev/null || true
done

ovs-ofctl -O "$OF_VERSION" del-groups "$BRIDGE" "group_id=200" 2>/dev/null || true

# Delete legacy non-cookie OVS flows.
for ip in \
    "$payload_n3" \
    "$ip_n3_old" \
    "$EFFECTIVE_TARGET" \
    10.60.41.4 \
    10.60.51.4 \
    10.60.61.4 \
    10.60.0.20
do
    ovs-ofctl -O "$OF_VERSION" del-flows "$BRIDGE" "ip,udp,nw_dst=$ip" 2>/dev/null || true
    ovs-ofctl -O "$OF_VERSION" del-flows "$BRIDGE" "ip,udp,nw_src=$ip" 2>/dev/null || true
    ovs-ofctl -O "$OF_VERSION" del-flows "$BRIDGE" "arp,arp_tpa=$ip" 2>/dev/null || true
    ovs-ofctl -O "$OF_VERSION" del-flows "$BRIDGE" "arp,arp_spa=$ip" 2>/dev/null || true
done

echo "[cross-ens5] cleanup old iptables NAT rules"

for c in \
    "$COMMENT_DNAT" \
    upf-migrate-cross-input-snat \
    upf-migrate-ens5-output-dnat \
    upf-migrate-ens5-postrouting-snat \
    upf-migrate-ens5-prerouting-dnat \
    upf-migrate-ens5-input-snat \
    upf-migrate-test
do
    delete_nat_rules_by_comment OUTPUT "$c"
    delete_nat_rules_by_comment INPUT "$c"
    delete_nat_rules_by_comment PREROUTING "$c"
    delete_nat_rules_by_comment POSTROUTING "$c"
done

echo "[cross-ens5] ensure route to effective target uses ens5"
ip route replace "$EFFECTIVE_TARGET/32" via "$CROSS_GW" dev "$CROSS_DEV" src "$GNB_IP"

echo "[cross-ens5] sysctl"
sysctl -w net.ipv4.ip_forward=1 >/dev/null
sysctl -w net.ipv4.conf.all.rp_filter=0 >/dev/null
sysctl -w net.ipv4.conf.default.rp_filter=0 >/dev/null
sysctl -w net.ipv4.conf."$CROSS_DEV".rp_filter=0 >/dev/null 2>&1 || true
sysctl -w net.ipv4.conf.int0.rp_filter=0 >/dev/null 2>&1 || true
sysctl -w net.ipv4.conf.ens6.rp_filter=0 >/dev/null 2>&1 || true

echo "[cross-ens5] install OUTPUT DNAT"
iptables -t nat -I OUTPUT 1 \
  -p udp \
  -d "$ip_n3_old" \
  --dport "$GTP_PORT" \
  -m comment --comment "$COMMENT_DNAT" \
  -j DNAT --to-destination "$EFFECTIVE_TARGET:$EFFECTIVE_TARGET_PORT"

ip route flush cache

if command -v conntrack >/dev/null 2>&1; then
    conntrack -D -p udp --orig-dst "$ip_n3_old" --dport "$GTP_PORT" 2>/dev/null || true
    conntrack -D -p udp --orig-dst "$payload_n3" --dport "$GTP_PORT" 2>/dev/null || true
    conntrack -D -p udp --orig-dst "$EFFECTIVE_TARGET" --dport "$EFFECTIVE_TARGET_PORT" 2>/dev/null || true
fi

echo "[cross-ens5] current route to effective target:"
ip route get "$EFFECTIVE_TARGET" || true

echo "[cross-ens5] current NAT OUTPUT rule:"
iptables -t nat -S OUTPUT | grep "$COMMENT_DNAT" || true

echo "[cross-ens5] remaining OVS migration flows:"
ovs-ofctl -O "$OF_VERSION" dump-flows "$BRIDGE" | grep -E "$payload_n3|$ip_n3_old|$EFFECTIVE_TARGET|10.60.0.20|$GTP_PORT|0x5101|0x5201|0x6201|group:200" || true

echo "[cross-ens5] done"

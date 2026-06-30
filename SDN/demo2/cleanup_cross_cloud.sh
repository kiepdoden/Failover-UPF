#!/usr/bin/env bash
set -euo pipefail

payload_n3="${1:-10.60.41.4}"
ip_n3_old="${2:-192.168.40.11}"

BRIDGE="${BRIDGE:-br-ovs}"
OF_VERSION="${OF_VERSION:-OpenFlow13}"

INSIDE_COOKIE="${INSIDE_COOKIE:-0x5101}"
CROSS_COOKIE_OLD="${CROSS_COOKIE_OLD:-0x5201}"
CROSS_COOKIE_ENS6="${CROSS_COOKIE_ENS6:-0x6201}"
COOKIE_MASK="0xffffffffffffffff"

GTP_PORT="${GTP_PORT:-2152}"
EFFECTIVE_TARGET="${AZURE_TRANSPORT_IP:-$payload_n3}"
EFFECTIVE_TARGET_PORT="${AZURE_TRANSPORT_PORT:-$GTP_PORT}"

COMMENT_DNAT="${COMMENT_DNAT:-upf-migrate-cross-output-dnat}"

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

echo "[cleanup-cross-ens5] delete iptables NAT rules"

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

echo "[cleanup-cross-ens5] delete OVS migration flows/groups"

for cookie in "$INSIDE_COOKIE" "$CROSS_COOKIE_OLD" "$CROSS_COOKIE_ENS6"; do
    ovs-ofctl -O "$OF_VERSION" del-flows "$BRIDGE" "cookie=$cookie/$COOKIE_MASK" 2>/dev/null || true
done

ovs-ofctl -O "$OF_VERSION" del-groups "$BRIDGE" "group_id=200" 2>/dev/null || true

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

echo "[cleanup-cross-ens5] flush conntrack if available"

if command -v conntrack >/dev/null 2>&1; then
    conntrack -D -p udp --orig-dst "$ip_n3_old" --dport "$GTP_PORT" 2>/dev/null || true
    conntrack -D -p udp --orig-dst "$payload_n3" --dport "$GTP_PORT" 2>/dev/null || true
    conntrack -D -p udp --orig-dst "$EFFECTIVE_TARGET" --dport "$EFFECTIVE_TARGET_PORT" 2>/dev/null || true
fi

ip route flush cache

echo "[cleanup-cross-ens5] remaining NAT migration rules:"
iptables -t nat -S | grep -E 'upf-migrate|192.168.40.11|10.60.41.4|10.60.0.20' || true

echo "[cleanup-cross-ens5] remaining OVS migration flows:"
ovs-ofctl -O "$OF_VERSION" dump-flows "$BRIDGE" | grep -E "$payload_n3|$ip_n3_old|$EFFECTIVE_TARGET|10.60.0.20|0x5101|0x5201|0x6201|group:200" || true

echo "[cleanup-cross-ens5] done"

#!/usr/bin/env bash
set -euo pipefail

BRIDGE="${BRIDGE:-br-ovs}"
OF_VERSION="${OF_VERSION:-OpenFlow13}"

ENS5_IF="${ENS5_IF:-ens5}"
ENS5_IP="${ENS5_IP:-192.168.0.197}"
ENS5_GW="${ENS5_GW:-192.168.0.1}"

INT0_IF="${INT0_IF:-int0}"
INT0_IP="${INT0_IP:-192.168.1.10}"

ENS6_IF="${ENS6_IF:-ens6}"

OLD_N3="${OLD_N3:-192.168.40.11}"
AZ_N3="${AZ_N3:-10.60.41.4}"
AZ_N4="${AZ_N4:-10.60.51.4}"
AZ_N6="${AZ_N6:-10.60.61.4}"
AZ_MGMT="${AZ_MGMT:-10.60.0.20}"

GTP_PORT="${GTP_PORT:-2152}"
SDN_PORT="${SDN_PORT:-8000}"

COOKIE_MASK="0xffffffffffffffff"
COOKIES=("0x5101" "0x5201" "0x6201")

echo "[reset] backup current state"
mkdir -p /tmp/gnb-reset-backup
ip -br addr > /tmp/gnb-reset-backup/ip_addr.before
ip route > /tmp/gnb-reset-backup/ip_route.before
sudo iptables-save > /tmp/gnb-reset-backup/iptables.before
sudo ovs-vsctl show > /tmp/gnb-reset-backup/ovs.before 2>/dev/null || true

delete_nat_rules_by_comment() {
    local chain="$1"
    local comment="$2"
    local line_no

    while true; do
        line_no="$(sudo iptables -t nat -L "$chain" --line-numbers -n 2>/dev/null | awk -v c="$comment" '$0 ~ c {print $1; exit}')"
        if [ -z "${line_no:-}" ]; then
            break
        fi
        sudo iptables -t nat -D "$chain" "$line_no"
    done
}

kill_sdn_server_by_port() {
    local port="$1"
    local pids=""
    local killed_pids=""
    local pid
    local comm
    local cmd

    echo "[reset] stop Python SDN server listening on TCP $port if running"

    pids="$(sudo ss -H -ltnp "sport = :$port" 2>/dev/null \
        | grep -oE 'pid=[0-9]+' \
        | cut -d= -f2 \
        | sort -u || true)"

    if [ -z "${pids:-}" ]; then
        echo "[reset] no process listening on TCP $port"
        return 0
    fi

    for pid in $pids; do
        comm="$(ps -p "$pid" -o comm= 2>/dev/null || true)"
        cmd="$(ps -p "$pid" -o args= 2>/dev/null || true)"

        echo "[reset] TCP $port owner: pid=$pid comm=$comm cmd=$cmd"

        # Only kill likely Python-based SDN servers.
        # This avoids killing unrelated services that coincidentally bind port 8000.
        if echo "$comm $cmd" | grep -qiE 'python|uvicorn|gunicorn|flask|fastapi'; then
            echo "[reset] terminate pid=$pid"
            sudo kill "$pid" 2>/dev/null || true
            killed_pids="$killed_pids $pid"
        else
            echo "[reset] skip pid=$pid because it does not look like a Python SDN server"
        fi
    done

    sleep 1

    for pid in $killed_pids; do
        if kill -0 "$pid" 2>/dev/null; then
            echo "[reset] pid=$pid still alive, force killing"
            sudo kill -9 "$pid" 2>/dev/null || true
        fi
    done
}

echo "[reset] stop nr-gnb / nr-ue / SDN server if running"
sudo pkill -f nr-gnb 2>/dev/null || true
sudo pkill -f nr-ue 2>/dev/null || true
kill_sdn_server_by_port "$SDN_PORT"
sleep 1

echo "[reset] check UDP 2152 owner after stop"
sudo ss -lunp | grep ":$GTP_PORT" || true

echo "[reset] check TCP $SDN_PORT owner after stop"
sudo ss -ltnp | grep ":$SDN_PORT" || true

echo "[reset] delete all previous SDN iptables NAT rules"
for comment in \
    upf-migrate-cross-output-dnat \
    upf-migrate-cross-input-snat \
    upf-migrate-ens5-output-dnat \
    upf-migrate-ens5-postrouting-snat \
    upf-migrate-ens5-prerouting-dnat \
    upf-migrate-ens5-input-snat \
    upf-migrate-test
do
    delete_nat_rules_by_comment OUTPUT "$comment"
    delete_nat_rules_by_comment INPUT "$comment"
    delete_nat_rules_by_comment PREROUTING "$comment"
    delete_nat_rules_by_comment POSTROUTING "$comment"
done

echo "[reset] delete old OVS migration flows/groups"
for cookie in "${COOKIES[@]}"; do
    sudo ovs-ofctl -O "$OF_VERSION" del-flows "$BRIDGE" "cookie=$cookie/$COOKIE_MASK" 2>/dev/null || true
done

sudo ovs-ofctl -O "$OF_VERSION" del-groups "$BRIDGE" "group_id=200" 2>/dev/null || true

for ip in "$OLD_N3" "$AZ_N3" "$AZ_N4" "$AZ_N6" "$AZ_MGMT"; do
    sudo ovs-ofctl -O "$OF_VERSION" del-flows "$BRIDGE" "ip,udp,nw_dst=$ip" 2>/dev/null || true
    sudo ovs-ofctl -O "$OF_VERSION" del-flows "$BRIDGE" "ip,udp,nw_src=$ip" 2>/dev/null || true
    sudo ovs-ofctl -O "$OF_VERSION" del-flows "$BRIDGE" "arp,arp_tpa=$ip" 2>/dev/null || true
    sudo ovs-ofctl -O "$OF_VERSION" del-flows "$BRIDGE" "arp,arp_spa=$ip" 2>/dev/null || true
done

echo "[reset] delete manual routes added during tests"
sudo ip route del "$AZ_N3/32" 2>/dev/null || true
sudo ip route del "$AZ_N4/32" 2>/dev/null || true
sudo ip route del "$AZ_N6/32" 2>/dev/null || true
sudo ip route del "$AZ_MGMT/32" 2>/dev/null || true

echo "[reset] restore interface roles"

# Do NOT flush ens5. It is SSH/mgmt.
sudo ip link set "$ENS5_IF" up

# int0 is the local gNB/OVS internal side.
sudo ip addr replace "$INT0_IP/24" dev "$INT0_IF"
sudo ip link set "$INT0_IF" up

# ens6 should be L2-only if it is an OVS physical port.
sudo ip addr flush dev "$ENS6_IF" 2>/dev/null || true
sudo ip link set "$ENS6_IF" up

echo "[reset] sysctl"
sudo sysctl -w net.ipv4.ip_forward=1 >/dev/null
sudo sysctl -w net.ipv4.conf.all.rp_filter=0 >/dev/null
sudo sysctl -w net.ipv4.conf.default.rp_filter=0 >/dev/null
sudo sysctl -w net.ipv4.conf."$ENS5_IF".rp_filter=0 >/dev/null 2>&1 || true
sudo sysctl -w net.ipv4.conf."$INT0_IF".rp_filter=0 >/dev/null 2>&1 || true
sudo sysctl -w net.ipv4.conf."$ENS6_IF".rp_filter=0 >/dev/null 2>&1 || true
sudo sysctl -w net.ipv4.conf."$INT0_IF".send_redirects=0 >/dev/null 2>&1 || true
sudo sysctl -w net.ipv4.conf."$ENS6_IF".send_redirects=0 >/dev/null 2>&1 || true

echo "[reset] flush conntrack/cache"
if command -v conntrack >/dev/null 2>&1; then
    sudo conntrack -D -p udp --orig-dst "$OLD_N3" --dport "$GTP_PORT" 2>/dev/null || true
    sudo conntrack -D -p udp --orig-dst "$AZ_N3" --dport "$GTP_PORT" 2>/dev/null || true
    sudo conntrack -D -p udp --orig-dst "$AZ_MGMT" --dport "$GTP_PORT" 2>/dev/null || true
fi
sudo ip route flush cache

echo
echo "========== RESET RESULT =========="

echo "[interfaces]"
ip -br addr show "$ENS5_IF" "$INT0_IF" "$ENS6_IF" || true

echo
echo "[routes]"
ip route | grep -E 'default|192.168.0.0|192.168.1.0|192.168.40.0|10.60.41.4|10.60.0.20' || true

echo
echo "[iptables NAT migration leftovers]"
sudo iptables -t nat -S | grep -E 'upf-migrate|192.168.40.11|10.60.41.4|10.60.0.20' || true

echo
echo "[OVS migration leftovers]"
sudo ovs-ofctl -O "$OF_VERSION" dump-flows "$BRIDGE" | grep -E "$OLD_N3|$AZ_N3|$AZ_MGMT|0x5101|0x5201|0x6201|group:200" || true

echo
echo "[UDP $GTP_PORT owner]"
sudo ss -lunp | grep ":$GTP_PORT" || true

echo
echo "[TCP $SDN_PORT owner]"
sudo ss -ltnp | grep ":$SDN_PORT" || true

echo
echo "[reset] done"

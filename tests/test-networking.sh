#!/usr/bin/env bash
# Test paranoid networking: WG-in-root + veth + namespace kill switch
# Does NOT require Mullvad credentials — tests isolation primitives only
set -euo pipefail

RED=$'\033[0;31m' GREEN=$'\033[0;32m' BOLD=$'\033[1m' RESET=$'\033[0m'
pass() { echo "${GREEN}  PASS: $*${RESET}"; }
fail() { echo "${RED}  FAIL: $*${RESET}"; FAILURES=$((FAILURES + 1)); }
info() { echo "${BOLD}:: $*${RESET}"; }

FAILURES=0
NS="paranoid-test-net"
WG="wg-test"
VH="veTesthost"
VN="veTestns"
TAP="tap-test"
IDX=250

cleanup() {
    iptables-save -t filter 2>/dev/null | grep "paranoid-test" | sed 's/-A /-D /' | \
        while IFS= read -r r; do iptables $r 2>/dev/null; done
    iptables-save -t nat 2>/dev/null | grep "paranoid-test" | sed 's/-A /-D /' | \
        while IFS= read -r r; do iptables -t nat $r 2>/dev/null; done
    ip rule del table 199 2>/dev/null || true
    ip route flush table 199 2>/dev/null || true
    ip link delete "$VH" 2>/dev/null || true
    ip link delete "$WG" 2>/dev/null || true
    ip netns delete "$NS" 2>/dev/null || true
    return 0
}
trap cleanup EXIT
[[ $EUID -eq 0 ]] || { echo "Run as root: sudo $0"; exit 1; }
cleanup 2>/dev/null || true

# === 1: Namespace ===
info "TEST 1: Namespace"
ip netns add "$NS"
ip netns exec "$NS" ip link set lo up
ip netns exec "$NS" sysctl -qw net.ipv6.conf.all.disable_ipv6=1
ip netns list | grep -q "^${NS}" && pass "Created" || fail "Creation failed"

# === 2: WG in root (NOT in namespace) ===
info "TEST 2: WireGuard in root"
PRIVKEY=$(wg genkey)
ip link add "$WG" type wireguard
KF=$(mktemp /dev/shm/.wg-XXXXXX); echo "$PRIVKEY" > "$KF"; chmod 600 "$KF"
wg set "$WG" private-key "$KF" \
    peer "VLz6FKDO7bJTG0bBKOjQjlRaLsOcBFGofPCHLBGAF18=" \
    endpoint "185.213.154.69:51820" allowed-ips "0.0.0.0/0" persistent-keepalive 25
rm -f "$KF"
ip addr add 10.68.99.99/32 dev "$WG"
ip link set "$WG" up
wg show "$WG" public-key | grep -q "." && pass "WG up, key set" || fail "WG key missing"

# === 3: Veth + policy routing ===
info "TEST 3: Veth transport"
ip link add "$VH" type veth peer name "$VN"
ip link set "$VN" netns "$NS"
ip addr add "10.99.${IDX}.2/30" dev "$VH"; ip link set "$VH" up
ip netns exec "$NS" ip addr add "10.99.${IDX}.1/30" dev "$VN"
ip netns exec "$NS" ip link set "$VN" up
ip netns exec "$NS" ip route add default via "10.99.${IDX}.2" dev "$VN"
ip route add default dev "$WG" table 199
ip rule add iif "$VH" table 199 priority 1199
sysctl -qw net.ipv4.ip_forward=1
ip rule list 2>/dev/null | grep -q "199" && pass "Policy routing set" || fail "Policy routing missing"

# === 4: TAP ===
info "TEST 4: TAP device"
ip netns exec "$NS" ip tuntap add dev "$TAP" mode tap
ip netns exec "$NS" ip addr add "10.155.${IDX}.1/24" dev "$TAP"
ip netns exec "$NS" ip link set "$TAP" up
ip netns exec "$NS" ip link show "$TAP" | grep -q "UP" && pass "TAP up" || fail "TAP down"

# === 5: Root iptables ===
info "TEST 5: Root firewall"
iptables -I FORWARD -o "$VH" -j DROP -m comment --comment "paranoid-test"
iptables -I FORWARD -i "$VH" -j DROP -m comment --comment "paranoid-test"
iptables -I FORWARD -o "$VH" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT -m comment --comment "paranoid-test"
iptables -I FORWARD -i "$VH" -o "$WG" -j ACCEPT -m comment --comment "paranoid-test"
iptables -t nat -A POSTROUTING -s "10.99.${IDX}.0/30" -o "$WG" -j MASQUERADE -m comment --comment "paranoid-test"
iptables -L FORWARD -n | grep -q "paranoid-test" && pass "iptables loaded" || fail "iptables missing"

# === 6: Namespace nftables ===
info "TEST 6: Namespace kill switch"
ip netns exec "$NS" nft -f - << EOF
table inet killswitch {
    chain output { type filter hook output priority 0; policy drop;
        oifname "lo" accept
        oifname "${VN}" ip version 4 accept
        ip daddr 10.155.${IDX}.0/24 accept
        ip6 version 6 drop
        drop
    }
    chain input { type filter hook input priority 0; policy drop;
        iifname "lo" accept
        ct state established,related accept
        ip saddr 10.155.${IDX}.0/24 accept
        iifname "${VN}" ct state established,related accept
        ip6 version 6 drop
        drop
    }
    chain forward { type filter hook forward priority 0; policy drop;
        iifname "tap-*" oifname "${VN}" ip version 4 accept
        ct state established,related accept
        ip6 version 6 drop
        drop
    }
}
table ip nat {
    chain postrouting {
        type nat hook postrouting priority 100; policy accept;
        oifname "${VN}" masquerade
    }
}
EOF
ip netns exec "$NS" sysctl -qw net.ipv4.ip_forward=1
ip netns exec "$NS" nft list ruleset | grep -q "killswitch" && pass "nftables loaded" || fail "nftables missing"

# === 7: Structural isolation ===
info "TEST 7: Structural isolation"
NS_IFACES=$(ip netns exec "$NS" ip -br link | awk '{print $1}')
echo "$NS_IFACES" | grep -q "wg-" && fail "WG in namespace!" || pass "No WG in namespace"
echo "$NS_IFACES" | grep -q "$VN" && pass "Veth is only exit" || fail "Veth missing"

# === 8: Kill switch ===
info "TEST 8: Kill switch blocks traffic"
ip netns exec "$NS" timeout 2 bash -c 'echo > /dev/tcp/1.1.1.1/80' 2>/dev/null \
    && fail "Internet LEAKED" || pass "Internet blocked"
ip netns exec "$NS" timeout 2 bash -c 'echo > /dev/tcp/192.168.1.1/80' 2>/dev/null \
    && fail "LAN LEAKED" || pass "LAN blocked"
ip netns exec "$NS" ping -c1 -W1 127.0.0.1 &>/dev/null \
    && pass "Loopback works" || fail "Loopback broken"

# === 9: Cleanup ===
info "TEST 9: Cleanup"
trap - EXIT
cleanup
ip netns list | grep -q "^${NS}" && fail "Namespace lingered" || pass "Namespace gone"
ip link show "$WG" &>/dev/null && fail "WG lingered" || pass "WG gone"

echo ""
[[ $FAILURES -eq 0 ]] && echo "${GREEN}${BOLD}ALL TESTS PASSED${RESET}" \
    || echo "${RED}${BOLD}${FAILURES} TEST(S) FAILED${RESET}"
exit $FAILURES

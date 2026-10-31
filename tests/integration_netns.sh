#!/usr/bin/env bash
# Real-kernel integration test. Run as root INSIDE A THROWAWAY NETWORK NAMESPACE so the
# host firewall is never touched:
#     sudo unshare --net bash tests/integration_netns.sh
# Needs: nft, iptables(-restore), ip6tables, ipset. Used by .github/workflows/ci.yml.
set -euo pipefail

[[ $(id -u) -eq 0 ]] || { echo "run as root inside 'unshare --net'" >&2; exit 1; }
# refuse to run in the host namespace (pid 1's netns)
if [[ $(readlink /proc/self/ns/net) == "$(readlink /proc/1/ns/net)" ]]; then
    echo "refusing: not in a separate network namespace (use: sudo unshare --net $0)" >&2; exit 1
fi
ip link set lo up 2>/dev/null || true

ROOT=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
printf 'Port 22\n' >"$T/sshd_config"
export IRB_ETC="$T/etc" IRB_RAW_BASE="file://$ROOT" IRB_SSHD_CONFIG="$T/sshd_config" IRB_LOCK="$T/lock"
export IRB_BIN="$T/bin/ir-isp-blocker" IRB_PERSIST=none SSH_CONNECTION="198.51.100.7 5555 192.0.2.1 22" NO_COLOR=1
S=(bash "$ROOT/ir-isp-blocker.sh" --yes)
fail() { echo "FAIL: $*" >&2; exit 1; }

for be in nft ipset iptables; do
    echo "=== backend $be"
    "${S[@]}" --backend "$be" block --isp mci,mtn --ports 443,8443 --docker yes
    case $be in
        nft) nft list table inet ir_isp_blocker | grep -q 'ip saddr @s_mci_4' || fail "nft set rule missing"
             nft list set inet ir_isp_blocker s_mci_4 | grep -q '5.' || fail "nft set empty" ;;
        ipset) iptables -S IRB-R1-IN | grep -q 'match-set irb4-mci src' || fail "ipset rule missing"
               ipset list irb4-mci | grep -q 'Number of entries' || fail "ipset missing"
               ip6tables -S IRB-R1-IN | grep -q 'irb6-mci' || fail "ip6tables rule missing"
               iptables -C INPUT -j IRB-INPUT || fail "INPUT jump missing" ;;
        iptables) [[ $(iptables -S IRB-R1-IN | wc -l) -gt 50 ]] || fail "plain iptables rules missing" ;;
    esac
    # idempotent re-apply must not duplicate jumps
    "${S[@]}" --backend "$be" apply
    if [[ $be != nft ]]; then
        [[ $(iptables -S INPUT | grep -c -- '-j IRB-INPUT') -eq 1 ]] || fail "duplicate INPUT jump"
    fi
    "${S[@]}" --backend "$be" whitelist add 203.0.113.9 9000
    "${S[@]}" --backend "$be" only --isp tci --ports 2053
    "${S[@]}" --backend "$be" block --isp tci --raw --log-only
    "${S[@]}" status
    "${S[@]}" --backend "$be" rollback
    "${S[@]}" --backend "$be" unblock --all
    nft list table inet ir_isp_blocker >/dev/null 2>&1 && fail "nft table left behind"
    iptables -S 2>/dev/null | grep -q 'IRB-' && fail "IRB chains left behind"
    ipset list -n 2>/dev/null | grep -q '^irb' && fail "ipsets left behind"
    rm -rf "$IRB_ETC"
done

echo "=== backend switch nft -> ipset leaves no nft table"
"${S[@]}" --backend nft block --isp mci --ports 443
"${S[@]}" --backend ipset block --isp mtn --ports 443
nft list table inet ir_isp_blocker >/dev/null 2>&1 && fail "nft table not removed after switch"
"${S[@]}" uninstall
echo "integration: OK"

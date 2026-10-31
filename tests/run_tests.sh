#!/usr/bin/env bash
# Unit/functional tests for ir-isp-blocker.sh. No root and no real firewall needed:
#  * --dry-run output is asserted for every backend and mode
#  * the real apply/commit/backup/rollback paths run against a fake `nft` (tests/fake-bin)
# Usage: bash tests/run_tests.sh
# shellcheck disable=SC2015,SC2016,SC2012  # intentional literal payloads; ok() always succeeds; "cond && ok || bad": ok() always succeeds
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$ROOT/ir-isp-blocker.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/irb-test.XXXXXX")
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0

base_url() { if command -v cygpath >/dev/null 2>&1; then echo "file://$(cygpath -m "$ROOT")"; else echo "file://$ROOT"; fi; }

reset_env() {
    rm -rf "${T:?}/etc" "${T:?}/state" "${T:?}/bin-installed"
    mkdir -p "$T/etc" "$T/state" "$T/ssh"
    printf 'Port 2222\n' >"$T/ssh/sshd_config"
    IRB_RAW_BASE="$(base_url)"
    export IRB_ETC="$T/etc" IRB_RAW_BASE IRB_SSHD_CONFIG="$T/ssh/sshd_config"
    export IRB_LOCK="$T/lock" IRB_BIN="$T/bin-installed/ir-isp-blocker" IRB_PERSIST=none
    export SSH_CONNECTION="5.6.7.8 5555 1.1.1.1 2222" NO_COLOR=1 FAKE_STATE="$T/state"
    unset IRB_BACKEND IRB_ASSUME_ROOT IRB_SKIP_PROBE FAKE_NFT_FAIL
}

ok()   { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; [[ -n ${2:-} ]] && printf '%s\n' "$2" | head -20 | sed 's/^/       | /'; }
irb()  { bash "$SCRIPT" "$@" 2>&1; }
has()  { grep -qF -- "$2" <<<"$1"; }
expect_has()   { if has "$2" "$3"; then ok "$1"; else bad "$1 (missing: $3)" "$2"; fi; }
expect_not()   { if has "$2" "$3"; then bad "$1 (unexpected: $3)" "$2"; else ok "$1"; fi; }
expect_rc()    { if [[ $2 -eq $3 ]]; then ok "$1"; else bad "$1 (rc=$2, want $3)" "${4:-}"; fi; }

echo "== static"
bash -n "$SCRIPT" && ok "bash -n" || bad "bash -n"
if command -v shellcheck >/dev/null; then
    out=$(shellcheck "$SCRIPT" "$0" 2>&1); expect_rc "shellcheck" $? 0 "$out"
else echo "  skip shellcheck (not installed)"; fi
out=$(irb --version); expect_has "--version" "$out" "ir-isp-blocker 2."
out=$(irb --help); expect_has "--help lists commands" "$out" "whitelist list"

echo "== dry-run / nftables"
reset_env
out=$(IRB_BACKEND=nft irb --dry-run block --isp mci,mtn --ports 443,8443 --proto tcp --docker no)
expect_has "table recreated atomically" "$out" "delete table inet ir_isp_blocker"
expect_has "one rule per ISP set (mci v4)" "$out" 'ip saddr @s_mci_4 counter drop comment "r1:mci"'
expect_has "IPv6 set rule" "$out" 'ip6 saddr @s_mtn_6 counter drop comment "r1:mtn"'
expect_has "port set + conntrack direction" "$out" 'ct direction original tcp dport { 443, 8443 } jump r1_in'
expect_has "ssh port exempted" "$out" 'tcp dport { 2222 } accept comment "ssh-protect"'
expect_has "ssh client auto-whitelisted" "$out" "5.6.7.8/32"
expect_not "no udp rule for --proto tcp" "$out" "udp dport { 443"
expect_not "no forward chain with --docker no" "$out" "hook forward"
n=$(grep -c 'saddr @' <<<"$out"); [[ $n -le 8 ]] && ok "rule count independent of CIDR count ($n)" || bad "too many rules ($n)"
[[ ! -f $T/etc/rules.conf ]] && ok "dry-run wrote no config" || bad "dry-run wrote config"
[[ ! -d $T/etc/lists ]] && ok "dry-run wrote no list cache" || bad "dry-run wrote list cache"

out=$(IRB_BACKEND=nft irb --dry-run block --isp tci --ports 2000-3000 --docker yes)
expect_has "forward hook matches original (pre-DNAT) port" "$out" "ct original proto-dst { 2000-3000 }"
out=$(IRB_BACKEND=nft irb --dry-run block --isp tci --direction out --reject --docker no)
expect_has "outbound uses daddr" "$out" 'ip daddr @s_tci_4 counter reject'
expect_has "output hook" "$out" "hook output"
out=$(IRB_BACKEND=nft irb --dry-run block --isp tci --raw --docker no)
expect_has "raw prerouting hook" "$out" "hook prerouting priority -300"
out=$(IRB_BACKEND=nft irb --dry-run only --isp tci --ports 443 --docker no)
expect_has "only: ISP returns" "$out" "ip saddr @s_tci_4 return"
expect_has "only: catch-all counted" "$out" 'counter drop comment "r1:others"'
out=$(IRB_BACKEND=nft irb --dry-run block --isp tci --log-only --ipv6 no --docker no)
expect_has "log-only counts then logs" "$out" "counter limit rate 10/minute log prefix"
expect_not "--ipv6 no drops v6 sets" "$out" "ipv6_addr"
out=$(IRB_BACKEND=nft irb --dry-run block --isp tci --ports 443 --rate-limit 20/minute --docker no)
expect_has "rate-limit dynamic set" "$out" "update @rl1_4 { ip saddr limit rate over 20/minute }"

echo "== dry-run / ipset + plain iptables"
out=$(IRB_BACKEND=ipset irb --dry-run block --isp mci --ports 443 --docker no)
expect_has "ipset atomic swap" "$out" "swap irb4-mci-n irb4-mci"
expect_has "iptables set match" "$out" "-m set --match-set irb4-mci src -m comment --comment r1:mci -j DROP"
expect_has "ip6tables restore generated" "$out" "===== ipt6.restore ====="
expect_not "raw table untouched when unused" "$out" "*raw"
out=$(IRB_BACKEND=iptables irb --dry-run block --isp mci --ports 443 --docker no --ipv6 no)
expect_has "plain iptables: per-CIDR rules in rule chain" "$out" "-A IRB-R1-IN -s "
expect_not "plain iptables: no ipset" "$out" "match-set"
out=$(IRB_BACKEND=ipset irb --dry-run block --isp mci --ports $(seq -s, 1000 1020) --docker no --ipv6 no)
c=$(grep -c -- '-A IRB-INPUT -p tcp -m multiport' <<<"$out"); [[ $c -eq 3 ]] && ok "multiport chunks of 15 (3 incl. ssh)" || bad "multiport chunking ($c)" "$out"

echo "== validation / safety"
out=$(IRB_BACKEND=nft irb --dry-run block --isp nosuchisp); expect_has "unknown ISP rejected" "$out" "unknown ISP"
out=$(IRB_BACKEND=nft irb --dry-run block --isp 'mci;id'); expect_has "injection in --isp rejected" "$out" "invalid ISP id"
out=$(IRB_BACKEND=nft irb --dry-run block --isp mci --ports '443;reboot'); expect_has "injection in --ports rejected" "$out" "invalid --ports"
out=$(IRB_BACKEND=nft irb --dry-run block --isp mci --ports 0); expect_has "port 0 rejected" "$out" "invalid --ports"
out=$(IRB_BACKEND=nft irb --dry-run block --isp mci --whitelist '1.2.3.4;x'); expect_has "bad whitelist rejected" "$out" "invalid whitelist"
out=$(IRB_SSH_PROBE=0 IRB_SSHD_CONFIG=/nonexistent IRB_BACKEND=nft irb --dry-run block --isp mci); expect_has "all-ports refused without SSH port" "$out" "Could not detect any SSH port"
out=$(IRB_SSH_PROBE=0 IRB_SSHD_CONFIG=/nonexistent IRB_BACKEND=nft irb --dry-run block --isp mci --ssh-port 22022)
expect_has "--ssh-port satisfies protection" "$out" "tcp dport { 22022 } accept"
out=$(IRB_BACKEND=nft irb --dry-run block --isp mci --no-ssh-protect); expect_has "no-ssh-protect needs --force" "$out" "refusing without --force"

echo "== custom lists (HTML / garbage must be rejected)"
printf '<html><body>404</body></html>\n' >"$T/evil.txt"
out=$(IRB_BACKEND=nft irb --dry-run block --list-file "$T/evil.txt" --name evil); expect_has "HTML list rejected" "$out" "rejected"
printf '1.2.3.0/24\n$(reboot)\n' >"$T/evil2.txt"
out=$(IRB_BACKEND=nft irb --dry-run block --list-file "$T/evil2.txt" --name evil2); expect_has "shell payload rejected" "$out" "rejected"
printf '0.0.0.0/1\n' >"$T/wide.txt"
out=$(IRB_BACKEND=nft irb --dry-run block --list-file "$T/wide.txt" --name wide); expect_has "too-wide prefix rejected" "$out" "rejected"
printf '# my list\n1.2.3.4/24\n1.2.3.0/24\n2001:db8:abcd::1/48\n\n' >"$T/good.txt"
out=$(IRB_BACKEND=nft irb --dry-run block --list-file "$T/good.txt" --name mine --ports 443 --docker no)
expect_has "custom list canonicalised + deduplicated (v4)" "$out" "1.2.3.0/24"
expect_has "custom list v6 canonicalised" "$out" "2001:db8:abcd::/48"
expect_has "custom set name" "$out" "s_c_mine_4"

echo "== list integrity (checksums)"
reset_env
mkdir -p "$T/mirror/lists"; cp "$ROOT"/lists/* "$T/mirror/lists/"
echo "9.9.9.0/24" >>"$T/mirror/lists/mci.v4"
src=$(if command -v cygpath >/dev/null; then cygpath -m "$T/mirror"; else echo "$T/mirror"; fi)
out=$(IRB_RAW_BASE="file://$src" IRB_BACKEND=nft irb --dry-run block --isp mci --ports 443); expect_has "tampered list detected" "$out" "checksum mismatch"
printf '<html>error</html>\n' >"$T/mirror/lists/SHA256SUMS"
out=$(IRB_RAW_BASE="file://$src" IRB_BACKEND=nft irb --dry-run block --isp mci --ports 443); expect_has "HTML instead of SHA256SUMS detected" "$out" "malformed"

echo "== apply / status / unblock / rollback with fake nft"
reset_env
export PATH="$ROOT/tests/fake-bin:$PATH" IRB_ASSUME_ROOT=1 IRB_SKIP_PROBE=1 IRB_BACKEND=nft
out=$(irb --yes block --isp mci --ports 443 --docker no); rc=$?
expect_rc "block applied" $rc 0 "$out"
[[ -f $T/state/ruleset ]] && ok "ruleset loaded into (fake) kernel" || bad "no ruleset applied"
grep -q '^id=1 mode=block isps=mci ports=443' "$T/etc/rules.conf" && ok "rules.conf committed" || bad "rules.conf not committed"
[[ -x $IRB_BIN ]] && ok "self-installed to IRB_BIN" || bad "not installed"
grep -q 'nft -c -f' "$T/state/calls.log" && ok "ruleset checked (nft -c) before apply" || bad "no nft -c"
grep -qx '5.6.7.8' "$T/etc/state/auto-whitelist" && ok "SSH client remembered" || bad "SSH client not remembered"
out=$(irb status); expect_has "status shows per-ISP hits" "$out" "hits=14"
out=$(irb --yes block --isp tci --ports 8443 --docker no)
grep -q '^id=2 ' "$T/etc/rules.conf" && ok "second rule appended" || bad "second rule missing"
out=$(FAKE_NFT_FAIL=1 irb --yes block --isp shatel --docker no); rc=$?
[[ $rc -ne 0 ]] && ok "failed apply returns error" || bad "failed apply returned 0"
grep -q 'shatel' "$T/etc/rules.conf" && bad "config committed despite failure" || ok "config not committed on failure"
out=$(irb --yes whitelist add 9.9.9.9 8080); grep -q '9.9.9.9/32' "$T/state/ruleset" && ok "whitelist IP applied" || bad "whitelist IP missing" "$out"
grep -q 'tcp dport { 8080 } accept' "$T/state/ruleset" && ok "whitelist port applied" || bad "whitelist port missing"
out=$(irb --yes unblock --isp mci); grep -q 'isps=mci' "$T/etc/rules.conf" && bad "mci still present" || ok "unblock --isp removes rule"
out=$(irb rollback --list); expect_has "backups listed" "$out" "unblock"
out=$(irb --yes rollback); rc=$?; expect_rc "rollback ok" $rc 0 "$out"
grep -q 'isps=mci' "$T/etc/rules.conf" && ok "rollback restored mci rule" || bad "rollback did not restore" "$(cat "$T/etc/rules.conf")"
out=$(irb export "$T/export.txt"); grep -q '^\[rules.conf\]' "$T/export.txt" && ok "export bundle" || bad "export failed"
out=$(irb --yes unblock --all); [[ ! -f $T/state/ruleset ]] && ok "unblock --all removes table" || bad "table still present"
out=$(irb --yes import "$T/export.txt"); grep -q 'isps=mci' "$T/etc/rules.conf" && ok "import restores rules" || bad "import failed" "$out"
printf '[rules.conf]\nid=1 mode=block isps=mci ports=all proto=any dir=in action=drop rate=30/minute raw=no expires=0 evil=$(id)\n' >"$T/bad-import.txt"
out=$(irb --yes import "$T/bad-import.txt"); expect_has "malicious import rejected" "$out" "unknown field"
past=$(( $(date +%s) - 10 ))
printf 'id=7 mode=block isps=tci ports=443 proto=both dir=in action=drop rate=30/minute raw=no expires=%s\n' "$past" >>"$T/etc/rules.conf"
out=$(irb expire); grep -q '^id=7 ' "$T/etc/rules.conf" && bad "expired rule kept" "$out" || ok "expired rule pruned"
out=$(irb --yes block --isp tci --ports 443 --for 2h --docker no); grep -Eq 'expires=[1-9][0-9]+' "$T/etc/rules.conf" && ok "--for sets expiry" || bad "--for missing"
out=$(QUIET=1 irb restore); rc=$?; expect_rc "boot restore (offline) works" $rc 0 "$out"
nb=$(ls "$T/etc/backups" | wc -l); [[ $nb -le 10 ]] && ok "backups rotated ($nb <= 10)" || bad "too many backups ($nb)"
out=$(irb --yes uninstall); [[ ! -d $T/etc && ! -e $IRB_BIN ]] && ok "uninstall removes everything" || bad "uninstall left files" "$out"

echo "== interactive menu (driven through stdin with the functions sourced)"
reset_env
export IRB_ASSUME_ROOT=1 IRB_SKIP_PROBE=1 IRB_BACKEND=nft
printf 'x
1,mtn
99999
443,8443
2
1
1

n
1.1.1.1
' >"$T/menu1.txt"
printf '3
' >"$T/menu2.txt"
IRB_NO_MAIN=1 bash -c 'source "$1"; ASSUME_YES=1; ensure_index >/dev/null; reset_opts; menu_block block <"$2"' _ "$SCRIPT" "$T/menu1.txt" >"$T/menu.out" 2>&1
grep -q '^id=1 mode=block isps=mci,mtn ports=443,8443 proto=tcp dir=in action=drop' "$T/etc/rules.conf" 2>/dev/null &&
    ok "menu: invalid input re-asked, rule created" || bad "menu block failed" "$(cat "$T/menu.out")"
grep -qx '1.1.1.1' "$T/etc/whitelist.ips" 2>/dev/null && ok "menu: whitelist IP stored" || bad "menu whitelist missing"
IRB_NO_MAIN=1 bash -c 'source "$1"; ASSUME_YES=1; reset_opts; menu_unblock <"$2"' _ "$SCRIPT" "$T/menu2.txt" >"$T/menu.out" 2>&1
grep -q '^id=' "$T/etc/rules.conf" && bad "menu unblock-all failed" "$(cat "$T/menu.out")" || ok "menu: unblock everything"

echo "== v1 migration (fake iptables with an old isp-blocker chain)"
reset_env
export IRB_ASSUME_ROOT=1 IRB_SKIP_PROBE=1 IRB_BACKEND=nft
cat >"$T/legacy.txt" <<'EOF'
-N isp-blocker
-A isp-blocker -s 9.9.9.9/32 -j ACCEPT
-A isp-blocker -s 5.22.0.0/20 -p tcp -m tcp --dport 443 -j DROP
-A isp-blocker -s 5.22.16.0/20 -p tcp -m tcp --dport 443 -j DROP
-A isp-blocker -s 2.144.0.0/18 -p tcp -m tcp --dport 443 -j DROP
EOF
out=$(FAKE_LEGACY="$T/legacy.txt" irb status); expect_has "v1 chain detected" "$out" "isp-blocker"
out=$(FAKE_LEGACY="$T/legacy.txt" irb --yes migrate); rc=$?; expect_rc "migrate ok" $rc 0 "$out"
grep -q '^id=1 mode=block isps=mci,mtn ports=443 proto=tcp' "$T/etc/rules.conf" && ok "v1 rules imported (ISPs inferred, tcp/443)" || bad "migrate import wrong" "$(cat "$T/etc/rules.conf" 2>/dev/null; echo "$out")"
grep -qx '9.9.9.9/32' "$T/etc/whitelist.ips" && ok "v1 whitelist imported" || bad "v1 whitelist missing"
[[ ! -f $T/legacy.txt ]] && ok "v1 chain removed" || bad "v1 chain not removed"
cat >"$T/legacy2.txt" <<'EOF'
-N isp-blocker
-A isp-blocker -p tcp -m tcp --dport 22 -j ACCEPT
-A isp-blocker -s 5.22.0.0/20 -p udp -m udp --dport 2053 -j ACCEPT
-A isp-blocker -s 5.22.0.0/20 -p tcp -m tcp --dport 2053 -j ACCEPT
-A isp-blocker -p tcp -m tcp --dport 2053 -j DROP
-A isp-blocker -p udp -m udp --dport 2053 -j DROP
EOF
rm -rf "${T:?}/etc"
out=$(FAKE_LEGACY="$T/legacy2.txt" irb --yes migrate)
grep -q '^id=1 mode=only isps=mci ports=2053 proto=both' "$T/etc/rules.conf" && ok "v1 only-mode imported as 'only'" || bad "only-mode migrate wrong" "$(cat "$T/etc/rules.conf" 2>/dev/null; echo "$out")"

echo "== menu: settings / update / rollback / backup screens"
reset_env
export IRB_ASSUME_ROOT=1 IRB_SKIP_PROBE=1 IRB_BACKEND=nft
printf '1\nno\n7\n' >"$T/m3.txt"
IRB_NO_MAIN=1 bash -c 'source "$1"; ASSUME_YES=1; ensure_index >/dev/null; reset_opts; menu_settings <"$2"' _ "$SCRIPT" "$T/m3.txt" >"$T/menu.out" 2>&1
grep -qx 'IPV6=no' "$T/etc/config" 2>/dev/null && ok "menu settings: IPv6 switched off" || bad "menu settings failed" "$(cat "$T/menu.out")"
printf '3\n' >"$T/m4.txt"
IRB_NO_MAIN=1 bash -c 'source "$1"; ASSUME_YES=1; ensure_index >/dev/null; reset_opts; menu_update <"$2"' _ "$SCRIPT" "$T/m4.txt" >"$T/menu.out" 2>&1
grep -qx 'AUTO_UPDATE=daily' "$T/etc/config" 2>/dev/null && ok "menu update: automatic daily" || bad "menu update failed" "$(cat "$T/menu.out")"
printf '1\n' >"$T/m5.txt"
out=$(IRB_NO_MAIN=1 bash -c 'source "$1"; ASSUME_YES=1; reset_opts; menu_rollback <"$2"' _ "$SCRIPT" "$T/m5.txt" 2>&1)
expect_has "menu rollback lists backups" "$out" "settings"
printf '1\n%s\n' "$T/cfg-export.txt" >"$T/m6.txt"
IRB_NO_MAIN=1 bash -c 'source "$1"; ASSUME_YES=1; reset_opts; menu_backup <"$2"' _ "$SCRIPT" "$T/m6.txt" >"$T/menu.out" 2>&1
grep -q '^\[config\]' "$T/cfg-export.txt" 2>/dev/null && ok "menu backup: export written" || bad "menu export failed" "$(cat "$T/menu.out")"
out=$(IRB_NO_MAIN=1 bash -c 'source "$1"; ensure_index >/dev/null 2>&1; show_isps' _ "$SCRIPT" 2>&1)
expect_has "ISP picker lists categories" "$out" "DATACENTER"

echo "== v2 replaces v1 automatically on the next command"
reset_env
export IRB_ASSUME_ROOT=1 IRB_SKIP_PROBE=1 IRB_BACKEND=nft
cat >"$T/legacy3.txt" <<'EOF'
-N isp-blocker
-A isp-blocker -s 5.22.0.0/20 -p tcp -m tcp --dport 443 -j DROP
-A isp-blocker -s 2.144.0.0/18 -p tcp -m tcp --dport 443 -j DROP
EOF
out=$(FAKE_LEGACY="$T/legacy3.txt" irb --yes block --isp tci --ports 8443 --docker no)
[[ ! -f $T/legacy3.txt ]] && ok "v1 chain removed without a prompt" || bad "v1 chain still there" "$out"
grep -q '^id=1 mode=block isps=mci,mtn ports=443' "$T/etc/rules.conf" && grep -q '^id=2 mode=block isps=tci ports=8443' "$T/etc/rules.conf" &&
    ok "v1 rules imported, new rule added" || bad "auto-migrate result wrong" "$(cat "$T/etc/rules.conf" 2>/dev/null; echo "$out")"

echo
echo "passed: $PASS  failed: $FAIL"
[[ $FAIL -eq 0 ]]

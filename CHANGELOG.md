# Changelog

## v2.0.0

Complete rewrite. English-only. The interactive menu covers every feature (custom ASN/URL/file
sources, time limits, rate limits, settings, scheduled list updates, rollback and backups,
export/import). v1 installations are replaced automatically: the old iptables chain is imported and
removed on the first v2 command. List updates run weekly by default.

### Engine
- nftables backend (one `inet ir_isp_blocker` table, interval sets, atomic `nft -f` after `nft -c`),
  with automatic fallback to iptables + ipset (atomic `swap`) and plain iptables.
- One rule per ISP set per rule instead of one rule per CIDR per port; lists aggregated.
- IPv4 **and IPv6**.
- Dedicated table/chains only; whitelists use `accept`-in-own-table / `RETURN`, never opening
  anything in other firewalls. Coexists with ufw, firewalld and Docker (`DOCKER-USER` / forward
  hook matching the original pre-DNAT port).
- `--direction in|out|both` based on conntrack direction (inbound blocking no longer breaks the
  server's own outbound connections), optional raw/prerouting mode.
- Actions: drop, reject, log-only (monitor, with per-ISP hit counters in `status`), rate-limit.
- Time-limited rules (`--for 24h`), port ranges, protocol selection, `only` mode.

### Safety
- SSH port detection (sshd_config, sshd_config.d, `ss`) with mandatory exemption; current SSH
  client IP auto-whitelisted; all-ports rules refused without SSH protection.
- Dead-man switch `--rollback-after`, automatic backups + `rollback`, `--dry-run`, `flock`.
- Every list line validated and canonicalised as CIDR before use (HTML/error pages rejected);
  over-wide prefixes refused; config parsed as data, never sourced.

### Persistence & install
- systemd unit (OpenRC / rc.local fallback) restoring rules at boot from cached lists,
  independent of iptables-persistent. Optional update/expiry timers (cron fallback).
- `install`, `uninstall`, config under `/etc/ir-isp-blocker/`, `export`/`import`.
- Prerequisite installation via apt, dnf/yum, pacman, apk or zypper.

### CLI
- Subcommands: `block`, `only`, `unblock`, `status`, `list`, `update`, `whitelist`, `rollback`,
  `confirm`, `apply`, `restore`, `expire`, `migrate`, `doctor`, `export`, `import`, `install`,
  `uninstall`. Loop-based, validated interactive menu; colours only
  on a TTY, `NO_COLOR` respected.

### Data
- New generator `tools/ipgen.py` (stdlib only) building lists from RIPEstat (holder-verified
  ASNs) and RIPE delegated stats (`all-ir`), declarative catalogue `data/isps.json`,
  `lists/` with IPv4/IPv6 files, `index.tsv`, `asns.tsv`, `SHA256SUMS`.
- 21 additional networks (HiWEB, Sepanta, Afranet, Respina, Mabna, Andisheh Sabz Khazar, Sabanet,
  FANAP Telecom, Fanava, Datak, Neda Gostar Saba, TIC, DCI, IPM, ArvanCloud, HostIran, Sotoon,
  MizbanCloud, ServerPars, MobinHost, Abramad), `all-ir`, custom `--asn` and custom lists.
- Weekly GitHub Actions regeneration with sanity checks (syntax, aggregation, checksums,
  >50 % shrink guard). v1 root `*-ips.ipv4` files kept and regenerated for old clients.
- Removed stale entries from the v1 lists (e.g. 151.240.0.0/13 in the Shatel list is not
  announced by Shatel).

### Migration
- `migrate` imports the v1 `isp-blocker` chain (ports, whitelists, inferred ISPs) and removes it,
  including its lines in `/etc/iptables/rules.v4`.

## v1.x
- Interactive bash script adding iptables rules per CIDR to the `isp-blocker` chain.

<h1 align="center">IR-ISP-Blocker</h1>

<div align="center">
    <a href="https://t.me/savechannelkiya6955"> <img src="https://img.shields.io/badge/TelegramChannel-%230577B8?logo=telegram" alt="Telegram channel"/> </a>
    <a href="https://github.com/Kiya6955/IR-ISP-Blocker"> <img src="https://img.shields.io/github/stars/Kiya6955/IR-ISP-Blocker?style=flat" alt="GitHub stars"/> </a>
    <a href="https://github.com/Kiya6955/IR-ISP-Blocker/releases/latest"> <img src="https://img.shields.io/github/release/Kiya6955/IR-ISP-Blocker.svg" alt="Latest release"/> </a>
    <a href="https://github.com/Kiya6955/IR-ISP-Blocker/actions/workflows/ci.yml"> <img src="https://github.com/Kiya6955/IR-ISP-Blocker/actions/workflows/ci.yml/badge.svg" alt="CI"/> </a>
    <a href="https://github.com/Kiya6955/IR-ISP-Blocker/actions/workflows/update-lists.yml"> <img src="https://github.com/Kiya6955/IR-ISP-Blocker/actions/workflows/update-lists.yml/badge.svg" alt="List update"/> </a>
</div>

Block (or allow only) the IP ranges of **Iranian ISPs, datacenters and the whole country** on a
server outside Iran — one layer of defence against the server being probed and flagged by the GFW.

Version 2 is a complete rewrite: nftables sets (or ipset), IPv4 + IPv6, atomic updates, SSH
lockout protection, rollback, automatic weekly list updates generated from RIPE data, and a
full interactive menu that covers every feature. A CLI is available for scripting.

## Quick start

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Kiya6955/IR-ISP-Blocker/main/ir-isp-blocker.sh)
```

This opens the interactive menu (same one-liner as v1). Everything can be done from the menu:
block, allow-only, unblock, status, whitelist, doctor, list updates (now or scheduled), rollback,
settings, export/import and install/uninstall. The first change you make installs the tool to
`/usr/local/bin/ir-isp-blocker` and enables restore-at-boot, so afterwards you can simply run
`ir-isp-blocker`. Lists refresh automatically every week (change it in the menu under *Update IP lists*).

For scripts and automation, the same features exist as commands:

```bash
ir-isp-blocker block --isp mci,mtn --ports 443,8443 --proto tcp   # block 2 operators on 2 ports
ir-isp-blocker block --isp all-ir --rollback-after 120             # whole country, with dead-man switch
ir-isp-blocker only  --isp tci --ports 2053                        # only TCI may reach port 2053
ir-isp-blocker block --isp tci --log-only                          # monitor first ...
ir-isp-blocker status                                              # ... and look at hit counters
ir-isp-blocker block --asn 12345 --ports 443 --for 24h             # any ASN, for 24 hours
ir-isp-blocker unblock --all
ir-isp-blocker --dry-run block --isp mci                           # print exact ruleset, change nothing
```

Explicit install (optional): `curl -fsSLo /tmp/irb.sh https://raw.githubusercontent.com/Kiya6955/IR-ISP-Blocker/main/ir-isp-blocker.sh && sudo bash /tmp/irb.sh install`

## Command reference

| Command | What it does |
|---|---|
| `block --isp ID[,ID]` | Block ISPs. Options: `--ports 443,8443,2000-3000\|all` (default `all`), `--proto tcp\|udp\|both`, `--direction in\|out\|both` (default `in`), `--drop` (default) / `--reject` / `--log-only` / `--rate-limit 30/minute`, `--raw`, `--for 24h`, `--replace`, `--whitelist IP[,CIDR]` |
| `only --isp ID --ports SPEC` | On these ports allow **only** the given ISPs; everyone else (Iranian or not) is blocked |
| `unblock --isp ID \| --rule N \| --all` | Remove an ISP from all rules, one rule, or everything |
| `status` | Rules, live backend, per-ISP **hit counters** |
| `list` | Available ISP ids, ASNs and prefix counts |
| `update [--auto daily\|weekly\|off]` | Download fresh lists (SHA-256 verified, last-known-good kept on failure) and re-apply; `--auto` installs a systemd timer (cron fallback) |
| `whitelist list\|add\|remove\|clear-auto ENTRY...` | IPs/CIDRs and ports that are never blocked |
| `rollback [--to ID] [--list]` | Restore an automatic backup (one is taken before every change) |
| `confirm` | Keep new rules and cancel a pending dead-man switch |
| `apply` / `restore` | Re-apply the saved config (`restore` = offline, used at boot) |
| `expire` | Drop time-limited rules that have expired (runs from a timer) |
| `settings [--ipv6 yes\|no] [--backend B] [--docker D] [--ssh-port N]` | Change saved settings and re-apply |
| `migrate [--isp ...]` | Import + remove the v1 `isp-blocker` iptables chain (runs automatically, see below) |
| `doctor` | Checks backend, kernel modules, SSH lockout risk, stale lists, conflicting firewalls, v1 leftovers |
| `export [FILE]` / `import FILE` | Configuration bundle (strictly validated on import) |
| `install` / `uninstall [--keep-config]` | Install to `/usr/local/bin` + boot unit / remove **everything** |

Global options: `--dry-run`, `-y/--yes`, `-q/--quiet`, `--no-color` (and `NO_COLOR`),
`--backend auto|nft|ipset|iptables`, `--ipv6 yes|no`, `--docker auto|yes|no`, `--ssh-port N`,
`--no-ssh-protect` (needs `--force` for all-ports rules), `--version`, `--help`.

ISP selection: `--isp` with ids from the table below, `--asn N[,M]` (fetched live from RIPEstat,
the holder name is printed), `--list-url https://... --name X` or `--list-file FILE --name X`
(custom lists: every non-comment line must be a valid IP/CIDR or the list is rejected).

## How it works

* **Backend auto-detection:** nftables if `nft` works (probed with a test ruleset), else
  iptables + ipset, else plain iptables (one rule per CIDR - slower, warned about). Install
  prerequisites with apt, dnf/yum, pacman, apk or zypper is offered when nothing is usable.
* **Isolation:** everything lives in one nft table `inet ir_isp_blocker`, or in `IRB-*` chains
  and `irb4-*`/`irb6-*` ipsets. Other rules are never touched. Whitelist hits use `accept` inside
  our own table / `RETURN` from our chains, so they **never open anything** in your other firewall.
* **Fast and small:** one set per ISP and family, one rule per (ISP set × rule) - not per CIDR
  and port. Lists are aggregated (nested/duplicate ranges removed).
* **Atomic:** nftables rules are replaced in one `nft -f` transaction (after `nft -c`);
  ipsets are filled under a temporary name and `swap`ped; chains are replaced with
  `iptables-restore --noflush`. There is never a moment without protection, and a failed apply
  leaves the previous rules in place. Config is only committed after a successful apply.
* **Direction semantics (`--direction`):** rules match `ct direction original`, i.e. *connections
  initiated by* the matched side. `in` (default) blocks connections from ISP addresses to this
  server, but replies to connections **your server** opens to Iranian IPs still work. `out` blocks
  connections this server opens to those networks. `both` does both.
* **`--raw`:** drops in the `prerouting` hook at raw priority, before conntrack - cheapest under
  floods, but conntrack direction is unknown there, so with `--ports all` it also drops replies to
  your own outbound connections to those networks. Only `drop`/`log-only` are allowed in raw mode.
* **Docker:** with Docker present (`--docker auto`), a forward hook is added (nft) or `IRB-FORWARD`
  is jumped to from `DOCKER-USER` (iptables). Published ports are matched on the **original,
  pre-DNAT port** (`ct original proto-dst` / `--ctorigdstport`), so `--ports 443` means the port
  clients connect to, not the container port.
* **ufw / firewalld:** coexist. They have their own chains/tables; a drop in any of them wins.
* **Persistence:** a systemd unit (`ir-isp-blocker.service`) runs `ir-isp-blocker restore` at boot
  after nftables/netfilter-persistent/firewalld/ufw and before Docker, using cached lists (no
  network needed). OpenRC init script or `rc.local` fallback otherwise. Independent of
  iptables-persistent.
* **Files:** `/etc/ir-isp-blocker/` → `config`, `rules.conf`, `whitelist.ips`, `whitelist.ports`,
  `custom.sources`, `lists/` (cache), `backups/` (last 10), `state/`. Config files are parsed as
  data (never `source`d) and validated field by field.

### Safety (anti-lockout)

* SSH ports are detected from `sshd_config` (+ `sshd_config.d`) and `ss`, and are always exempt
  from inbound rules. Rules that block all ports (or `only` mode) are refused if no SSH port can
  be found (`--ssh-port N` fixes that).
* The client IP of your current SSH session (`SSH_CONNECTION`) is auto-whitelisted (the last 5
  are remembered, `whitelist clear-auto` forgets them).
* `--rollback-after SEC` arms a dead-man switch (systemd-run timer, or a detached process): if you
  do not type `yes` (or run `ir-isp-blocker confirm`) in time, the previous state is restored.
  The interactive menu offers it for every all-ports/only change.
* `--dry-run` prints the exact nft ruleset / ipset + iptables-restore input.
* `flock` prevents concurrent runs. Blocklists may not contain prefixes wider than /8 (IPv4) or
  /16 (IPv6) - a poisoned list cannot blackhole the internet.

### Honest limits

This is **one** layer. It does not stop active probing from non-Iranian vantage points, the GFW
can use hosts abroad and other techniques (traffic analysis, SNI/TLS fingerprinting), IP data is
never perfect (prefixes get leased, moved or announced from elsewhere), and blocking an ISP also
blocks real users on it. Use it together with a well-configured proxy, not instead of one.

## IP lists / data pipeline

Lists are generated by [`tools/ipgen.py`](tools/ipgen.py) (Python 3 standard library only) from
[`data/isps.json`](data/isps.json), the single declarative ISP catalogue:

1. every ASN's holder name is checked against RIPEstat `as-overview` (`holder_regex`); a mismatch
   aborts the run - ASNs are never guessed,
2. prefixes come from RIPEstat `announced-prefixes`; `all-ir` comes from the RIPE NCC
   delegated-extended statistics (country `IR`),
3. bogons and over-wide prefixes are dropped, lists are aggregated with
   `ipaddress.collapse_addresses`, sorted, and written deterministically with a `SHA256SUMS`.

The [weekly workflow](.github/workflows/update-lists.yml) regenerates them and refuses to commit
if a list is empty, invalid, or shrinks by more than 50 %. Layout:

* `lists/<id>.v4`, `lists/<id>.v6` - one CIDR per line; `lists/index.tsv` (catalogue + counts),
  `lists/asns.tsv` (verified holder of every ASN), `lists/SHA256SUMS`.
* **Backward compatibility:** the v1 root files (`mci-ips.ipv4`, `mtn-ips.ipv4`, `tci-ips.ipv4`,
  `rightel-ips.ipv4`, `shatel-ips.ipv4`, `asiatech-ips.ipv4`, `pishgaman-ips.ipv4`,
  `mobinnet-ips.ipv4`, `parsan-ips.ipv4`) are kept and regenerated (IPv4, aggregated, identical to
  `lists/<id>.v4`) so already-deployed copies of the old script keep working.

## Supported ISPs

`ir-isp-blocker list` shows the live prefix counts. All ASNs verified against RIPEstat on
2026-10-31; see `lists/asns.tsv` for each holder name.

| id | ISP | Category | ASNs |
|---|---|---|---|
| `mci` | Hamrah-e Aval (MCI) | mobile | AS197207, AS43358 |
| `mtn` | Irancell (MTN) | mobile | AS44244 |
| `rightel` | Rightel | mobile | AS57218, AS62140 |
| `tci` | Mokhaberat (TCI) | fixed | AS58224, AS51119, AS51828, AS59587, AS58085, AS59628 |
| `shatel` | Shatel | fixed | AS31549, AS34369 |
| `asiatech` | Asiatech | fixed | AS43754, AS34636, AS41689, AS51433, AS57391, AS203000, AS60077 |
| `pishgaman` | Pishgaman | fixed | AS49100, AS3263, AS34918, AS57755, AS57831, AS56660, AS58216, AS59481 |
| `mobinnet` | MobinNet | fixed | AS50810, AS47330 |
| `parsonline` | ParsOnline (Parsan Lin) — v1 file `parsan-ips.ipv4` | fixed | AS16322, AS60976, AS61061 |
| `hiweb` | HiWEB (Dadeh Gostar Asr Novin) | fixed | AS56402 |
| `sepanta` | Sepanta | fixed | AS39074 |
| `afranet` | Afranet | fixed | AS25184 |
| `respina` | Respina | fixed | AS42337 |
| `mabna` | Mabna Telecom (Gostaresh Ertebatat Mabna) | fixed | AS51074, AS59442 |
| `ask` | Andisheh Sabz Khazar | fixed | AS39308 |
| `sabanet` | Sabanet (Soroush Rasaneh) | fixed | AS21341 |
| `fanap` | FANAP Telecom | fixed | AS24631, AS43343, AS203558, AS206065, AS44966 |
| `fanava` | Fanava | fixed | AS41881, AS61036, AS39164, AS62442 |
| `datak` | Datak | fixed | AS25124, AS43245 |
| `nedagostar` | Neda Gostar Saba (Parvaresh Dadeha) | fixed | AS39501, AS59703 |
| `tic` | TIC (Telecommunication Infrastructure Co., incl. IXP) | infrastructure | AS48159, AS49666, AS50722, AS50992 |
| `dci` | DCI (Iran Information Technology Co.) | infrastructure | AS12880 |
| `ipm` | IPM / IRANET (research network) | research | AS6736, AS34837 |
| `arvancloud` | ArvanCloud (Iran) | datacenter | AS202468, AS205585 |
| `hostiran` | HostIran | datacenter | AS59441 |
| `netmihan` | Netmihan (Mihan Webhost) | datacenter | AS204213 |
| `all-ir` | **All Iran** (RIPE delegated, country IR) | country | – |

Missing a network? Use `--asn N` right away, and open an issue/PR adding it to `data/isps.json`.

## Upgrading from v1

Run the same one-liner as before. v2 replaces v1 completely: if the old `isp-blocker` iptables chain
is still live, the next command (or opening the menu) reads its blocked ports and whitelisted
IPs/ports, infers the ISPs, creates the equivalent v2 rule and removes the old chain, including its
lines in `/etc/iptables/rules.v4` (a backup is kept), so you never end up with two stacks. If the
ISPs cannot be inferred, run `ir-isp-blocker migrate --isp mci,mtn` (or use *Settings > Import old
v1 rules* in the menu).

## FAQ / troubleshooting

* **I locked myself out.** Use your provider's console and run `ir-isp-blocker rollback` or
  `ir-isp-blocker unblock --all`. Next time use `--rollback-after 120`.
* **Rules are gone after `systemctl reload nftables`.** Debian's `/etc/nftables.conf` starts with
  `flush ruleset`. Run `ir-isp-blocker apply` afterwards (boot order is handled). `doctor` warns.
* **iptables-persistent fails at boot after `netfilter-persistent save`.** The saved file then
  references our ipsets. Remove the `IRB-*`/`irb*` lines from `/etc/iptables/rules.v*` - we restore
  ourselves. `doctor` detects this.
* **OpenVZ / LXC:** nftables or ipset may be unavailable; the plain-iptables fallback is used and
  `doctor` explains. Some containers cannot filter at all - ask your provider.
* **Docker published ports still reachable?** Check `doctor` reports Docker, or force `--docker yes`.
* **Where do the hit counters come from?** nft rule counters / iptables rule counters; they reset
  when the rules are re-applied (e.g. weekly update).

## Development

`bash tests/run_tests.sh` (dry-run assertions + real apply/rollback paths against a fake `nft`),
`python3 -m unittest discover -s tests` (generator), `sudo unshare --net bash tests/integration_netns.sh`
(real nftables/ipset/iptables in a throwaway network namespace, run by CI). See
[CONTRIBUTING.md](CONTRIBUTING.md).

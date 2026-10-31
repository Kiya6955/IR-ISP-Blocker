#!/usr/bin/env python3
"""IR-ISP-Blocker list generator (Python 3.8+, standard library only).

Builds per-ISP CIDR lists from authoritative data:
  * RIPEstat ``as-overview``        - verifies every ASN's holder name
  * RIPEstat ``announced-prefixes`` - prefixes actually originated by each ASN
  * RIPE NCC delegated-extended     - country-level "all Iran" registration data

Everything fetched from the network is treated as untrusted *data*: every prefix is
parsed with :mod:`ipaddress`, bogons/absurdly short prefixes are dropped, and lists
are aggregated with ``ipaddress.collapse_addresses`` so nested/duplicate ranges
disappear. Output is sorted and byte-for-byte deterministic.

Sub-commands
  generate   fetch + build lists into an output directory (atomic replace)
  validate   sanity-check a lists directory (syntax, canonical form, shrink guard)
"""
from __future__ import annotations

import argparse
import hashlib
import ipaddress
import json
import os
import re
import shutil
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from typing import Dict, Iterable, List, Optional, Tuple

RIPESTAT = "https://stat.ripe.net/data/{call}/data.json?{query}"
DELEGATED = "https://ftp.ripe.net/pub/stats/ripencc/delegated-ripencc-extended-latest"
SOURCEAPP = "ir-isp-blocker"
UA = "ir-isp-blocker-listgen/2 (+https://github.com/Kiya6955/IR-ISP-Blocker)"
ID_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,23}$")
MIN_PREFIXLEN = {4: 8, 6: 16}  # anything shorter is treated as a leak/hijack, not data

Net = ipaddress._BaseNetwork  # type: ignore[attr-defined]


def log(msg: str) -> None:
    print(msg, file=sys.stderr, flush=True)


def http_get(url: str, retries: int = 4, timeout: int = 60) -> bytes:
    last: Optional[Exception] = None
    for attempt in range(retries):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": UA})
            with urllib.request.urlopen(req, timeout=timeout) as r:  # noqa: S310 (https only)
                return r.read()
        except (urllib.error.URLError, TimeoutError, ConnectionError) as e:
            last = e
            time.sleep(2 ** attempt)
    raise RuntimeError(f"GET {url} failed after {retries} attempts: {last}")


def ripestat(call: str, **params: str) -> dict:
    params["sourceapp"] = SOURCEAPP
    url = RIPESTAT.format(call=call, query=urllib.parse.urlencode(params))
    doc = json.loads(http_get(url).decode("utf-8"))
    if not isinstance(doc, dict) or doc.get("status") != "ok" or not isinstance(doc.get("data"), dict):
        raise RuntimeError(f"RIPEstat {call} {params}: unexpected response status {doc.get('status')!r}")
    return doc["data"]


def parse_prefix(text: str) -> Optional[Net]:
    """Return a canonical network or None if the text is not an acceptable public prefix."""
    try:
        net = ipaddress.ip_network(str(text).strip(), strict=False)
    except ValueError:
        return None
    if net.prefixlen < MIN_PREFIXLEN[net.version]:
        return None
    if not net.is_global or net.is_multicast:
        return None
    return net


def collapse(nets: Iterable[Net]) -> Dict[int, List[Net]]:
    out: Dict[int, List[Net]] = {4: [], 6: []}
    by_v: Dict[int, List[Net]] = {4: [], 6: []}
    for n in nets:
        by_v[n.version].append(n)
    for v in (4, 6):
        out[v] = sorted(ipaddress.collapse_addresses(by_v[v]),
                        key=lambda n: (int(n.network_address), n.prefixlen))
    return out


# ---------------------------------------------------------------- data sources
def asn_holder(asn: int) -> str:
    data = ripestat("as-overview", resource=f"AS{asn}")
    return str(data.get("holder") or "")


def asn_prefixes(asn: int) -> List[Net]:
    data = ripestat("announced-prefixes", resource=f"AS{asn}")
    nets = []
    for item in data.get("prefixes", []) or []:
        p = parse_prefix(item.get("prefix", "") if isinstance(item, dict) else "")
        if p is not None:
            nets.append(p)
    return nets


def delegated_country(cc: str, blob: Optional[bytes] = None) -> List[Net]:
    if blob is None:
        blob = http_get(DELEGATED, timeout=180)
    nets: List[Net] = []
    for raw in blob.decode("ascii", "replace").splitlines():
        f = raw.split("|")
        if len(f) < 7 or f[1] != cc or f[6] not in ("allocated", "assigned"):
            continue
        try:
            if f[2] == "ipv4":
                start = ipaddress.IPv4Address(f[3])
                end = ipaddress.IPv4Address(int(start) + int(f[4]) - 1)
                cand = list(ipaddress.summarize_address_range(start, end))
            elif f[2] == "ipv6":
                cand = [ipaddress.IPv6Network(f"{f[3]}/{int(f[4])}", strict=False)]
            else:
                continue
        except (ValueError, ipaddress.AddressValueError):
            continue
        for n in cand:
            p = parse_prefix(str(n))
            if p is not None:
                nets.append(p)
    return nets


# ---------------------------------------------------------------- outputs
def write_list(path: str, nets: List[Net]) -> None:
    with open(path, "w", encoding="ascii", newline="\n") as fh:
        for n in nets:
            fh.write(f"{n}\n")


def sha256(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def load_catalog(path: str) -> dict:
    with open(path, encoding="utf-8") as fh:
        cat = json.load(fh)
    seen = set()
    for e in cat.get("isps", []) + cat.get("aggregates", []):
        if not ID_RE.match(e["id"]) or e["id"] in seen:
            raise SystemExit(f"catalog: invalid or duplicate id {e['id']!r}")
        seen.add(e["id"])
        for k in ("name_en", "category"):
            if not e.get(k) or any(c in e[k] for c in "\t\n\r"):
                raise SystemExit(f"catalog: {e['id']}: bad {k}")
    return cat


def read_previous_date(index_path: str) -> Tuple[Optional[str], Optional[str]]:
    """Return (generated-date, body-without-date) of an existing index.tsv."""
    if not os.path.exists(index_path):
        return None, None
    with open(index_path, encoding="utf-8") as fh:
        lines = fh.read().splitlines(True)
    date = None
    body = []
    for ln in lines:
        if ln.startswith("# generated="):
            date = ln.strip().split("=", 1)[1]
        else:
            body.append(ln)
    return date, "".join(body)


def cmd_generate(a: argparse.Namespace) -> int:
    cat = load_catalog(a.catalog)
    errors: List[str] = []
    results: Dict[str, Dict[int, List[Net]]] = {}
    asn_rows: List[str] = []

    for isp in cat["isps"]:
        rx = re.compile(isp["holder_regex"], re.I)
        nets: List[Net] = []
        for asn in isp["asns"]:
            holder = asn_holder(asn)
            if not rx.search(holder):
                errors.append(f"{isp['id']}: AS{asn} holder {holder!r} does not match /{isp['holder_regex']}/")
                continue
            pfx = asn_prefixes(asn)
            if not pfx:
                log(f"warn: {isp['id']}: AS{asn} ({holder}) announces no prefixes right now")
            c = collapse(pfx)
            asn_rows.append(f"AS{asn}\t{isp['id']}\t{holder.replace(chr(9), ' ')}\t{len(c[4])}\t{len(c[6])}\n")
            nets.extend(pfx)
            log(f"ok:   {isp['id']:<12} AS{asn:<7} {holder}  v4={len(c[4])} v6={len(c[6])}")
        results[isp["id"]] = collapse(nets)

    delegated_blob = None
    for agg in cat.get("aggregates", []):
        if agg.get("source") != "ripe-delegated":
            errors.append(f"{agg['id']}: unknown aggregate source")
            continue
        if delegated_blob is None:
            delegated_blob = http_get(DELEGATED, timeout=180)
        results[agg["id"]] = collapse(delegated_country(agg["country"], delegated_blob))
        log(f"ok:   {agg['id']:<12} delegated {agg['country']}  v4={len(results[agg['id']][4])} v6={len(results[agg['id']][6])}")

    if errors:
        for e in errors:
            log(f"ERROR: {e}")
        log("refusing to write lists: fix data/isps.json (never guess ASNs)")
        return 2

    os.makedirs(a.out, exist_ok=True)
    tmp = tempfile.mkdtemp(prefix=".ipgen-", dir=os.path.dirname(os.path.abspath(a.out)))
    try:
        index_rows = []
        for e in cat["isps"] + cat.get("aggregates", []):
            r = results[e["id"]]
            write_list(os.path.join(tmp, f"{e['id']}.v4"), r[4])
            write_list(os.path.join(tmp, f"{e['id']}.v6"), r[6])
            asns = ",".join(str(x) for x in e.get("asns", [])) or "-"
            index_rows.append("\t".join([e["id"], e["category"], e["name_en"], asns,
                                         str(len(r[4])), str(len(r[6]))]) + "\n")
        body = "#id\tcategory\tname_en\tasns\tv4\tv6\n" + "".join(index_rows)
        prev_date, prev_body = read_previous_date(os.path.join(a.out, "index.tsv"))
        date = prev_date if (prev_body == body and prev_date) else time.strftime("%Y-%m-%d", time.gmtime())
        with open(os.path.join(tmp, "index.tsv"), "w", encoding="utf-8", newline="\n") as fh:
            fh.write(f"# generated={date}\n{body}")
        with open(os.path.join(tmp, "asns.tsv"), "w", encoding="utf-8", newline="\n") as fh:
            fh.write("#asn\tisp\tholder (RIPEstat as-overview)\tv4\tv6\n" + "".join(sorted(asn_rows)))
        names = sorted(f for f in os.listdir(tmp))
        with open(os.path.join(tmp, "SHA256SUMS"), "w", encoding="ascii", newline="\n") as fh:
            for n in names:
                fh.write(f"{sha256(os.path.join(tmp, n))}  {n}\n")
        # replace managed files atomically-ish (per file rename), drop stale ones
        for old in os.listdir(a.out):
            if re.match(r"^[a-z0-9-]+\.v[46]$", old) and old not in names:
                os.remove(os.path.join(a.out, old))
        for n in names + ["SHA256SUMS"]:
            os.replace(os.path.join(tmp, n), os.path.join(a.out, n))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    if a.legacy_root:
        for e in cat["isps"]:
            if e.get("legacy_file"):
                write_list(os.path.join(a.legacy_root, e["legacy_file"]), results[e["id"]][4])
    log(f"wrote {len(results)} lists to {a.out}")
    return 0


# ---------------------------------------------------------------- validation
def read_list(path: str) -> Tuple[List[Net], List[str]]:
    nets, problems = [], []
    with open(path, encoding="ascii", errors="replace", newline="") as fh:
        for i, ln in enumerate(fh, 1):
            if "\r" in ln:
                problems.append(f"{path}:{i}: CR line ending")
            s = ln.strip()
            try:
                n = ipaddress.ip_network(s, strict=True)
            except ValueError:
                problems.append(f"{path}:{i}: not a canonical CIDR: {s[:60]!r}")
                continue
            if str(n) != s:
                problems.append(f"{path}:{i}: non-canonical form {s!r} (expected {n})")
            nets.append(n)
    return nets, problems


def cmd_validate(a: argparse.Namespace) -> int:
    problems: List[str] = []
    files = sorted(f for f in os.listdir(a.lists) if re.match(r"^[a-z0-9-]+\.v[46]$", f))
    if not files:
        problems.append("no list files found")
    for f in files:
        want_v = 4 if f.endswith(".v4") else 6
        nets, p = read_list(os.path.join(a.lists, f))
        problems += p
        if any(n.version != want_v for n in nets):
            problems.append(f"{f}: wrong address family entries")
        if want_v == 4 and not nets:
            problems.append(f"{f}: empty IPv4 list")
        if nets and [str(n) for n in collapse(nets)[want_v]] != [str(n) for n in nets]:
            problems.append(f"{f}: not sorted/aggregated (overlaps or duplicates)")
        if a.previous:
            prev = os.path.join(a.previous, f)
            if os.path.exists(prev):
                old, _ = read_list(prev)
                old_n = sum(n.num_addresses for n in old)
                new_n = sum(n.num_addresses for n in nets)
                if old_n and new_n < old_n * (1 - a.max_shrink):
                    problems.append(f"{f}: address space shrank {old_n} -> {new_n} (> {int(a.max_shrink*100)}%)")
    sums = os.path.join(a.lists, "SHA256SUMS")
    if os.path.exists(sums):
        with open(sums, encoding="ascii") as fh:
            for ln in fh:
                h, _, name = ln.strip().partition("  ")
                path = os.path.join(a.lists, name)
                if not os.path.exists(path) or sha256(path) != h:
                    problems.append(f"SHA256SUMS mismatch for {name}")
    else:
        problems.append("SHA256SUMS missing")
    if a.catalog and a.legacy_root:
        for e in load_catalog(a.catalog)["isps"]:
            if not e.get("legacy_file"):
                continue
            legacy = os.path.join(a.legacy_root, e["legacy_file"])
            new = os.path.join(a.lists, f"{e['id']}.v4")
            if not os.path.exists(legacy):
                problems.append(f"legacy file {e['legacy_file']} missing (v1 clients still download it)")
            elif os.path.exists(new) and open(legacy, "rb").read() != open(new, "rb").read():
                problems.append(f"legacy file {e['legacy_file']} differs from lists/{e['id']}.v4")
    for p in problems:
        log(f"FAIL: {p}")
    log(f"validated {len(files)} files: {'OK' if not problems else str(len(problems)) + ' problem(s)'}")
    return 1 if problems else 0


def main(argv: Optional[List[str]] = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    g = sub.add_parser("generate", help="fetch data and build lists")
    g.add_argument("--catalog", default="data/isps.json")
    g.add_argument("--out", default="lists")
    g.add_argument("--legacy-root", default=".", help="where to write v1 root-level *-ips.ipv4 files ('' to skip)")
    g.set_defaults(fn=cmd_generate)
    v = sub.add_parser("validate", help="sanity-check a lists directory")
    v.add_argument("--lists", default="lists")
    v.add_argument("--previous", help="directory with the previous lists for the shrink guard")
    v.add_argument("--max-shrink", type=float, default=0.5)
    v.add_argument("--catalog", default="data/isps.json", help="also check v1 root-level legacy files ('' to skip)")
    v.add_argument("--legacy-root", default=".")
    v.set_defaults(fn=cmd_validate)
    a = ap.parse_args(argv)
    return a.fn(a)


if __name__ == "__main__":
    sys.exit(main())

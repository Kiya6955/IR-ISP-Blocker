# Contributing

* **Adding/fixing an ISP:** edit `data/isps.json` only (id, names, category, ASNs and a
  `holder_regex` that matches the RIPEstat `as-overview` holder of *every* ASN). Verify each ASN
  at `https://stat.ripe.net/AS<number>` — never add an ASN from memory. Then run
  `python3 tools/ipgen.py generate && python3 tools/ipgen.py validate`. Lists are regenerated
  weekly by CI, so list files in PRs are optional.
* **Script changes:** keep `ir-isp-blocker.sh` a single self-contained bash file (it must work via
  `bash <(curl ...)`), `shellcheck`-clean, with all input validated. Run:
  ```bash
  shellcheck ir-isp-blocker.sh tests/*.sh
  bash tests/run_tests.sh
  python3 -m unittest discover -s tests
  sudo unshare --net bash tests/integration_netns.sh   # optional, real firewall in a netns
  ```
* Never test firewall changes on a host you cannot reach through a console.

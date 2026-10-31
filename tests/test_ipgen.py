"""Offline unit tests for tools/ipgen.py (python3 -m unittest discover -s tests)."""
import argparse
import ipaddress
import os
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "tools"))
import ipgen  # noqa: E402

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))


class ParseTests(unittest.TestCase):
    def test_rejects_garbage_and_bogons(self):
        for bad in ["<html>", "1.2.3", "10.0.0.0/8", "192.168.1.0/24", "0.0.0.0/0", "1.0.0.0/7",
                    "::/0", "2001:db8::/32", "fe80::/10", "224.0.0.0/4", "$(reboot)"]:
            self.assertIsNone(ipgen.parse_prefix(bad), bad)

    def test_accepts_and_canonicalises(self):
        self.assertEqual(str(ipgen.parse_prefix("5.22.0.1/16")), "5.22.0.0/16")
        self.assertEqual(str(ipgen.parse_prefix("2a01:5ec0::/29")), "2a01:5ec0::/29")

    def test_collapse_removes_nested_and_duplicates(self):
        nets = [ipaddress.ip_network(x) for x in
                ["5.22.0.0/20", "5.22.0.0/18", "5.22.0.0/17", "5.22.16.0/20", "5.22.0.0/17", "2a01:5ec0::/32", "2a01:5ec0:1::/48"]]
        out = ipgen.collapse(nets)
        self.assertEqual([str(n) for n in out[4]], ["5.22.0.0/17"])
        self.assertEqual([str(n) for n in out[6]], ["2a01:5ec0::/32"])

    def test_delegated_parser(self):
        blob = (b"2|ripencc|20261031|1|19830705|20261030|+0100\n"
                b"ripencc|IR|ipv4|2.144.0.0|262144|20100901|allocated|x\n"
                b"ripencc|IR|ipv4|5.52.0.0|768|20120101|assigned|x\n"     # not a power of two -> 2 prefixes
                b"ripencc|DE|ipv4|1.2.3.0|256|20100901|allocated|x\n"
                b"ripencc|IR|ipv6|2a01:5ec0::|29|20100901|allocated|x\n"
                b"ripencc|IR|ipv4|9.9.9.0|256|20100901|available|x\n")
        nets = sorted(str(n) for n in ipgen.delegated_country("IR", blob))
        self.assertEqual(nets, ["2.144.0.0/14", "2a01:5ec0::/29", "5.52.0.0/23", "5.52.2.0/24"])


class ValidateTests(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.mkdtemp()
        self.prev = tempfile.mkdtemp()

    def tearDown(self):
        shutil.rmtree(self.d, ignore_errors=True)
        shutil.rmtree(self.prev, ignore_errors=True)

    def _write(self, d, name, lines):
        with open(os.path.join(d, name), "w", newline="\n") as fh:
            fh.write("".join(f"{x}\n" for x in lines))

    def _sums(self, d):
        with open(os.path.join(d, "SHA256SUMS"), "w", newline="\n") as fh:
            for n in sorted(os.listdir(d)):
                if n != "SHA256SUMS":
                    fh.write(f"{ipgen.sha256(os.path.join(d, n))}  {n}\n")

    def _validate(self, previous=None):
        a = argparse.Namespace(lists=self.d, previous=previous, max_shrink=0.5, catalog="", legacy_root="")
        return ipgen.cmd_validate(a)

    def test_good(self):
        self._write(self.d, "x.v4", ["1.0.0.0/24", "2.0.0.0/16"])
        self._write(self.d, "x.v6", [])
        self._sums(self.d)
        self.assertEqual(self._validate(), 0)

    def test_overlap_and_garbage_detected(self):
        self._write(self.d, "x.v4", ["1.0.0.0/16", "1.0.1.0/24"])
        self._write(self.d, "y.v4", ["<!DOCTYPE html>"])
        self._sums(self.d)
        self.assertEqual(self._validate(), 1)

    def test_empty_v4_detected(self):
        self._write(self.d, "x.v4", [])
        self._sums(self.d)
        self.assertEqual(self._validate(), 1)

    def test_shrink_guard(self):
        self._write(self.prev, "x.v4", ["1.0.0.0/16"])
        self._write(self.d, "x.v4", ["1.0.0.0/24"])
        self._sums(self.d)
        self.assertEqual(self._validate(previous=self.prev), 1)

    def test_checksum_mismatch(self):
        self._write(self.d, "x.v4", ["1.0.0.0/24"])
        self._sums(self.d)
        self._write(self.d, "x.v4", ["1.0.0.0/23"])
        self.assertEqual(self._validate(), 1)


class RepoTests(unittest.TestCase):
    def test_published_lists_are_valid(self):
        a = argparse.Namespace(lists=os.path.join(ROOT, "lists"), previous=None, max_shrink=0.5,
                               catalog=os.path.join(ROOT, "data", "isps.json"), legacy_root=ROOT)
        self.assertEqual(ipgen.cmd_validate(a), 0)

    def test_catalog_ids_have_lists(self):
        cat = ipgen.load_catalog(os.path.join(ROOT, "data", "isps.json"))
        for e in cat["isps"] + cat["aggregates"]:
            for fam in ("v4", "v6"):
                self.assertTrue(os.path.exists(os.path.join(ROOT, "lists", f"{e['id']}.{fam}")), e["id"])


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3
"""Offline safety checks; never invoke nft or alter host networking."""

import copy
import ipaddress
import json
import shlex
import signal
import subprocess
import unittest
from unittest import mock

import kubernetes_scratch_node_fault_driver as driver


def pin_document():
    return {
        "authorization": "scratch-only-node-network-partition",
        "server_number": 4000001,
        "node_name": "symphony-node-fault-test",
        "node_uid": "10000000-0000-4000-8000-000000000001",
        "machine_id": "a" * 32,
        "boot_id": "20000000-0000-4000-8000-000000000002",
        "namespace": "symphony-node-fault-test",
        "namespace_uid": "30000000-0000-4000-8000-000000000003",
        "management_ipv4": "192.0.2.10",
        "management_ssh_port": 22,
        "cluster_cidrs": ["10.42.0.0/16", "fd42::/64"],
        "max_hold_seconds": 120,
        "expires_at_unix": 1100,
    }


class NftKernel:
    """Lifecycle double, not an nft syntax validator; real netns smoke is required."""

    def __init__(self):
        self.tables = {}
        self.rules = {}
        self.next_handle = 1
        self.after_commit = None

    def run(self, argv, **kwargs):
        if kwargs.get("shell") or not 0 < kwargs["timeout"] <= 5:
            raise AssertionError("nft must be shell-free and bounded")
        if argv[1:] == ["--json", "--handle", "list", "tables"]:
            # nft 1.0.6 does not include table comments in JSON.
            objects = [{"table": {k: v for k, v in t.items() if k != "comment"}} for t in self.tables.values()]
            stdout = json.dumps({"nftables": objects})
        elif argv[1:4] == ["--handle", "list", "table"]:
            table = self.tables[argv[5]]
            stdout = 'table inet %s { # handle %d\n\tcomment "%s"\n}\n' % (table["name"], table["handle"], table["comment"])
        elif argv[1:] == ["--file", "-"]:
            commands = [shlex.split(line) for line in kwargs["input"].splitlines()]
            tables, rules = copy.deepcopy((self.tables, self.rules))
            for tokens in commands:
                if tokens[:3] == ["create", "table", "inet"]:
                    name = tokens[3]
                    if name in tables:
                        return subprocess.CompletedProcess(argv, 1, "", "File exists")
                    tables[name] = dict(name=name, family="inet", handle=self.next_handle, comment=tokens[6].rstrip(";"))
                    rules[name] = []
                    self.next_handle += 1
                elif tokens[:3] == ["add", "rule", "inet"]:
                    rules[tokens[3]].append((tokens[4], tokens[5:]))
                elif tokens[:3] == ["add", "chain", "inet"]:
                    pass
                elif tokens[:4] == ["delete", "table", "inet", "handle"]:
                    names = [n for n, t in tables.items() if t["handle"] == int(tokens[4])]
                    if len(names) != 1:
                        return subprocess.CompletedProcess(argv, 1, "", "No such file")
                    del tables[names[0]]
                    del rules[names[0]]
                else:
                    raise AssertionError(tokens)
            self.tables, self.rules = tables, rules
            if self.after_commit and commands[0][0] == "create":
                self.after_commit()
            stdout = ""
        else:
            raise AssertionError(argv)
        return subprocess.CompletedProcess(argv, 0, stdout, "")

    def verdict(self, name, chain, source, destination, protocol="tcp", sport=40000, dport=443):
        packet = {"saddr": source, "daddr": destination, "sport": str(sport), "dport": str(dport), "state": "established"}
        family = "ip" if ipaddress.ip_address(source).version == 4 else "ip6"
        for rule_chain, tokens in self.rules[name]:
            if rule_chain != chain:
                continue
            if tokens[-1] not in ("accept", "drop") or (len(tokens) - 1) % 3:
                raise AssertionError(tokens)
            for offset in range(0, len(tokens) - 1, 3):
                proto, field, value = tokens[offset:offset + 3]
                actual = packet[field]
                if proto not in (protocol, family, "ct"):
                    break
                matches = ipaddress.ip_address(actual) in ipaddress.ip_network(value) if "/" in value else actual == value
                if not matches:
                    break
            else:
                return tokens[-1]
        return "accept"


class NodeFaultSafetyTest(unittest.TestCase):
    def setUp(self):
        self.pin = pin_document()
        self.kernel = NftKernel()
        self.run_patch = mock.patch.object(driver.subprocess, "run", self.kernel.run)
        self.run_patch.start()
        self.addCleanup(self.run_patch.stop)
        self.clock_patch = mock.patch.object(driver.time, "time", return_value=1000)
        self.clock_patch.start()
        self.addCleanup(self.clock_patch.stop)

    def test_protected_pin_and_actual_host_are_refused(self):
        for field, value in (("server_number", 3071011), ("machine_id", "91d53397210e4abeae824abe6c6032a7")):
            with self.subTest(field=field):
                pin = dict(self.pin, **{field: value})
                with self.assertRaises(driver.DriverError):
                    driver.validate_pin_document(pin)
        files = {
            "/etc/machine-id": "91d53397210e4abeae824abe6c6032a7",
            "/proc/sys/kernel/random/boot_id": self.pin["boot_id"],
            "/etc/symphony-node-fault-server-id": str(self.pin["server_number"]),
        }
        with mock.patch.object(driver.os, "geteuid", return_value=0), mock.patch.object(driver, "read_identity", side_effect=files.__getitem__), mock.patch.object(driver.socket, "gethostname", return_value=self.pin["node_name"]):
            with self.assertRaises(driver.DriverError):
                driver.verify_host(self.pin)
        self.assertEqual(self.kernel.tables, {})

    def test_broad_noncanonical_and_unsafe_cidrs_are_refused(self):
        for cidr in ("0.0.0.0/0", "::/0", "0.0.0.0/1", "::/1", "224.0.0.0/4", "ff00::/8", "127.0.0.0/8", "::1/128", "169.254.0.0/16", "fe80::/10", "10.42.0.1/16", "10.42.0.0/255.255.0.0", "10.42.0.0/16; drop", "bad"):
            with self.subTest(cidr=cidr), self.assertRaises(driver.DriverError):
                driver.validate_pin_document(dict(self.pin, cluster_cidrs=[cidr]))
        for cidrs in ([], "10.42.0.0/16", [False]):
            with self.subTest(cidrs=cidrs), self.assertRaises(driver.DriverError):
                driver.validate_pin_document(dict(self.pin, cluster_cidrs=cidrs))

    def test_expiry_blocks_apply_and_check_but_not_owned_restore(self):
        expired = dict(self.pin, expires_at_unix=999)
        driver.apply_partition(self.pin)
        def load_expired(_path, restoring=False):
            return driver.validate_pin_document(expired, restoring=restoring)

        with mock.patch.object(driver, "load_pin", side_effect=load_expired), mock.patch.object(driver, "verify_host"), mock.patch.object(driver, "_emit"), mock.patch.object(driver.sys, "stderr"):
            self.assertEqual(driver.main(["--pin", "/private/pin.json", "--duration-seconds", "1"]), 2)
            self.assertEqual(driver.main(["--pin", "/private/pin.json", "--duration-seconds", "1", "--check"]), 2)
            self.assertEqual(driver.main(["--pin", "/private/pin.json", "--restore"]), 0)
        self.assertEqual(self.kernel.tables, {})
        with self.assertRaises(driver.DriverError):
            driver.validate_pin_document(dict(self.pin, expires_at_unix=1301))

    def test_unknown_schema_and_boolean_integer_are_refused(self):
        for pin in (dict(self.pin, server_number=True), dict(self.pin, max_hold_seconds=121), dict(self.pin, management_ssh_port=2222), dict(self.pin, extra="no")):
            with self.subTest(pin=pin), self.assertRaises(driver.DriverError):
                driver.validate_pin_document(pin)

    def test_existing_table_never_replaced_and_wrong_owner_never_deleted(self):
        driver.apply_partition(self.pin)
        name = driver.table_name(self.pin)
        self.kernel.tables[name]["comment"] = "someone else's table"
        before = copy.deepcopy(self.kernel.tables)
        with self.assertRaises(driver.DriverError):
            driver.apply_partition(self.pin)
        with self.assertRaises(driver.DriverError):
            driver.restore_partition(self.pin)
        self.assertEqual(self.kernel.tables, before)
        del self.kernel.tables[name]
        driver.restore_partition(self.pin)
        self.assertEqual(self.kernel.tables, {})

    def test_replacement_between_ownership_check_and_delete_is_not_deleted(self):
        driver.apply_partition(self.pin)
        name = driver.table_name(self.pin)

        def replace_before_delete(argv, **kwargs):
            if (kwargs.get("input") or "").startswith("delete "):
                self.kernel.tables[name]["handle"] = 999
                self.kernel.tables[name]["comment"] = "replacement owner"
            return self.kernel.run(argv, **kwargs)

        with mock.patch.object(driver.subprocess, "run", side_effect=replace_before_delete):
            with self.assertRaises(driver.DriverError):
                driver.restore_partition(self.pin)
        self.assertEqual(self.kernel.tables[name]["comment"], "replacement owner")

    def test_changed_handle_between_json_and_native_observations_is_refused(self):
        driver.apply_partition(self.pin)
        name = driver.table_name(self.pin)

        def replace_before_native_read(argv, **kwargs):
            if argv[1:4] == ["--handle", "list", "table"]:
                self.kernel.tables[name]["handle"] = 999
            return self.kernel.run(argv, **kwargs)

        with mock.patch.object(driver.subprocess, "run", side_effect=replace_before_native_read):
            with self.assertRaises(driver.DriverError):
                driver.restore_partition(self.pin)
        self.assertEqual(self.kernel.tables[name]["handle"], 999)

    def test_management_exception_does_not_allow_established_cluster_traffic(self):
        # Put management inside the cluster range to prove precedence, not just
        # that unrelated public traffic misses every DROP rule.
        pin = dict(self.pin, management_ipv4="10.42.0.10")
        driver.apply_partition(pin)
        name = driver.table_name(pin)
        cases = [
            ("input", "10.42.0.10", "10.42.0.20", "tcp", 40000, 22, "accept"),
            ("output", "10.42.0.20", "10.42.0.10", "tcp", 22, 40000, "accept"),
            ("input", "10.42.0.11", "10.42.0.20", "tcp", 40000, 22, "drop"),
            ("input", "10.42.0.10", "10.42.0.20", "tcp", 40000, 443, "drop"),
            ("output", "10.42.0.20", "10.42.0.10", "tcp", 40000, 22, "drop"),
            ("input", "10.42.0.10", "10.42.0.20", "udp", 40000, 22, "drop"),
            ("forward", "10.42.0.10", "10.42.0.20", "tcp", 40000, 22, "drop"),
            ("forward", "192.0.2.11", "10.42.0.20", "tcp", 40000, 443, "drop"),
            ("output", "fd42::20", "2001:db8::1", "tcp", 40000, 443, "drop"),
            ("input", "2001:db8::1", "fd42::20", "tcp", 40000, 443, "drop"),
            ("output", "192.0.2.20", "198.51.100.1", "tcp", 40000, 443, "accept"),
        ]
        for chain, src, dst, protocol, sport, dport, want in cases:
            with self.subTest(chain=chain, src=src, dst=dst, dport=dport):
                self.assertEqual(self.kernel.verdict(name, chain, src, dst, protocol, sport, dport), want)

    def test_deadline_and_signal_during_commit_restore(self):
        for signum in (None, signal.SIGTERM, signal.SIGINT):
            with self.subTest(signal=signum):
                if signum:
                    self.kernel.after_commit = lambda: signal.getsignal(signum)(signum, None)
                else:
                    self.kernel.after_commit = None
                with mock.patch.object(driver.time, "monotonic", side_effect=[10, 12, 12, 12, 12, 12]), mock.patch.object(driver, "_emit"):
                    reason = driver.hold_partition(self.pin, 1)
                self.assertEqual(reason, signal.Signals(signum).name if signum else "deadline")
                self.assertEqual(self.kernel.tables, {})

    def test_ambiguous_commit_failure_and_ready_failure_restore(self):
        def timed_out_after_commit():
            raise subprocess.TimeoutExpired("nft", 5)

        self.kernel.after_commit = timed_out_after_commit
        with self.assertRaises(driver.DriverError):
            driver.hold_partition(self.pin, 1)
        self.assertEqual(self.kernel.tables, {})
        self.kernel.after_commit = None
        with mock.patch.object(driver, "_emit", side_effect=BrokenPipeError), self.assertRaises(BrokenPipeError):
            driver.hold_partition(self.pin, 1)
        self.assertEqual(self.kernel.tables, {})

    def test_refused_hold_does_not_clean_preexisting_owned_table(self):
        driver.apply_partition(self.pin)
        before = copy.deepcopy(self.kernel.tables)
        with self.assertRaises(driver.DriverError):
            driver.hold_partition(self.pin, 1)
        self.assertEqual(self.kernel.tables, before)


if __name__ == "__main__":
    unittest.main()

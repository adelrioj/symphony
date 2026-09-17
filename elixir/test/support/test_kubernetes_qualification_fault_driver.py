#!/usr/bin/env python3
"""Refusal checks for the qualification fault driver.

These cover the decisions that must never be wrong: protected hosts, retained
volumes, foreign CSI drivers, malformed requests and world-readable request files.
They run as any user and touch no LVM, nft or Kubernetes state.
"""

import importlib.util
import json
import os
import stat
import sys
import tempfile
import unittest

SOURCE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "kubernetes_qualification_fault_driver.py")
spec = importlib.util.spec_from_file_location("qualification_fault_driver", SOURCE)
driver = importlib.util.module_from_spec(spec)
spec.loader.exec_module(driver)

GOOD_PINS = {
    "authorization": "qualification-storage-and-node-fault",
    "node_name": "symphony-qual-5slot",
    "node_uid": "11111111-2222-3333-4444-555555555555",
    "machine_id": "0123456789abcdef0123456789abcdef",
    "server_number": 3080340,
    "vg_name": "symphony-state",
    "management_ipv4": "203.0.113.10",
    "cluster_cidrs": ["10.42.0.0/16", "10.43.0.0/16"],
    "excluded_volume_handles": ["a5333dad-adc8-4695-ae70-becfaf99926c"],
    "max_hold_seconds": 600,
}

REQUEST = {
    "scenario": "storage_deletion",
    "phase": "apply",
    "deployment_id": "qual5-20260917",
    "scope": {"namespace": "symphony-qual"},
    "resource": {
        "environment_id": "env-1",
        "issue_id": "issue-1",
        "provider_resource_id": {"uid": "pod-uid"},
        "volumes": [{"volume_handle": "8be0a689-dc8e-4e70-9520-2004d622762f", "csi_driver": "topolvm.io"}],
    },
    "credential_references": {"kubeconfig": "/root/.kube/config", "context": "qual"},
}


class PinTests(unittest.TestCase):
    def setUp(self):
        self.original = dict(driver.PINS)
        driver.PINS.clear()
        driver.PINS.update(GOOD_PINS)

    def tearDown(self):
        driver.PINS.clear()
        driver.PINS.update(self.original)

    def test_good_pins_validate(self):
        driver.validate_pins()

    def test_protected_server_number_refused(self):
        driver.PINS["server_number"] = 3071011
        with self.assertRaises(driver.DriverError):
            driver.validate_pins()

    def test_protected_machine_id_refused(self):
        driver.PINS["machine_id"] = "91d53397210e4abeae824abe6c6032a7"
        with self.assertRaises(driver.DriverError):
            driver.validate_pins()

    def test_cluster_cidr_covering_loopback_refused(self):
        driver.PINS["cluster_cidrs"] = ["0.0.0.0/1"]
        with self.assertRaises(driver.DriverError):
            driver.validate_pins()

    def test_cluster_cidr_containing_management_refused(self):
        driver.PINS["cluster_cidrs"] = ["203.0.113.0/24"]
        with self.assertRaises(driver.DriverError):
            driver.validate_pins()

    def test_unbounded_hold_refused(self):
        driver.PINS["max_hold_seconds"] = 36000
        with self.assertRaises(driver.DriverError):
            driver.validate_pins()


class VolumeTests(unittest.TestCase):
    def setUp(self):
        self.original = dict(driver.PINS)
        driver.PINS.clear()
        driver.PINS.update(GOOD_PINS)

    def tearDown(self):
        driver.PINS.clear()
        driver.PINS.update(self.original)

    def test_in_scope_volume_accepted(self):
        self.assertEqual(driver.volumes_of(REQUEST), ["8be0a689-dc8e-4e70-9520-2004d622762f"])

    def test_excluded_retained_volume_refused(self):
        request = json.loads(json.dumps(REQUEST))
        request["resource"]["volumes"][0]["volume_handle"] = "a5333dad-adc8-4695-ae70-becfaf99926c"
        with self.assertRaises(driver.DriverError):
            driver.volumes_of(request)

    def test_foreign_csi_driver_refused(self):
        request = json.loads(json.dumps(REQUEST))
        request["resource"]["volumes"][0]["csi_driver"] = "csi.hetzner.cloud"
        with self.assertRaises(driver.DriverError):
            driver.volumes_of(request)

    def test_duplicate_handles_refused(self):
        request = json.loads(json.dumps(REQUEST))
        request["resource"]["volumes"].append(dict(request["resource"]["volumes"][0]))
        with self.assertRaises(driver.DriverError):
            driver.volumes_of(request)


class RequestTests(unittest.TestCase):
    def _write(self, document, mode=0o600):
        handle, path = tempfile.mkstemp()
        with os.fdopen(handle, "w") as stream:
            json.dump(document, stream)
        os.chmod(path, mode)
        self.addCleanup(os.unlink, path)
        return path

    def test_well_formed_request_loads(self):
        self.assertEqual(driver.load_request(self._write(REQUEST))["scenario"], "storage_deletion")

    def test_world_readable_request_refused(self):
        with self.assertRaises(driver.DriverError):
            driver.load_request(self._write(REQUEST, mode=0o644))

    def test_extra_field_refused(self):
        document = dict(REQUEST, unexpected=True)
        with self.assertRaises(driver.DriverError):
            driver.load_request(self._write(document))

    def test_unknown_scenario_refused(self):
        document = dict(REQUEST, scenario="reboot")
        with self.assertRaises(driver.DriverError):
            driver.load_request(self._write(document))

    def test_all_scenario_apply_refused(self):
        document = dict(REQUEST, scenario="all", phase="apply")
        with self.assertRaises(driver.DriverError):
            driver.load_request(self._write(document))

    def test_relative_request_path_refused(self):
        with self.assertRaises(driver.DriverError):
            driver.load_request("relative/request.json")

    def test_table_name_is_deployment_scoped_and_stable(self):
        first = driver.table_name("qual5-20260917")
        self.assertEqual(first, driver.table_name("qual5-20260917"))
        self.assertNotEqual(first, driver.table_name("qual5-20260918"))


if __name__ == "__main__":
    unittest.main(verbosity=2)

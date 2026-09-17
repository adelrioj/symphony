#!/usr/bin/env python3
"""Focused checks for kubernetes_scratch_fault_driver.py.

Run: python3 -m unittest discover -s elixir/test/support -p 'test_*.py' -v
  or python3 elixir/test/support/test_kubernetes_scratch_fault_driver.py

These exercise pure validation (identity mismatch, excluded handle) and the
narrowly shared descriptor-holder on a harmless tempfile. The holder never
inspects the fd, so testing it with a regular file cannot make the production
path accept a regular file: only open_pinned_device() opens devices, and it
requires a block device whose rdev matches the pin.
"""

import importlib.util
import os
import signal
import json
import tempfile
import unittest

_HERE = os.path.dirname(os.path.abspath(__file__))
_SPEC = importlib.util.spec_from_file_location(
    "kubernetes_scratch_fault_driver",
    os.path.join(_HERE, "kubernetes_scratch_fault_driver.py"),
)
driver = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(driver)

EXCLUDED = [
    "a5333dad-adc8-4695-ae70-becfaf99926c",
    "47509632-4c7d-4d63-b0ab-b7bf084acf01",
    "e336c1e5-8f2d-4e78-a269-a590673f5100",
]
TARGET = "3f4b1c2d-0000-4a00-8a00-aaaaaaaaaaaa"


def pin(**over):
    doc = {
        "authorization": "scratch-only-readonly-lv-hold",
        "namespace": "symphony-scratch-fault-20260916",
        "namespace_uid": "11111111-1111-4111-8111-111111111111",
        "pvc_name": "scratch-pvc",
        "pvc_uid": "22222222-2222-4222-8222-222222222222",
        "pv_name": "pvc-33333333-3333-4333-8333-333333333333",
        "pv_uid": "44444444-4444-4444-8444-444444444444",
        "volume_handle": TARGET,
        "logical_volume_uid": TARGET,
        "node_uid": "66666666-6666-4666-8666-666666666666",
        "vg_name": "symphony-state",
        "lv_name": TARGET,
        "lv_uuid": "pxHQQr-3Jk5-JMHY-16pT-ykAj-3MeL-yGrGnZ",
        "lv_size_bytes": 8589934592,
        "major": 252,
        "minor": 7,
        "max_hold_seconds": 1200,
        "excluded_volume_handles": list(EXCLUDED),
    }
    doc.update(over)
    return doc


def row(**over):
    r = {
        "vg_name": "symphony-state",
        "lv_name": TARGET,
        "lv_uuid": "pxHQQr-3Jk5-JMHY-16pT-ykAj-3MeL-yGrGnZ",
        "lv_size": "8589934592",
        "lv_attr": "Vwi-aotz--",
        "lv_layout": "thin,sparse",
        "pool_lv": "pool0",
        "lv_kernel_major": "252",
        "lv_kernel_minor": "7",
    }
    r.update(over)
    return r


class PinValidation(unittest.TestCase):
    def test_excluded_volume_handle_is_rejected(self):
        with self.assertRaises(driver.DriverError) as ctx:
            driver.validate_pin_document(pin(volume_handle=EXCLUDED[1], lv_name=EXCLUDED[1]))
        self.assertIn("excluded", str(ctx.exception))

    def test_missing_required_exclusion_is_rejected(self):
        with self.assertRaises(driver.DriverError):
            driver.validate_pin_document(pin(excluded_volume_handles=EXCLUDED[:2]))

    def test_unknown_key_is_rejected(self):
        with self.assertRaises(driver.DriverError):
            driver.validate_pin_document(pin(extra="nope"))


    def test_conflicting_volume_identity_is_rejected(self):
        with self.assertRaises(driver.DriverError):
            driver.validate_pin_document(pin(lv_name="99999999-9999-4999-8999-999999999999"))
    def test_oversized_or_unauthorized_pin_is_rejected(self):
        with self.assertRaises(driver.DriverError):
            driver.validate_pin_document(pin(lv_size_bytes=8589934593))
        with self.assertRaises(driver.DriverError):
            driver.validate_pin_document(pin(max_hold_seconds=1201))
        with self.assertRaises(driver.DriverError):
            driver.validate_pin_document(pin(authorization="anything-else"))
        with self.assertRaises(driver.DriverError):
            driver.validate_pin_document(pin(vg_name="other-vg"))

    def test_duration_bounds(self):
        p = driver.validate_pin_document(pin(max_hold_seconds=60))
        self.assertEqual(driver.effective_hold_seconds(p, 60), 60)
        for bad in (0, 61, 1201):
            with self.assertRaises(driver.DriverError):
                driver.effective_hold_seconds(p, bad)


class LvIdentity(unittest.TestCase):
    def test_identity_mismatch_is_rejected(self):
        driver.verify_lv_row(pin(), row())
        for field, value in (
            ("lv_uuid", "aaaaaa-3Jk5-JMHY-16pT-ykAj-3MeL-yGrGnZ"),
            ("lv_name", "99999999-9999-4999-8999-999999999999"),
            ("lv_size", "8589934593"),
            ("lv_kernel_minor", "8"),
        ):
            with self.assertRaises(driver.DriverError, msg=field):
                driver.verify_lv_row(pin(), row(**{field: value}))

    def test_thin_pool_and_non_thin_lv_are_rejected(self):
        with self.assertRaises(driver.DriverError):
            driver.verify_lv_row(pin(), row(lv_attr="twi-aotz--", lv_layout="thin,pool", pool_lv=""))
        with self.assertRaises(driver.DriverError):
            driver.verify_lv_row(pin(), row(lv_attr="-wi-ao----", lv_layout="linear", pool_lv=""))

    def test_report_parsing_requires_exactly_one_row(self):
        one = '{"report":[{"lv":[%s]}]}' % json.dumps(row())
        self.assertEqual(driver.parse_lvs_report(one), row())
        with self.assertRaises(driver.DriverError):
            driver.parse_lvs_report('{"report":[{"lv":[]}]}')
        with self.assertRaises(driver.DriverError):
            driver.parse_lvs_report('{"report":[{"lv":[{},{}]}]}')


class DescriptorHold(unittest.TestCase):
    def _fd(self):
        handle, path = tempfile.mkstemp()
        os.close(handle)
        self.addCleanup(os.unlink, path)
        return os.open(path, os.O_RDONLY | os.O_CLOEXEC)

    def test_deadline_releases_descriptor(self):
        fd = self._fd()
        seen = []
        reason = driver.hold_descriptor(fd, 0.05, lambda s, d: seen.append(d - s))
        self.assertEqual(reason, "deadline")
        self.assertAlmostEqual(seen[0], 0.05, places=6)
        with self.assertRaises(OSError):
            os.fstat(fd)

    def test_sigterm_releases_descriptor(self):
        fd = self._fd()
        reason = driver.hold_descriptor(fd, 600, lambda s, d: os.kill(os.getpid(), signal.SIGTERM))
        self.assertEqual(reason, "SIGTERM")
        with self.assertRaises(OSError):
            os.fstat(fd)
        self.assertIs(signal.getsignal(signal.SIGTERM), signal.SIG_DFL)


if __name__ == "__main__":
    unittest.main(verbosity=2)

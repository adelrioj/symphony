#!/usr/bin/env python3
"""Operator-only scratch fault driver: hold one read-only fd on one pinned LV.

Scope: this process does exactly one thing. It validates a root-owned private
pin file, verifies the pinned LVM logical volume identity with `lvs` (read-only
reporting), opens `/dev/<vg>/<lv>` O_RDONLY|O_CLOEXEC, re-verifies identity
after the open, prints one `ready` record, holds the descriptor until a bounded
monotonic deadline or SIGTERM/SIGINT, then closes it and prints one `release`
record.

It never reads or writes device contents, never mutates LVM, never forks or
daemonizes, never signals other processes, never touches the network, and never
starts/stops services. Restoration is `systemctl stop <run-owned unit>` or
SIGTERM by the operator; RuntimeMaxSec on that unit is the independent upper
bound. Neither the pin nor the CLI can authorize more than 1200 seconds.

Usage:
    kubernetes_scratch_fault_driver.py --pin /root/<dir>/<pin>.json \
        --duration-seconds 300

Checks live in test_kubernetes_scratch_fault_driver.py beside this file.
"""

import argparse
import errno
import json
import os
import re
import signal
import stat
import subprocess
import sys
import time

HARD_MAX_HOLD_SECONDS = 1200
MAX_LV_SIZE_BYTES = 8 * 1024 * 1024 * 1024
REQUIRED_AUTHORIZATION = "scratch-only-readonly-lv-hold"
REQUIRED_VG_NAME = "symphony-state"
REQUIRED_NAMESPACE_PREFIX = "symphony-scratch-fault-"
REQUIRED_EXCLUSIONS = frozenset(
    {
        "a5333dad-adc8-4695-ae70-becfaf99926c",
        "47509632-4c7d-4d63-b0ab-b7bf084acf01",
        "e336c1e5-8f2d-4e78-a269-a590673f5100",
    }
)
MAX_PIN_BYTES = 65536
LVS_TIMEOUT_SECONDS = 30

UUID_RE = re.compile(r"\A[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}\Z")
LVM_UUID_RE = re.compile(r"\A(LVM-)?[A-Za-z0-9]{6}(-[A-Za-z0-9]{4}){5}-[A-Za-z0-9]{6}\Z")
DNS1123_RE = re.compile(r"\A[a-z0-9]([a-z0-9.-]{0,251}[a-z0-9])?\Z")
LVM_NAME_RE = re.compile(r"\A[A-Za-z0-9+_.][A-Za-z0-9+_.-]{0,126}\Z")

LVS_FIELDS = (
    "vg_name,lv_name,lv_uuid,lv_size,lv_attr,lv_layout,pool_lv,"
    "lv_kernel_major,lv_kernel_minor"
)


class DriverError(Exception):
    """Refusal or failure; always fatal, never retried in-process."""


def _fail(message):
    raise DriverError(message)


# --- pin schema ------------------------------------------------------------


def _text(name, value, pattern, maxlen):
    if not isinstance(value, str) or len(value) > maxlen or not pattern.match(value):
        _fail("pin field %s is not a well-formed value" % name)


def _integer(name, value, low, high):
    if isinstance(value, bool) or not isinstance(value, int) or not low <= value <= high:
        _fail("pin field %s is not an integer in [%d, %d]" % (name, low, high))


_FIELD_CHECKS = {
    "authorization": lambda n, v: _text(n, v, re.compile(r"\A[a-z-]{1,64}\Z"), 64),
    "namespace": lambda n, v: _text(n, v, DNS1123_RE, 63),
    "namespace_uid": lambda n, v: _text(n, v, UUID_RE, 36),
    "pvc_name": lambda n, v: _text(n, v, DNS1123_RE, 253),
    "pvc_uid": lambda n, v: _text(n, v, UUID_RE, 36),
    "pv_name": lambda n, v: _text(n, v, DNS1123_RE, 253),
    "pv_uid": lambda n, v: _text(n, v, UUID_RE, 36),
    "volume_handle": lambda n, v: _text(n, v, UUID_RE, 36),
    "logical_volume_uid": lambda n, v: _text(n, v, UUID_RE, 36),
    "node_uid": lambda n, v: _text(n, v, UUID_RE, 36),
    "vg_name": lambda n, v: _text(n, v, LVM_NAME_RE, 127),
    "lv_name": lambda n, v: _text(n, v, UUID_RE, 36),
    "lv_uuid": lambda n, v: _text(n, v, LVM_UUID_RE, 64),
    "lv_size_bytes": lambda n, v: _integer(n, v, 1, MAX_LV_SIZE_BYTES),
    "major": lambda n, v: _integer(n, v, 1, 4095),
    "minor": lambda n, v: _integer(n, v, 0, 1048575),
    "max_hold_seconds": lambda n, v: _integer(n, v, 1, HARD_MAX_HOLD_SECONDS),
    "excluded_volume_handles": lambda n, v: _exclusions(n, v),
}

# Identities echoed in ready/release records: names and UUIDs only, never the
# authorization token or the exclusion list.
SAFE_IDENTITY_FIELDS = (
    "namespace",
    "namespace_uid",
    "pvc_name",
    "pvc_uid",
    "pv_name",
    "pv_uid",
    "volume_handle",
    "logical_volume_uid",
    "node_uid",
    "vg_name",
    "lv_name",
    "lv_uuid",
    "lv_size_bytes",
    "major",
    "minor",
)


def _exclusions(name, value):
    if not isinstance(value, list) or not 1 <= len(value) <= 256:
        _fail("pin field %s must be a non-empty list" % name)
    for item in value:
        _text(name, item, UUID_RE, 36)


def validate_pin_document(document):
    """Validate schema and policy of a decoded pin. Returns it unchanged."""
    if not isinstance(document, dict):
        _fail("pin must be a JSON object")
    missing = sorted(set(_FIELD_CHECKS) - set(document))
    unknown = sorted(set(document) - set(_FIELD_CHECKS))
    if missing or unknown:
        _fail("pin schema mismatch: missing=%s unknown=%s" % (missing, unknown))
    for key, check in _FIELD_CHECKS.items():
        check(key, document[key])

    if document["authorization"] != REQUIRED_AUTHORIZATION:
        _fail("pin authorization is not %r" % REQUIRED_AUTHORIZATION)
    if document["vg_name"] != REQUIRED_VG_NAME:
        _fail("pin vg_name is not %r" % REQUIRED_VG_NAME)
    if not document["namespace"].startswith(REQUIRED_NAMESPACE_PREFIX):
        _fail("pin namespace is not a %r scratch namespace" % REQUIRED_NAMESPACE_PREFIX)

    excluded = set(document["excluded_volume_handles"])
    if not REQUIRED_EXCLUSIONS.issubset(excluded):
        _fail(
            "pin exclusion list is missing protected handles: %s"
            % sorted(REQUIRED_EXCLUSIONS - excluded)
        )
    for field in ("volume_handle", "lv_name", "logical_volume_uid", "pv_uid", "pvc_uid"):
        if document[field] in excluded:
            _fail("pin %s names an excluded volume; refusing" % field)
    if not document["volume_handle"] == document["logical_volume_uid"] == document["lv_name"]:
        _fail("CSI handle, LogicalVolume UID, and LV name must identify the same volume")
    return document


def effective_hold_seconds(pin, requested_seconds):
    """Hold length after the CLI, pin, and hard ceilings are all applied."""
    _integer("--duration-seconds", requested_seconds, 1, HARD_MAX_HOLD_SECONDS)
    if requested_seconds > pin["max_hold_seconds"]:
        _fail(
            "--duration-seconds %d exceeds pin max_hold_seconds %d"
            % (requested_seconds, pin["max_hold_seconds"])
        )
    return requested_seconds


# --- pin file ---------------------------------------------------------------


def _require_private_root_owned(description, st, expected_mode, expect_dir):
    kind_ok = stat.S_ISDIR(st.st_mode) if expect_dir else stat.S_ISREG(st.st_mode)
    if not kind_ok:
        _fail("%s is not a regular %s" % (description, "directory" if expect_dir else "file"))
    if st.st_uid != 0:
        _fail("%s is not owned by root (uid=%d)" % (description, st.st_uid))
    if stat.S_IMODE(st.st_mode) != expected_mode:
        _fail("%s mode is %04o, expected %04o" % (description, stat.S_IMODE(st.st_mode), expected_mode))


def load_pin(path):
    """Read and validate a root-owned private pin file at an absolute path."""
    if not os.path.isabs(path) or path != os.path.normpath(path) or path.rstrip("/") != path:
        _fail("--pin must be an absolute, normalized path without a trailing slash")
    if os.path.realpath(path) != path:
        _fail("--pin path contains a symlink; refusing")

    directory = os.path.dirname(path)
    _require_private_root_owned("pin directory", os.lstat(directory), 0o700, True)
    ancestor = os.path.dirname(directory)
    while True:
        st = os.lstat(ancestor)
        if st.st_uid != 0 or st.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
            _fail("pin ancestor %s is not root-owned and non-writable by others" % ancestor)
        parent = os.path.dirname(ancestor)
        if parent == ancestor:
            break
        ancestor = parent

    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        _require_private_root_owned("pin file", os.fstat(fd), 0o600, False)
        raw = os.read(fd, MAX_PIN_BYTES + 1)
    finally:
        os.close(fd)
    if len(raw) > MAX_PIN_BYTES:
        _fail("pin file is larger than %d bytes" % MAX_PIN_BYTES)
    try:
        document = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, ValueError) as exc:
        _fail("pin file is not valid UTF-8 JSON: %s" % exc)
    return validate_pin_document(document)


# --- LVM identity -----------------------------------------------------------


def parse_lvs_report(stdout):
    """Return the single lv row from an `lvs --reportformat json` document."""
    try:
        document = json.loads(stdout)
    except ValueError as exc:
        _fail("lvs did not return valid JSON: %s" % exc)
    rows = []
    for report in document.get("report", []) if isinstance(document, dict) else []:
        rows.extend(report.get("lv", []) if isinstance(report, dict) else [])
    if len(rows) != 1:
        _fail("lvs reported %d logical volumes, expected exactly 1" % len(rows))
    if not isinstance(rows[0], dict):
        _fail("lvs row is not an object")
    return rows[0]


def query_lv(vg_name, lv_name):
    """Read-only identity query for one LV. Never mutates LVM state."""
    command = [
        "lvs",
        "--reportformat",
        "json",
        "--units",
        "b",
        "--nosuffix",
        "-o",
        LVS_FIELDS,
        "%s/%s" % (vg_name, lv_name),
    ]
    try:
        result = subprocess.run(
            command,
            stdin=subprocess.DEVNULL,
            capture_output=True,
            timeout=LVS_TIMEOUT_SECONDS,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        _fail("lvs invocation failed: %s" % exc)
    if result.returncode != 0:
        _fail(
            "lvs exited %d: %s"
            % (result.returncode, result.stderr.decode("utf-8", "replace").strip()[:512])
        )
    return parse_lvs_report(result.stdout.decode("utf-8", "replace"))


def _row_text(row, key):
    value = row.get(key)
    if value is None:
        _fail("lvs row is missing %s" % key)
    return str(value).strip()


def _row_int(row, key):
    text = _row_text(row, key).rstrip("Bb")
    try:
        return int(text)
    except ValueError:
        _fail("lvs field %s is not an integer: %r" % (key, text))


def verify_lv_row(pin, row):
    """Fail unless the reported LV is exactly the pinned thin volume."""
    for pin_key, row_key in (
        ("vg_name", "vg_name"),
        ("lv_name", "lv_name"),
        ("lv_uuid", "lv_uuid"),
    ):
        actual = _row_text(row, row_key)
        if actual != pin[pin_key]:
            _fail("LV identity mismatch on %s: pin=%r lvs=%r" % (row_key, pin[pin_key], actual))

    size = _row_int(row, "lv_size")
    if size != pin["lv_size_bytes"]:
        _fail("LV size mismatch: pin=%d lvs=%d" % (pin["lv_size_bytes"], size))
    if size > MAX_LV_SIZE_BYTES:
        _fail("LV size %d exceeds the %d byte scratch ceiling" % (size, MAX_LV_SIZE_BYTES))

    for pin_key, row_key in (("major", "lv_kernel_major"), ("minor", "lv_kernel_minor")):
        actual = _row_int(row, row_key)
        if actual != pin[pin_key]:
            _fail("LV %s mismatch: pin=%d lvs=%d" % (row_key, pin[pin_key], actual))

    attr = _row_text(row, "lv_attr")
    layout = set(_row_text(row, "lv_layout").split(","))
    if not attr:
        _fail("lvs reported an empty lv_attr")
    if attr[0] == "t" or "pool" in layout:
        _fail("pinned LV is a thin pool; refusing")
    if attr[0] != "V" or "thin" not in layout or "sparse" not in layout:
        _fail("pinned LV is not a thin volume (attr=%r layout=%r)" % (attr, sorted(layout)))
    if not _row_text(row, "pool_lv"):
        _fail("pinned thin volume reports no pool_lv")
    return row


# --- device hold ------------------------------------------------------------


def open_pinned_device(pin):
    """Open the pinned LV read-only and prove the descriptor is that device."""
    device_path = "/dev/%s/%s" % (pin["vg_name"], pin["lv_name"])
    resolved = os.path.realpath(device_path)
    if not resolved.startswith("/dev/"):
        _fail("device path %s resolves outside /dev: %s" % (device_path, resolved))

    verify_lv_row(pin, query_lv(pin["vg_name"], pin["lv_name"]))
    fd = os.open(device_path, os.O_RDONLY | os.O_CLOEXEC)
    try:
        st = os.fstat(fd)
        if not stat.S_ISBLK(st.st_mode):
            _fail("%s is not a block device" % device_path)
        if (os.major(st.st_rdev), os.minor(st.st_rdev)) != (pin["major"], pin["minor"]):
            _fail(
                "opened device is %d:%d, pin says %d:%d"
                % (os.major(st.st_rdev), os.minor(st.st_rdev), pin["major"], pin["minor"])
            )
        # Re-read identities after the open so a rename/recreate between the
        # first query and the open cannot hand us a different volume.
        verify_lv_row(pin, query_lv(pin["vg_name"], pin["lv_name"]))
    except BaseException:
        os.close(fd)
        raise
    return fd, device_path


def hold_descriptor(fd, duration_seconds, on_ready):
    """Hold fd until the monotonic deadline or SIGTERM/SIGINT; then close it.

    Deliberately knows nothing about what fd is: production hands it a verified
    block-device descriptor, the checks hand it a tempfile descriptor. Returns
    "deadline", "SIGTERM", or "SIGINT".
    """
    caught = []

    def handler(signum, _frame):
        caught.append(signal.Signals(signum).name)

    previous = {s: signal.signal(s, handler) for s in (signal.SIGTERM, signal.SIGINT)}
    start = time.monotonic()
    deadline = start + duration_seconds
    try:
        on_ready(start, deadline)
        while not caught:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return "deadline"
            time.sleep(min(0.25, remaining))
        return caught[0]
    finally:
        for signum, previous_handler in previous.items():
            signal.signal(signum, previous_handler)
        os.close(fd)


def _emit(record):
    sys.stdout.write(json.dumps(record, sort_keys=True) + "\n")
    sys.stdout.flush()


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Hold a read-only descriptor on one pinned scratch LV.",
        allow_abbrev=False,
    )
    parser.add_argument("--pin", required=True, help="absolute path to the private pin file")
    parser.add_argument(
        "--duration-seconds",
        required=True,
        type=int,
        help="hold length, 1..%d, additionally capped by the pin" % HARD_MAX_HOLD_SECONDS,
    )
    args = parser.parse_args(argv)

    pin = load_pin(args.pin)
    hold_seconds = effective_hold_seconds(pin, args.duration_seconds)
    fd, device_path = open_pinned_device(pin)

    identity = {field: pin[field] for field in SAFE_IDENTITY_FIELDS}
    held = {}

    def on_ready(start, deadline):
        held["start"] = start
        record = {
            "event": "ready",
            "holder_pid": os.getpid(),
            "device_path": device_path,
            "hold_seconds": hold_seconds,
            "start_monotonic": start,
            "deadline_monotonic": deadline,
        }
        record.update(identity)
        _emit(record)

    reason = hold_descriptor(fd, hold_seconds, on_ready)
    record = {
        "event": "release",
        "holder_pid": os.getpid(),
        "device_path": device_path,
        "reason": reason,
        "released_monotonic": time.monotonic(),
        "held_seconds": time.monotonic() - held["start"],
    }
    record.update(identity)
    _emit(record)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except DriverError as error:
        _emit_error = {"event": "error", "message": str(error)}
        sys.stderr.write(json.dumps(_emit_error, sort_keys=True) + "\n")
        sys.stderr.flush()
        sys.exit(2)
    except OSError as error:
        message = "%s: %s" % (errno.errorcode.get(error.errno, error.errno), error)
        sys.stderr.write(json.dumps({"event": "error", "message": message}, sort_keys=True) + "\n")
        sys.stderr.flush()
        sys.exit(2)

#!/usr/bin/env python3
"""Operator-only, pinned disposable-node cluster-network partition.

No Kubernetes API, credentials, service control, or network configuration files
are accessed. The operator must freshly verify Kubernetes node/namespace UIDs
and scratch-only eligibility before issuing the <=300-second pin, arrange an
independent systemd restore, and serialize applies for this namespace UID.
SIGKILL, host failure, and a broken nft executable require that external restore.
Receipts describe only this host's nft table, never cluster recovery.

Pin: absolute path, root-owned mode 0600, in a root-owned mode 0700 directory
with root-owned ancestors not writable by others. No symlinks. Requires Linux,
root, and /usr/sbin/nft with native table comments and handle-based deletion.
"""

import argparse
import ipaddress
import json
import os
import re
import signal
import socket
import stat
import subprocess
import sys
import time
import uuid

HARD_MAX_HOLD_SECONDS = 120
NFT_TIMEOUT_SECONDS = 5
MAX_PIN_BYTES = 65536
NFT = "/usr/sbin/nft"
PROTECTED_SERVER_NUMBER = 3071011
PROTECTED_MACHINE_ID = "91d53397210e4abeae824abe6c6032a7"
PREFIX = "symphony-node-fault-"
PIN_FIELDS = frozenset((
    "authorization", "server_number", "node_name", "node_uid", "machine_id",
    "boot_id", "namespace", "namespace_uid", "management_ipv4",
    "management_ssh_port", "cluster_cidrs", "max_hold_seconds", "expires_at_unix",
))
FORBIDDEN_NETWORKS = tuple(ipaddress.ip_network(cidr) for cidr in (
    "0.0.0.0/8", "127.0.0.0/8", "169.254.0.0/16", "224.0.0.0/4",
    "::/128", "::1/128", "fe80::/10", "ff00::/8",
))


class DriverError(Exception):
    """Refusal or bounded host-operation failure."""


def _fail(message):
    raise DriverError(message)


def _integer(name, value, low, high):
    if type(value) is not int or not low <= value <= high:
        _fail("%s must be an integer in [%d, %d]" % (name, low, high))


def validate_pin_document(document, restoring=False):
    if not isinstance(document, dict) or set(document) != PIN_FIELDS:
        _fail("pin schema must contain exactly the required fields")
    if document["authorization"] != "scratch-only-node-network-partition":
        _fail("pin does not authorize scratch-only node partition")
    _integer("server_number", document["server_number"], 1, 2**63 - 1)
    if document["server_number"] == PROTECTED_SERVER_NUMBER:
        _fail("protected server number")
    for field in ("node_name", "namespace"):
        value = document[field]
        if not isinstance(value, str) or not re.fullmatch(r"symphony-node-fault-[a-z0-9](?:[a-z0-9-]*[a-z0-9])?", value) or len(value) > 63:
            _fail("%s must be a scratch-only DNS label" % field)
    for field in ("node_uid", "namespace_uid", "boot_id"):
        value = document[field]
        try:
            valid = isinstance(value, str) and str(uuid.UUID(value)) == value
        except ValueError:
            valid = False
        if not valid:
            _fail("%s must be a canonical UUID" % field)
    machine_id = document["machine_id"]
    if not isinstance(machine_id, str) or not re.fullmatch(r"[0-9a-f]{32}", machine_id):
        _fail("machine_id must be 32 lowercase hex digits")
    if machine_id == PROTECTED_MACHINE_ID:
        _fail("protected machine ID")
    try:
        management = ipaddress.IPv4Address(document["management_ipv4"])
    except (ValueError, TypeError):
        _fail("management_ipv4 must be one canonical IPv4 address")
    if str(management) != document["management_ipv4"] or management.is_unspecified or management.is_multicast or management.is_loopback or management.is_link_local:
        _fail("management_ipv4 must be a unicast management address")
    _integer("management_ssh_port", document["management_ssh_port"], 22, 22)
    cidrs = document["cluster_cidrs"]
    if not isinstance(cidrs, list) or not 1 <= len(cidrs) <= 256:
        _fail("cluster_cidrs must be a nonempty bounded list")
    for cidr in cidrs:
        try:
            network = ipaddress.ip_network(cidr, strict=True) if isinstance(cidr, str) else None
        except ValueError:
            _fail("cluster_cidrs contains a malformed or noncanonical CIDR")
        if network is None or str(network) != cidr or network.prefixlen == 0:
            _fail("cluster_cidrs must contain canonical non-default CIDRs")
        # Check overlap, not just the first address: a broad supernet can
        # otherwise contain loopback/link-local/multicast without starting there.
        if any(network.version == forbidden.version and network.overlaps(forbidden) for forbidden in FORBIDDEN_NETWORKS):
            _fail("cluster CIDR overlaps unspecified, loopback, link-local, or multicast addresses")
    _integer("max_hold_seconds", document["max_hold_seconds"], 1, HARD_MAX_HOLD_SECONDS)
    _integer("expires_at_unix", document["expires_at_unix"], 1, 2**63 - 1)
    now = time.time()
    if not restoring and not now <= document["expires_at_unix"] <= now + 300:
        _fail("pin must expire between now and 300 seconds from now")
    return document


def _private_root_owned(description, st, mode, directory=False):
    kind_ok = stat.S_ISDIR(st.st_mode) if directory else stat.S_ISREG(st.st_mode)
    if not kind_ok or st.st_uid != 0 or stat.S_IMODE(st.st_mode) != mode:
        _fail("%s must be root-owned, correct type, and mode %04o" % (description, mode))


def _unique_object(pairs):
    document = {}
    for key, value in pairs:
        if key in document:
            _fail("duplicate JSON field in pin")
        document[key] = value
    return document


def load_pin(path, restoring=False):
    if not os.path.isabs(path) or path != os.path.normpath(path) or path.rstrip("/") != path:
        _fail("--pin must be an absolute normalized file path")
    if os.path.realpath(path) != path:
        _fail("--pin path must not contain symlinks")
    directory = os.path.dirname(path)
    _private_root_owned("pin directory", os.lstat(directory), 0o700, directory=True)
    ancestor = os.path.dirname(directory)
    while True:
        st = os.lstat(ancestor)
        if not stat.S_ISDIR(st.st_mode) or st.st_uid != 0 or st.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
            _fail("pin ancestors must be root-owned directories not writable by others")
        parent = os.path.dirname(ancestor)
        if parent == ancestor:
            break
        ancestor = parent
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK)
    with os.fdopen(fd, "rb") as stream:
        _private_root_owned("pin file", os.fstat(stream.fileno()), 0o600)
        raw = stream.read(MAX_PIN_BYTES + 1)
    if len(raw) > MAX_PIN_BYTES:
        _fail("pin file exceeds size limit")
    try:
        document = json.loads(raw.decode("utf-8"), object_pairs_hook=_unique_object)
    except (UnicodeDecodeError, ValueError):
        _fail("pin must be UTF-8 JSON")
    return validate_pin_document(document, restoring=restoring)


def read_identity(path):
    with open(path, encoding="ascii") as stream:
        return stream.read(256).strip()


def verify_host(pin):
    if os.geteuid() != 0:
        _fail("driver requires root")
    actual = {
        "machine_id": read_identity("/etc/machine-id"),
        "boot_id": read_identity("/proc/sys/kernel/random/boot_id"),
        "node_name": socket.gethostname(),
        "server_number": read_identity("/etc/symphony-node-fault-server-id"),
    }
    if actual["machine_id"] == PROTECTED_MACHINE_ID or actual["server_number"] == str(PROTECTED_SERVER_NUMBER):
        _fail("this is a protected host")
    for field, value in actual.items():
        if value != str(pin[field]):
            _fail("host %s does not match pin" % field)


def table_name(pin):
    return "symphony_node_fault_" + uuid.UUID(pin["namespace_uid"]).hex


def ownership_comment(pin):
    return "snf:%s:%s:%s" % (pin["namespace_uid"], pin["node_uid"], pin["boot_id"])


def nft(args, batch=None):
    try:
        result = subprocess.run(
            [NFT] + args, input=batch,
            capture_output=True, text=True, timeout=NFT_TIMEOUT_SECONDS,
            env={"PATH": "/usr/sbin:/usr/bin:/sbin:/bin", "LC_ALL": "C"},
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        _fail("nft operation failed: %s" % type(exc).__name__)
    if result.returncode:
        _fail("nft operation refused (exit %d): %s" % (result.returncode, result.stderr[:1024]))
    if "--json" not in args:
        return result.stdout
    try:
        objects = json.loads(result.stdout)["nftables"]
    except (ValueError, KeyError, TypeError):
        _fail("nft returned malformed JSON")
    if not isinstance(objects, list) or any(not isinstance(obj, dict) for obj in objects):
        _fail("nft returned malformed objects")
    return objects


def query_table(pin):
    name = table_name(pin)
    objects = nft(["--json", "--handle", "list", "tables"])
    tables = [obj["table"] for obj in objects if isinstance(obj.get("table"), dict)
              and obj["table"].get("family") == "inet" and obj["table"].get("name") == name]
    if not tables:
        return None
    if len(tables) != 1:
        _fail("nft returned ambiguous table identity")
    table = tables[0]
    _integer("nft table handle", table.get("handle"), 1, 2**64 - 1)
    # nft 1.0.6 silently ignores JSON table comments on input and omits them
    # on output. Read native ownership metadata, binding it to the JSON handle.
    text = nft(["--handle", "list", "table", "inet", name])
    lines = text.splitlines()
    header = "table inet %s { # handle %d" % (name, table["handle"])
    if not lines or lines[0] != header or lines[-1] != "}":
        _fail("native table identity/handle does not match JSON observation")
    comments = [re.fullmatch(r'\tcomment "([^"\\]*)"', line) for line in lines[1:-1]]
    comments = [match.group(1) for match in comments if match]
    if len(comments) != 1:
        _fail("native table must have exactly one unambiguous top-level ownership comment")
    table["comment"] = comments[0]
    return table


def apply_partition(pin):
    """One exclusive atomic nft transaction; caller owns uncertain-commit cleanup."""
    validate_pin_document(pin)
    name = table_name(pin)
    commands = ['create table inet %s { comment "%s"; }' % (name, ownership_comment(pin))]
    for chain in ("input", "output", "forward"):
        commands.append("add chain inet %s %s { type filter hook %s priority -10; policy accept; }" % (name, chain, chain))
        expressions = []
        if chain == "input":
            expressions.append("ip saddr %s tcp dport 22 accept" % pin["management_ipv4"])
        elif chain == "output":
            expressions.append("ip daddr %s tcp sport 22 accept" % pin["management_ipv4"])
        for cidr in pin["cluster_cidrs"]:
            protocol = "ip" if ipaddress.ip_network(cidr).version == 4 else "ip6"
            for field in ("saddr", "daddr"):
                expressions.append("%s %s %s drop" % (protocol, field, cidr))
        for expression in expressions:
            commands.append("add rule inet %s %s %s" % (name, chain, expression))
    nft(["--file", "-"], "\n".join(commands) + "\n")


def restore_partition(pin):
    """Delete only the exact owned table handle; absence is already restored."""
    table = query_table(pin)
    if table is None:
        return
    if table.get("comment") != ownership_comment(pin):
        _fail("table ownership mismatch; refusing deletion")
    handle = table.get("handle")
    _integer("nft table handle", handle, 1, 2**64 - 1)
    # A concurrently replaced table has a different handle: never delete by name.
    nft(["--file", "-"], "delete table inet handle %d\n" % handle)
    if query_table(pin) is not None:
        _fail("table is present after deletion; not claiming release")


def _emit(record):
    sys.stdout.write(json.dumps(record, sort_keys=True) + "\n")
    sys.stdout.flush()


def _receipt(pin, event, **fields):
    return dict(event=event, table=table_name(pin), node_name=pin["node_name"],
                node_uid=pin["node_uid"], namespace_uid=pin["namespace_uid"],
                boot_id=pin["boot_id"], holder_pid=os.getpid(), **fields)


def hold_partition(pin, duration_seconds):
    validate_pin_document(pin)
    _integer("--duration-seconds", duration_seconds, 1, HARD_MAX_HOLD_SECONDS)
    if duration_seconds > pin["max_hold_seconds"]:
        _fail("requested duration exceeds pin ceiling")
    caught = []

    def handler(signum, _frame):
        # Never raise across an nft commit: let the bounded child finish, then
        # reconcile ownership even when its timeout leaves commit status unknown.
        if not caught:
            caught.append(signal.Signals(signum).name)

    previous = {s: signal.signal(s, handler) for s in (signal.SIGTERM, signal.SIGINT)}
    attempted = False
    try:
        if query_table(pin) is not None:
            _fail("partition table already exists; refusing apply")
        if caught:
            return caught[0]
        start = time.monotonic()
        deadline = start + duration_seconds
        try:
            attempted = True
            apply_partition(pin)
            if not caught and time.monotonic() < deadline:
                _emit(_receipt(pin, "ready", mode="apply", table_state="installed",
                               hold_seconds=duration_seconds, start_monotonic=start,
                               deadline_monotonic=deadline))
            while not caught:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    break
                time.sleep(min(0.25, remaining))
            reason = caught[0] if caught else "deadline"
        finally:
            if attempted:
                restore_partition(pin)
        _emit(_receipt(pin, "release", reason=reason, table_state="absent",
                       released_monotonic=time.monotonic()))
        return reason
    finally:
        for signum, previous_handler in previous.items():
            signal.signal(signum, previous_handler)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    parser.add_argument("--pin", required=True)
    parser.add_argument("--duration-seconds", type=int)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--check", action="store_true", help="read-only pin/host/table preflight")
    mode.add_argument("--restore", action="store_true", help="remove only this pin's owned table")
    args = parser.parse_args(argv)
    try:
        if args.restore and args.duration_seconds is not None:
            _fail("--restore does not accept --duration-seconds")
        if not args.restore and args.duration_seconds is None:
            _fail("apply and --check require --duration-seconds")
        pin = load_pin(args.pin, restoring=args.restore)
        verify_host(pin)
        if args.restore:
            # Keep restore immune to SIGINT/SIGTERM until the bounded deletion
            # completes; an independent restore must be able to finish its job.
            previous = {s: signal.signal(s, signal.SIG_IGN) for s in (signal.SIGTERM, signal.SIGINT)}
            try:
                restore_partition(pin)
                _emit(_receipt(pin, "release", reason="restore", table_state="absent"))
            finally:
                for signum, previous_handler in previous.items():
                    signal.signal(signum, previous_handler)
        elif args.check:
            _integer("--duration-seconds", args.duration_seconds, 1, pin["max_hold_seconds"])
            if query_table(pin) is not None:
                _fail("partition table already exists; refusing preflight")
            _emit(_receipt(pin, "ready", mode="check", table_state="absent"))
        else:
            hold_partition(pin, args.duration_seconds)
        return 0
    except (DriverError, OSError, ValueError) as exc:
        sys.stderr.write(json.dumps({"event": "refusal", "message": str(exc)}, sort_keys=True) + "\n")
        sys.stderr.flush()
        return 2


if __name__ == "__main__":
    sys.exit(main())

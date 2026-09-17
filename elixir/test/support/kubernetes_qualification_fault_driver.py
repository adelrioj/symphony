#!/usr/bin/env python3
"""Operator-only, self-contained physical-fault driver for the managed qualification suite.

Speaks the suite protocol: `--request <private-json-file>`, printing exactly
{"applied": true} on success. Two scoped, bounded, self-releasing faults:

  storage_deletion  hold an open descriptor on the exact TopoLVM logical volume so
                    the CSI RemoveLV fails with "LV in use", then release it.
  node_disconnection install an nft table dropping this host's cluster traffic, then
                    delete it. The management address and SSH stay reachable.

Identities are pinned in PINS below; the profile records this file's sha256, so the
pins are part of the audited bytes and cannot be swapped at call time. Every apply
arms an independent bounded release: SIGKILL of the caller, a crashed suite, or a
lost connection still restores the host without operator action. Protected hosts
and retained volume handles are refused outright.

Requires Linux, root, /usr/sbin/nft and /sbin/lvs.
"""

import argparse
import errno
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

# --- operator pins -----------------------------------------------------------
# Filled per qualification run, then the sha256 of this file goes in the profile.
PINS = {
    "authorization": "qualification-storage-and-node-fault",
    "node_name": "",
    "node_uid": "",
    "machine_id": "",
    "server_number": 0,
    "vg_name": "symphony-state",
    "management_ipv4": "",
    "cluster_cidrs": [],
    "excluded_volume_handles": [],
    "max_hold_seconds": 600,
}

# Hosts that must never be faulted, whatever a request or pin claims.
PROTECTED_SERVER_NUMBERS = frozenset({3071011})
PROTECTED_MACHINE_IDS = frozenset({"91d53397210e4abeae824abe6c6032a7"})

NFT = "/usr/sbin/nft"
LVS = "/sbin/lvs"
STATE_ROOT = "/run/symphony-qualification-fault"
NFT_TIMEOUT_SECONDS = 5
MAX_REQUEST_BYTES = 262144
SCENARIOS = ("storage_deletion", "node_disconnection", "all")
PHASES = ("apply", "restore")
REQUEST_FIELDS = frozenset(
    ("scenario", "phase", "deployment_id", "scope", "resource", "credential_references")
)
FORBIDDEN_NETWORKS = tuple(
    ipaddress.ip_network(cidr)
    for cidr in ("0.0.0.0/8", "127.0.0.0/8", "169.254.0.0/16", "224.0.0.0/4")
)
UUID_RE = re.compile(r"\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\Z")
DEPLOYMENT_RE = re.compile(r"\A[A-Za-z0-9][A-Za-z0-9._-]{0,126}\Z")


class DriverError(Exception):
    """Refusal or bounded host-operation failure."""


def _fail(message):
    raise DriverError(message)


def _unique_object(pairs):
    document = {}
    for key, value in pairs:
        if key in document:
            _fail("duplicate JSON field in request")
        document[key] = value
    return document


# --- pins and host -----------------------------------------------------------


def validate_pins():
    if PINS["authorization"] != "qualification-storage-and-node-fault":
        _fail("pins do not authorize this driver")
    if not UUID_RE.match(PINS["node_uid"] or ""):
        _fail("node_uid pin must be a canonical lowercase UUID")
    if not re.fullmatch(r"[0-9a-f]{32}", PINS["machine_id"] or ""):
        _fail("machine_id pin must be 32 lowercase hex digits")
    if type(PINS["server_number"]) is not int or PINS["server_number"] <= 0:
        _fail("server_number pin must be a positive integer")
    if PINS["server_number"] in PROTECTED_SERVER_NUMBERS or PINS["machine_id"] in PROTECTED_MACHINE_IDS:
        _fail("pins name a protected host")
    if not re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9._-]{0,62}", PINS["vg_name"] or ""):
        _fail("vg_name pin must be a safe volume group name")
    if not 1 <= PINS["max_hold_seconds"] <= 1800:
        _fail("max_hold_seconds pin must be in [1, 1800]")
    try:
        management = ipaddress.IPv4Address(PINS["management_ipv4"])
    except (ValueError, TypeError):
        _fail("management_ipv4 pin must be one canonical IPv4 address")
    if management.is_loopback or management.is_link_local or management.is_multicast:
        _fail("management_ipv4 pin must be a unicast management address")
    cidrs = PINS["cluster_cidrs"]
    if not isinstance(cidrs, list) or not 1 <= len(cidrs) <= 64:
        _fail("cluster_cidrs pin must be a nonempty bounded list")
    for cidr in cidrs:
        try:
            network = ipaddress.ip_network(cidr, strict=True)
        except (ValueError, TypeError):
            _fail("cluster_cidrs pin contains a malformed CIDR")
        if str(network) != cidr or network.prefixlen == 0:
            _fail("cluster_cidrs pin must be canonical and non-default")
        # Overlap, not membership: a supernet can contain loopback without starting there.
        if any(network.version == bad.version and network.overlaps(bad) for bad in FORBIDDEN_NETWORKS):
            _fail("cluster CIDR overlaps loopback, link-local, or multicast space")
        if management in network:
            _fail("cluster CIDR contains the management address")
    for handle in PINS["excluded_volume_handles"]:
        if not UUID_RE.match(handle or ""):
            _fail("excluded_volume_handles pin must contain canonical UUIDs")


def _identity(path):
    with open(path, encoding="ascii") as stream:
        return stream.read(256).strip()


def verify_host():
    if os.geteuid() != 0:
        _fail("driver requires root")
    machine_id = _identity("/etc/machine-id")
    hostname = socket.gethostname()
    if machine_id in PROTECTED_MACHINE_IDS:
        _fail("this is a protected host")
    if machine_id != PINS["machine_id"]:
        _fail("host machine_id does not match pin")
    if hostname != PINS["node_name"]:
        _fail("host name does not match pin")


# --- request -----------------------------------------------------------------


def load_request(path):
    if not os.path.isabs(path) or path != os.path.normpath(path):
        _fail("request path must be absolute and normalized")
    handle = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        info = os.fstat(handle)
        if not stat.S_ISREG(info.st_mode):
            _fail("request must be a regular file")
        if info.st_size > MAX_REQUEST_BYTES:
            _fail("request file is too large")
        if stat.S_IMODE(info.st_mode) & 0o077:
            _fail("request file must not be group- or world-accessible")
        raw = os.read(handle, MAX_REQUEST_BYTES).decode("utf-8")
    finally:
        os.close(handle)
    document = json.loads(raw, object_pairs_hook=_unique_object)
    if not isinstance(document, dict) or set(document) != REQUEST_FIELDS:
        _fail("request schema must contain exactly the suite's fields")
    if document["scenario"] not in SCENARIOS or document["phase"] not in PHASES:
        _fail("unsupported scenario or phase")
    if not DEPLOYMENT_RE.match(str(document["deployment_id"])):
        _fail("deployment_id must be a bounded safe identifier")
    if document["scenario"] == "all" and document["phase"] != "restore":
        _fail("the all scenario only supports restore")
    return document


def volumes_of(request):
    resource = request["resource"]
    if not isinstance(resource, dict):
        _fail("storage_deletion requires a resource object")
    volumes = resource.get("volumes")
    if not isinstance(volumes, list) or not 1 <= len(volumes) <= 16:
        _fail("storage_deletion requires a bounded nonempty volume list")
    handles = []
    for volume in volumes:
        if not isinstance(volume, dict):
            _fail("each volume must be an object")
        handle = volume.get("volume_handle")
        if not UUID_RE.match(handle or ""):
            _fail("volume_handle must be a canonical lowercase UUID")
        if volume.get("csi_driver") != "topolvm.io":
            _fail("only topolvm.io volumes are in scope")
        if handle in PINS["excluded_volume_handles"]:
            _fail("volume_handle is an excluded retained volume")
        handles.append(handle)
    if len(set(handles)) != len(handles):
        _fail("duplicate volume handles in request")
    return handles


# --- host operations ---------------------------------------------------------


def _run(argv, timeout=NFT_TIMEOUT_SECONDS, check=True):
    try:
        result = subprocess.run(
            argv,
            capture_output=True,
            text=True,
            timeout=timeout,
            env={"PATH": "/usr/sbin:/usr/bin:/sbin:/bin", "LC_ALL": "C"},
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        _fail("%s failed: %s" % (os.path.basename(argv[0]), type(exc).__name__))
    if check and result.returncode:
        _fail("%s refused (exit %d): %s" % (os.path.basename(argv[0]), result.returncode, result.stderr[:512]))
    return result


def state_dir(deployment_id):
    path = os.path.join(STATE_ROOT, deployment_id)
    os.makedirs(path, mode=0o700, exist_ok=True)
    os.chmod(path, 0o700)
    return path


def verify_logical_volume(handle):
    """The LV must exist in the pinned VG. Never fault a volume we cannot name exactly."""
    result = _run([LVS, "--noheadings", "-o", "lv_name,vg_name", "--separator", ",",
                   "%s/%s" % (PINS["vg_name"], handle)], timeout=10)
    line = result.stdout.strip()
    if line != "%s,%s" % (handle, PINS["vg_name"]):
        _fail("logical volume does not resolve to exactly the pinned volume group")
    device = "/dev/%s/%s" % (PINS["vg_name"], handle)
    if not stat.S_ISBLK(os.stat(device).st_mode):
        _fail("logical volume path is not a block device")
    return device


def hold_volume(deployment_id, handle):
    """Fork a detached holder keeping the LV busy, self-releasing after max_hold_seconds."""
    device = verify_logical_volume(handle)
    directory = state_dir(deployment_id)
    pidfile = os.path.join(directory, "storage-%s.pid" % handle)
    if os.path.exists(pidfile):
        return  # already held; apply is idempotent within one deployment
    if os.fork():
        # Wait for the child to signal readiness by creating the pidfile.
        for _ in range(100):
            if os.path.exists(pidfile):
                return
            time.sleep(0.05)
        _fail("holder did not confirm it opened the volume")
    # Child: detach, open the device, hold it for a bounded window, then exit.
    os.setsid()
    descriptor = os.open(device, os.O_RDONLY | os.O_CLOEXEC)
    with open(pidfile, "w") as stream:
        stream.write(str(os.getpid()))
    os.chmod(pidfile, 0o600)

    def release(_signum=None, _frame=None):
        os.close(descriptor)
        try:
            os.unlink(pidfile)
        except OSError:
            pass
        os._exit(0)

    signal.signal(signal.SIGTERM, release)
    time.sleep(PINS["max_hold_seconds"])
    release()


def release_volumes(deployment_id):
    directory = os.path.join(STATE_ROOT, deployment_id)
    if not os.path.isdir(directory):
        return
    for name in sorted(os.listdir(directory)):
        if not name.startswith("storage-") or not name.endswith(".pid"):
            continue
        path = os.path.join(directory, name)
        try:
            with open(path) as stream:
                pid = int(stream.read().strip())
        except (OSError, ValueError):
            os.unlink(path)
            continue
        try:
            os.kill(pid, signal.SIGTERM)
        except OSError as exc:
            if exc.errno != errno.ESRCH:
                _fail("could not signal the volume holder")
        for _ in range(200):
            try:
                os.kill(pid, 0)
            except OSError:
                break
            time.sleep(0.05)
        else:
            _fail("volume holder did not release within its bounded window")
        if os.path.exists(path):
            os.unlink(path)


def table_name(deployment_id):
    digest = uuid.uuid5(uuid.NAMESPACE_URL, "symphony-qualification-fault/" + deployment_id).hex
    return "symphony_qual_fault_" + digest


def partition_present(deployment_id):
    result = _run([NFT, "--json", "list", "tables"], check=False)
    if result.returncode:
        return False
    try:
        objects = json.loads(result.stdout)["nftables"]
    except (ValueError, KeyError, TypeError):
        _fail("nft returned malformed JSON")
    name = table_name(deployment_id)
    return any(
        isinstance(obj.get("table"), dict)
        and obj["table"].get("family") == "inet"
        and obj["table"].get("name") == name
        for obj in objects
    )


def apply_partition(deployment_id):
    if partition_present(deployment_id):
        return
    name = table_name(deployment_id)
    members = ", ".join(PINS["cluster_cidrs"])
    management = PINS["management_ipv4"]
    # Management SSH is accepted first so the host stays reachable for restoration.
    batch = f"""
table inet {name} {{
  set cluster {{
    type ipv4_addr
    flags interval
    elements = {{ {members} }}
  }}
  chain input {{
    type filter hook input priority -150; policy accept;
    ip daddr {management} tcp dport 22 accept
    ip saddr @cluster drop
  }}
  chain output {{
    type filter hook output priority -150; policy accept;
    ip saddr {management} tcp sport 22 accept
    ip daddr @cluster drop
  }}
}}
"""
    result = subprocess.run(
        [NFT, "-f", "-"],
        input=batch,
        capture_output=True,
        text=True,
        timeout=NFT_TIMEOUT_SECONDS,
        env={"PATH": "/usr/sbin:/usr/bin:/sbin:/bin", "LC_ALL": "C"},
        check=False,
    )
    if result.returncode:
        _fail("nft refused the partition table (exit %d): %s" % (result.returncode, result.stderr[:512]))
    arm_partition_release(deployment_id)


def arm_partition_release(deployment_id):
    """Independent bounded restore, so a dead caller cannot strand the partition."""
    directory = state_dir(deployment_id)
    pidfile = os.path.join(directory, "partition.pid")
    if os.path.exists(pidfile):
        return
    if os.fork():
        return
    os.setsid()
    with open(pidfile, "w") as stream:
        stream.write(str(os.getpid()))
    os.chmod(pidfile, 0o600)
    try:
        time.sleep(PINS["max_hold_seconds"])
        remove_partition(deployment_id)
    finally:
        try:
            os.unlink(pidfile)
        except OSError:
            pass
        os._exit(0)


def remove_partition(deployment_id):
    if partition_present(deployment_id):
        _run([NFT, "delete", "table", "inet", table_name(deployment_id)], check=True)
    directory = os.path.join(STATE_ROOT, deployment_id)
    pidfile = os.path.join(directory, "partition.pid")
    if os.path.exists(pidfile):
        try:
            with open(pidfile) as stream:
                pid = int(stream.read().strip())
            if pid != os.getpid():
                os.kill(pid, signal.SIGKILL)
        except (OSError, ValueError):
            pass
        try:
            os.unlink(pidfile)
        except OSError:
            pass


# --- dispatch ----------------------------------------------------------------


def dispatch(request):
    deployment_id = request["deployment_id"]
    scenario, phase = request["scenario"], request["phase"]
    if scenario == "storage_deletion":
        if phase == "apply":
            for handle in volumes_of(request):
                hold_volume(deployment_id, handle)
        else:
            release_volumes(deployment_id)
    elif scenario == "node_disconnection":
        if phase == "apply":
            apply_partition(deployment_id)
        else:
            remove_partition(deployment_id)
    else:  # all / restore: leave no fault behind, in either subsystem
        remove_partition(deployment_id)
        release_volumes(deployment_id)


def main(argv=None):
    parser = argparse.ArgumentParser(description="Qualification physical-fault driver", allow_abbrev=False)
    parser.add_argument("--request", required=True)
    args = parser.parse_args(argv)
    try:
        validate_pins()
        verify_host()
        request = load_request(args.request)
        # Restores must finish even if the suite is being torn down around us.
        previous = {s: signal.signal(s, signal.SIG_IGN) for s in (signal.SIGTERM, signal.SIGINT)} \
            if request["phase"] == "restore" else {}
        try:
            dispatch(request)
        finally:
            for signum, handler in previous.items():
                signal.signal(signum, handler)
        sys.stdout.write(json.dumps({"applied": True}) + "\n")
        sys.stdout.flush()
        return 0
    except (DriverError, OSError, ValueError, KeyError) as exc:
        # Never echo the request: it carries credential references.
        sys.stderr.write(json.dumps({"event": "refusal", "message": str(exc)[:500]}) + "\n")
        sys.stderr.flush()
        return 2


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/python3
#
# Copyright (c) 2026 Wind River Systems, Inc.
#
# SPDX-License-Identifier: Apache-2.0
#
"""Simplex to duplex etcd conversion, controller-0 side.

The platform performs this conversion in two phases, and the etcd work has to
follow them:

  system host-lock controller-0
  <operator adds the controller addresses to the address pools>
  system modify -m duplex            <- --relocate runs here
  system host-unlock controller-0    <- --certificates runs here, at unlock

The addresses are added before the mode change rather than after it. That
command flips system_mode and fires the runtime manifests in the same
conductor call, and platform::drbd::params derives its peer address from
controller-1's management address as soon as the mode is duplex, so a manifest
that runs before the addresses exist cannot compile.

--relocate still uses only the floating address, and the certificate work
still runs at unlock, where it is idempotent and safe to repeat.

  --relocate      Move the existing member's data from local disk to the DRBD
                  mount and leave the etcd-fixed unit stopped and disabled.
                  The member keeps its name and its peer URL, so the raft
                  membership record does not change and no quorum write is
                  needed. Uses the floating address only.

  --certificates  Reissue the etcd server and apiserver client certificates
                  with the controller unit addresses in the SAN set. This has
                  to lead the new members: a member that binds an address its
                  certificate does not cover cannot complete mutual TLS.
                  Skips when the SAN set already covers them, so it is safe
                  on every unlock. kube-cert-rotation.sh only reissues within
                  15 days of expiry, so its helper cannot be reused here.
"""

import argparse
import logging
import os
import time
import shutil
import subprocess
import sys

# pylint: disable=unused-argument

ETC_ETCD_DIR = "/etc/etcd"
CA_CRT = os.path.join(ETC_ETCD_DIR, "ca.crt")
# etcd_cert_sans.py is the shared cert-SAN implementation, installed by the
# /usr/local/bin by Makefile. Reused here so certificate handling has a single
# implementation across the migration and the upgrade-activate path.
ETCD_CERT_SANS = "/usr/local/bin/etcd_cert_sans.py"

FIXED_BASEDIR = "/opt/etcd-fixed"
PEER_PORT = "2380"
PORT = "2379"
# Where the fixed member advertises while controller-0 unit address does not
# exist yet. Both members are on this host during the conversion, so the peer
# can reach it, and the server certificate already covers loopback.
LOOPBACK = "127.0.0.1"
FLOATING_BASEDIR = "/opt/etcd"
# The environment files the two members are started with. The fixed one
# is read to find where the incumbent is already listening, which is the
# address the renamed member keeps.
FIXED_ENV = "/etc/default/etcd-fixed"
FLOATING_ENV = "/etc/default/etcd"
HOSTS = "/etc/hosts"
CONTROLLERS = ("controller-0", "controller-1")
ETCDCTL_COMMAND_TIMEOUT = "5s"
ETCDCTL_DIAL_TIMEOUT = "2s"


LOG = logging.getLogger("etcd-duplex-migration")
logging.basicConfig(level=logging.INFO,
                    format="%(name)s: %(message)s")


def run(cmd, check=True):
    proc = subprocess.run(  # pylint: disable=subprocess-run-check
        cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        universal_newlines=True)
    if check and proc.returncode != 0:
        raise RuntimeError("%s failed: %s" % (" ".join(cmd),
                                              proc.stderr.strip()))
    return proc


def unit_address(hostname):
    """Return a controller's cluster-host address from /etc/hosts.

    The same source kube-cert-rotation.sh uses, so that the SAN set written
    here and the one written at renewal cannot disagree.
    """
    target = "%s-cluster-host" % hostname
    with open(HOSTS, encoding="utf-8") as handle:
        for line in handle:
            fields = line.split()
            if len(fields) >= 2 and fields[1] == target:
                return fields[0]
    return None


def handle_certificates(args):
    """Ensure the etcd certificates name the controller unit addresses.

    Delegates to etcd_cert_sans.py, the single implementation shared with the
    upgrade-activate path (platform::etcd::certs::runtime). That script unions
    the given addresses into the existing certificate's SANs, signs with the
    existing private key -- so the key is never replaced -- and is a no-op when
    the addresses are already present. Keeping one implementation avoids the
    two diverging on key handling or keyUsage depending on which ran last.
    """
    addresses = [unit_address(name) for name in CONTROLLERS]
    missing = [name for name, addr in zip(CONTROLLERS, addresses)
               if addr is None]
    if missing:
        # The addresses are added to the pools between the mode change and
        # the unlock. Before that there is nothing to add to the SAN set.
        LOG.info("no cluster-host entry for %s yet; leaving the certificate "
                 "alone", ", ".join(missing))
        return 0

    cmd = [ETCD_CERT_SANS] + addresses
    proc = run(cmd, check=False)
    if proc.stdout.strip():
        LOG.info("%s", proc.stdout.strip())
    if proc.returncode != 0:
        LOG.error("%s failed: %s", ETCD_CERT_SANS, proc.stderr.strip())
        return 1
    return 0


def handle_relocate(args):
    member = args.member_name

    # Which way the data moves. The conversion moves it onto DRBD so the
    # floating instance can own it; the upgrade from a release that had no
    # fixed member moves it the other way, onto local disk, because there the
    # single member becomes the fixed instance.
    to_fixed = getattr(args, "relocate_to_fixed", False)
    if to_fixed:
        source = os.path.join(FLOATING_BASEDIR, "db", "%s.etcd" % member)
        target = os.path.join(FIXED_BASEDIR, "db", "%s.etcd" % member)
    else:
        source = os.path.join(FIXED_BASEDIR, "db", "%s.etcd" % member)
        target = os.path.join(FLOATING_BASEDIR, "db", "%s.etcd" % member)

    if os.path.isdir(os.path.join(target, "member")):
        LOG.info("%s already holds the member data; nothing to relocate", target)
        return 0

    if not os.path.isdir(source):
        raise RuntimeError("no member data at %s" % source)

    # Whichever end of the move is on DRBD has to actually be mounted, or the
    # data would be written into, or read from, the mount point's empty
    # underlying directory.
    if not os.path.ismount(FLOATING_BASEDIR):
        raise RuntimeError(
            "%s is not a mount point; the DRBD resource must be promoted and "
            "mounted before the member is relocated" % FLOATING_BASEDIR)

    # Stop the member before its data moves. It is the only member in the
    # cluster, so the cluster is unavailable until it is started again -- the
    # same window any single-member cluster has while its process restarts.
    # The controller is locked at this point in the procedure.
    # Stop pmon monitoring. This prevents service restart.
    LOG.info("stopping the member before its data moves")
    run(["/usr/local/sbin/pmon-stop", "etcd-fixed"], check=False)
    run(["/usr/bin/systemctl", "stop", "etcd-fixed"], check=False)
    if to_fixed:
        # Coming off DRBD the running instance is the floating one, which
        # Service Manager owns and which is started through its init script.
        run(["/usr/bin/systemctl", "stop", "etcd"], check=False)
        run(["/etc/init.d/etcd", "stop"], check=False)

    os.makedirs(os.path.dirname(target), exist_ok=True)
    LOG.info("moving %s to %s", source, target)
    shutil.move(source, target)

    if to_fixed:
        # The data is now where the fixed instance expects it, and that
        # instance is what serves this member from here on.
        run(["/usr/bin/systemctl", "enable", "--now", "etcd-fixed"],
            check=False)
        # Resume pmon monitoring.
        run(["/usr/local/sbin/pmon-start", "etcd-fixed"], check=False)
    else:
        # The unit is re-rendered for fixed-0 at unlock, and fixed-0 owns a
        # different data directory. Leave it stopped and disabled so that
        # nothing starts it against the relocated data in the meantime.
        run(["/usr/bin/systemctl", "disable", "etcd-fixed"], check=False)
    LOG.info("relocation complete")
    return 0


def etcdctl_certs():
    return ["--cacert", CA_CRT,
            "--cert", os.path.join(ETC_ETCD_DIR, "etcd-client.crt"),
            "--key", os.path.join(ETC_ETCD_DIR, "etcd-client.key")]


def etcdctl_timeouts(command_timeout=None, dial_timeout=None):
    """Return timeout flags for etcdctl commands."""
    ct = command_timeout or ETCDCTL_COMMAND_TIMEOUT
    dt = dial_timeout or ETCDCTL_DIAL_TIMEOUT
    return ["--command-timeout", ct, "--dial-timeout", dt]


def local_revision():
    """The revision the running member is currently at, or None."""
    proc = run(["/usr/bin/etcdctl", "--endpoints", "https://127.0.0.1:2379"] +
               etcdctl_timeouts() + etcdctl_certs() +
               ["endpoint", "status", "-w", "fields"], check=False)
    if proc.returncode != 0:
        LOG.error("etcdctl endpoint status failed: %s", proc.stderr.strip())
        return None
    for line in proc.stdout.splitlines():
        if line.startswith('"Revision"'):
            try:
                return int(line.split(":", 1)[1].strip())
            except ValueError:
                LOG.error("failed to parse revision from: %s", line)
                return None
    return None


def snapshot_revision(path):
    """The revision recorded inside a snapshot file, or None."""
    proc = run(["/usr/bin/etcdutl", "snapshot", "status", path,
                "-w", "fields"], check=False)
    if proc.returncode != 0:
        LOG.error("etcdutl snapshot status failed: %s", proc.stderr.strip())
        return None
    for line in proc.stdout.splitlines():
        if line.startswith('"Revision"'):
            try:
                return int(line.split(":", 1)[1].strip())
            except ValueError:
                return None
    return None


def sysinv_unit_address(hostname="controller-0", network="cluster-host"):
    """A controller's unit address for a network, straight from sysinv.

    This is the only source that is correct while the conversion runs. The
    address pools are updated before the mode change -- the playbook requires
    that ordering -- but the runtime manifest fires in the same conductor call
    and reads a hieradata snapshot written before it, and /etc/hosts is
    rewritten later still. sysinv answers from postgres, so it is available
    even with the controller locked and etcd unavailable.
    """
    column = 9 if hostname.endswith("-0") else 10
    script = (
        "source /etc/platform/openrc >/dev/null 2>&1 || exit 1; "
        "system addrpool-list --nowrap 2>/dev/null | "
        "awk -F'|' '/%s/{gsub(/ /,\"\",$%d); print $%d}'" % (network, column, column)
    )
    proc = run(["/bin/bash", "-c", script], check=False)
    if proc.returncode != 0:
        LOG.error("sysinv addrpool-list for %s/%s failed: %s",
                  hostname, network, proc.stderr.strip())
        return None
    for line in proc.stdout.splitlines():
        value = line.strip()
        if value and value.lower() not in ("none", "no"):
            return value
    return None


def has_host(url):
    """True when a URL carries an actual host, not https://:2380."""
    if not url:
        return False
    remainder = url.split("//", 1)[-1]
    host = remainder.rsplit(":", 1)[0]
    return bool(host.strip("[]").strip())


def incumbent_peer_url():
    """Where the member being renamed is already listening.

    Read from the environment file the member was started with, so the renamed
    member keeps exactly the address the incumbent had. Nothing else is
    available at this point in the conversion, and nothing else is needed.
    """
    values = {}
    try:
        with open(FIXED_ENV, encoding="utf-8") as handle:
            for line in handle:
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    key, value = line.split("=", 1)
                    values[key.strip()] = value.strip().strip('"')
    except (IOError, OSError):
        return None
    for key in ("ETCD_INITIAL_ADVERTISE_PEER_URLS", "ETCD_LISTEN_PEER_URLS"):
        url = values.get(key, "").split(",")[0].strip()
        if has_host(url):
            return url
    return None


def resolve_peer_url(supplied, port):
    """Where the renamed member should advertise itself: where it already is.

    A rename changes the name, not the location. The incumbent's own address
    is therefore the right answer and the only one available -- controller-0's
    unit address does not exist yet at this point in the conversion and cannot
    be made to, because sysinv holds the cluster-host pool read-only until the
    mode is duplex, and the mode change is what fires this manifest.

    The move to the unit address belongs at unlock, where that address exists,
    and is already implemented there for the bootstrap case.
    """
    address = sysinv_unit_address()
    if address:
        LOG.info("controller-0 cluster-host address from sysinv: %s", address)
        return "https://%s:%s" % (address, port)

    # The unit address does not exist yet: the cluster-host pool is updated
    # after the mode change, and the mode change is what fires this manifest.
    # Loopback carries the member until then. Both members are on this host
    # for the whole of that window, so the peer can reach it, and it is moved
    # to the unit address at unlock -- before controller-1 exists and could
    # need to reach it from elsewhere.
    LOG.info("controller-0 unit address does not exist yet; advertising %s until "
             "unlock moves it", LOOPBACK)
    return "https://%s:%s" % (LOOPBACK, port)


def sysinv_floating_address(network="cluster-host"):
    """The floating address for a network, from sysinv."""
    script = (
        "source /etc/platform/openrc >/dev/null 2>&1 || exit 1; "
        "system addrpool-list --nowrap 2>/dev/null | "
        "awk -F'|' '/%s/{gsub(/ /,\"\",$8); print $8}'" % network
    )
    proc = run(["/bin/bash", "-c", script], check=False)
    if proc.returncode != 0:
        LOG.error("sysinv addrpool-list for %s failed: %s",
                  network, proc.stderr.strip())
        return None
    for line in proc.stdout.splitlines():
        value = line.strip()
        if value and value.lower() not in ("none", "no"):
            return value
    return None


def rewrite_env_addresses(path, replacements):
    """Replace address-bearing values in an etcd environment file.

    Only the named keys are touched. Everything else the template wrote --
    certificates, quota, the data directory -- is left exactly as it is.
    """
    if not os.path.exists(path):
        LOG.info("%s does not exist; nothing to correct", path)
        return False
    with open(path, encoding="utf-8") as handle:
        lines = handle.read().splitlines()
    changed = False
    out = []
    for line in lines:
        key = line.split("=", 1)[0] if "=" in line else ""
        if key in replacements:
            new = '%s="%s"' % (key, replacements[key])
            if new != line:
                LOG.info("  %s: %s -> %s", key, line.split("=", 1)[1], replacements[key])
                changed = True
                line = new
        out.append(line)
    if changed:
        with open(path, "w", encoding="utf-8") as handle:
            handle.write("\n".join(out) + "\n")
    return changed


def wait_for_member(endpoint, tries=30, delay=2):
    """Wait until a member answers, so the next raft write can succeed."""
    for _ in range(tries):
        proc = run(["/usr/bin/etcdctl", "--endpoints", endpoint] +
                   etcdctl_timeouts() + etcdctl_certs() + ["endpoint", "health"], check=False)
        if proc.returncode == 0:
            return True
        time.sleep(delay)
    return False


def handle_finalize_conversion(args):
    """Fix the addresses, then start fixed-0 and let the floating member join."""
    fixed_name = args.to_name
    floating_name = args.member_name
    port, peer_port = PORT, PEER_PORT

    unit = sysinv_unit_address() or LOOPBACK
    floating = sysinv_floating_address() or unit_address("controller-0")
    if not floating:
        raise RuntimeError("cannot determine the cluster-host floating address")
    LOG.info("fixed member on %s, floating member on %s", unit, floating)
    if unit == floating:
        raise RuntimeError(
            "the fixed and floating members would share the address %s; "
            "the address pool has not been split" % unit)

    fixed_peer = "https://%s:%s" % (unit, peer_port)
    fixed_client = "https://%s:%s" % (unit, port)
    float_peer = "https://%s:%s" % (floating, peer_port)
    float_client = "https://%s:%s" % (floating, port)

    LOG.info("correcting %s", FIXED_ENV)
    rewrite_env_addresses(FIXED_ENV, {
        "ETCD_LISTEN_PEER_URLS": fixed_peer,
        "ETCD_INITIAL_ADVERTISE_PEER_URLS": fixed_peer,
        "ETCD_LISTEN_CLIENT_URLS": "%s,https://127.0.0.1:%s" % (fixed_client, port),
        "ETCD_ADVERTISE_CLIENT_URLS": fixed_client,
        "ETCD_INITIAL_CLUSTER": "%s=%s" % (fixed_name, fixed_peer),
    })

    LOG.info("correcting %s", FLOATING_ENV)
    rewrite_env_addresses(FLOATING_ENV, {
        "ETCD_LISTEN_PEER_URLS": float_peer,
        "ETCD_INITIAL_ADVERTISE_PEER_URLS": float_peer,
        "ETCD_LISTEN_CLIENT_URLS": float_client,
        "ETCD_ADVERTISE_CLIENT_URLS": float_client,
        "ETCD_INITIAL_CLUSTER": "%s=%s,%s=%s"
                                % (fixed_name, fixed_peer, floating_name, float_peer),
        "ETCD_INITIAL_CLUSTER_STATE": "existing",
    })

    # fixed-0 first and alone: it holds the data and is the whole cluster
    # until the floating member is registered.
    LOG.info("starting %s", fixed_name)
    run(["/usr/bin/systemctl", "enable", "--now", "etcd-fixed"], check=False)
    run(["/usr/local/sbin/pmon-start", "etcd-fixed"], check=False)
    if not wait_for_member(fixed_client):
        raise RuntimeError("%s did not become healthy at %s"
                           % (fixed_name, fixed_client))
    LOG.info("%s is serving", fixed_name)

    # Registering the floating member is a raft write, so it can only happen
    # once the seed is serving.
    members = run(["/usr/bin/etcdctl", "--endpoints", fixed_client] +
                  etcdctl_timeouts() + etcdctl_certs() + ["member", "list", "-w", "simple"],
                  check=False)
    if floating_name in members.stdout:
        LOG.info("%s is already a member", floating_name)
    else:
        LOG.info("registering %s at %s", floating_name, float_peer)
        run(["/usr/bin/etcdctl", "--endpoints", fixed_client] +
            etcdctl_timeouts() + etcdctl_certs() +
            ["member", "add", floating_name, "--peer-urls=%s" % float_peer])

    # The floating member joins a cluster that already exists; its own
    # configuration says so.
    LOG.info("starting %s", floating_name)
    run(["/etc/init.d/etcd", "start"], check=False)
    if not wait_for_member(float_client):
        LOG.info("WARNING: %s has not become healthy yet at %s; Service Manager "
                 "will keep trying", floating_name, float_client)
    else:
        LOG.info("%s is serving", floating_name)

    LOG.info("conversion complete: %s seeds, %s joined", fixed_name, floating_name)
    return 0


def handle_rename_to_fixed(args):
    """Re-establish the single member under the fixed name, keeping its data.

    Leaves the service stopped. Puppet renders /etc/default/etcd-fixed for the
    new name and starts it; starting here would race that file.
    """
    old_name = args.member_name
    new_name = args.to_name
    peer_url = args.peer_url

    source = os.path.join(FIXED_BASEDIR, "db", "%s.etcd" % old_name)
    target = os.path.join(FIXED_BASEDIR, "db", "%s.etcd" % new_name)
    snapshot = os.path.join(FIXED_BASEDIR, "db", "%s-rename.snapshot" % new_name)

    if os.path.isdir(os.path.join(target, "member")):
        LOG.info("%s already holds the member data; nothing to rename", target)
        return 0

    if not os.path.isdir(os.path.join(source, "member")):
        raise RuntimeError("no member data at %s" % source)

    # Resolve rather than trust: what puppet passes here comes from hieradata
    # that has not caught up with the address pools yet, and an address it
    # cannot resolve arrives as https://:2380.
    peer_url = resolve_peer_url(peer_url, PEER_PORT)
    LOG.info("%s will advertise %s", new_name, peer_url)

    # Read where the member is before anything is taken, so the comparison
    # afterwards is against the live cluster rather than against the snapshot
    # alone.
    before = local_revision()
    LOG.info("member %s is at revision %s", old_name, before)

    if os.path.exists(snapshot):
        os.remove(snapshot)

    LOG.info("taking a snapshot of %s", old_name)
    run(["/usr/bin/etcdctl", "--endpoints", "https://127.0.0.1:2379"] +
        etcdctl_timeouts(command_timeout="60s") + etcdctl_certs() + ["snapshot", "save", snapshot])

    # Back to back with the snapshot: every commit in between is lost.
    # Stop pmon monitoring. This prevents service restart.
    LOG.info("stopping %s", old_name)
    run(["/usr/local/sbin/pmon-stop", "etcd-fixed"], check=False)
    run(["/usr/bin/systemctl", "stop", "etcd-fixed"], check=False)

    taken = snapshot_revision(snapshot)
    LOG.info("snapshot holds revision %s", taken)
    if before is not None and taken is not None and taken < before:
        LOG.info("WARNING: %d revisions were committed between reading the "
                 "revision and taking the snapshot and are not in it", before - taken)

    LOG.info("restoring the snapshot as %s into %s", new_name, target)
    run(["/usr/bin/etcdutl", "snapshot", "restore", snapshot,
         "--name", new_name,
         "--data-dir", target,
         "--initial-cluster", "%s=%s" % (new_name, peer_url),
         "--initial-cluster-token", "etcd-cluster",
         "--initial-advertise-peer-urls", peer_url])

    if not os.path.isdir(os.path.join(target, "member")):
        raise RuntimeError("restore produced no member directory at %s"
                           % target)

    # Keep the original. If the restored member turns out wrong, this is what
    # is left to start.
    kept = "%s.pre-rename" % source
    if os.path.exists(kept):
        shutil.rmtree(kept, ignore_errors=True)
    shutil.move(source, kept)
    LOG.info("previous data directory kept at %s", kept)

    os.remove(snapshot)
    LOG.info("rename complete; %s is now the member and holds the data", new_name)
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--certificates", action="store_true",
                       help="reissue the etcd certificates with the "
                            "controller unit addresses")
    group.add_argument("--relocate", action="store_true",
                       help="move the existing member's data to DRBD storage")
    group.add_argument("--finalize-conversion", action="store_true",
                       dest="finalize_conversion",
                       help="correct the addresses puppet rendered from stale "
                            "hieradata, then start the fixed member and let "
                            "the floating member join it")
    group.add_argument("--rename-to-fixed", action="store_true",
                       dest="rename_to_fixed",
                       help="re-establish the single member under the fixed "
                            "name, keeping its data, so that the floating "
                            "member can join it")
    group.add_argument("--relocate-to-fixed", action="store_true",
                       dest="relocate_to_fixed",
                       help="move the existing member's data off DRBD onto "
                            "local disk, for the upgrade from a release with "
                            "no fixed member")
    parser.add_argument("--floating-address",
                        help="cluster-host floating address")
    parser.add_argument("--to-name", default="fixed-0",
                        help="the name to re-establish the member under")
    parser.add_argument("--peer-url", default=None,
                        help="peer URL the renamed member advertises")
    parser.add_argument("--member-name", default="controller",
                        help="name of the member being relocated")
    args = parser.parse_args()

    try:
        if args.certificates:
            return handle_certificates(args)
        if getattr(args, 'finalize_conversion', False):
            return handle_finalize_conversion(args)
        if getattr(args, 'rename_to_fixed', False):
            return handle_rename_to_fixed(args)
        return handle_relocate(args)
    except Exception as exc:  # noqa: BLE001  pylint: disable=broad-except
        LOG.error("%s: %s", type(exc).__name__, exc)
        return 1


if __name__ == "__main__":
    sys.exit(main())

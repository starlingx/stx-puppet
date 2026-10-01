#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
#
# Copyright (c) 2025-2026 Wind River Systems, Inc.
#
# Safely configure the number of SR-IOV Virtual Functions (VFs) on a Physical
# Function (PF)
#
# Why this exists:
#   The raw "echo 0 > sriov_numvfs" tears down every VF. If a VF is bound to
#   vfio-pci and a userspace process  still holds its /dev/vfio/<group> fd open,
#   the write blocks indefinitely in the kernel (vfio_unregister_group_dev).
#   During an --auto subcloud restore this manifested as an ~80 minute hang
#   and an opaque Ansible async timeout, failing the whole restore.
#
# Behaviour:
#   1) Receives the interface name and the desired number of VFs.
#   2) Reads the current value from /sys/class/net/<ifname>/device/sriov_numvfs.
#        - If it already equals the requested number -> exit SUCCESS (no change).
#        - Otherwise, check whether any VF is bound to vfio-pci AND held open by
#          a process (i.e. a reconfigure would tear those VFs down and hang):
#            - if none are in use  -> apply the new value and exit SUCCESS.
#            - if any are in use   -> do NOT touch sysfs and exit ERROR.
#   Successes and failures are logged to /var/log/daemon.log
#
# Exit codes:
#   0  SUCCESS  - value already correct, or successfully reconfigured.
#   1  ERROR    - a VF is bound to vfio-pci and held open (reconfigure unsafe),
#                 or the write / validation failed, or bad arguments / no PF.
#
# Intended use inside the ifcfg pre-up hook, e.g.:
#     pre-up /usr/local/bin/configure_sriov_numvfs.py --pf ens1f0 --num-vfs 8

import argparse
import errno
import logging
import logging.handlers
import os
import re
import sys
import time

SYS_CLASS_NET = "/sys/class/net"
SYS_BUS_PCI_DEVICES = "/sys/bus/pci/devices"
DEV_VFIO = "/dev/vfio"

TAG = "configure_sriov_numvfs"
PREFIX = "[network]"

# A "holder" is a (pid, comm, cmdline) tuple for a process holding a VF's
# /dev/vfio/<group> fd open. A "VF in use" record is a dict with keys:
#   {"bdf", "iommu_group", "vfio_node", "holders"}.

_logger = None


def setup_logging():
    """Configure logging to syslog (daemon facility -> daemon.log) + stderr."""
    global _logger  # pylint: disable=global-statement
    logger = logging.getLogger(TAG)
    logger.setLevel(logging.INFO)
    logger.propagate = False

    # stderr handler (visible in the ifup/playbook output).
    stream = logging.StreamHandler(sys.stderr)
    stream.setFormatter(logging.Formatter("%(message)s"))
    logger.addHandler(stream)

    # syslog handler -> routed by syslog-ng/rsyslog to daemon.log.
    try:
        syslog = logging.handlers.SysLogHandler(
            address="/dev/log",
            facility=logging.handlers.SysLogHandler.LOG_DAEMON,
        )
        # syslog message body; the daemon captures timestamp/host/tag itself.
        syslog.setFormatter(logging.Formatter("%s[%%(process)d]: %%(message)s" % TAG))
        logger.addHandler(syslog)
    except OSError:
        # /dev/log may be unavailable (e.g. early boot / container). Keep going
        # with stderr only; not being able to reach syslog must not break the
        # network bring-up decision.
        pass

    _logger = logger
    return logger


def log_info(msg):
    assert _logger is not None
    _logger.info("%s %s", PREFIX, msg)


def log_error(msg):
    assert _logger is not None
    _logger.error("%s ERROR: %s", PREFIX, msg)


# ---------------------------------------------------------------------------
# sysfs / procfs helpers (self-contained; same approach as check_sriov_vf_inuse)
# ---------------------------------------------------------------------------

def resolve_basename_of_symlink(path):
    """Return os.path.basename(os.path.realpath(path)) or None if missing."""
    try:
        real = os.path.realpath(path)
    except OSError:
        return None
    if not os.path.exists(path) and not os.path.islink(path):
        return None
    return os.path.basename(real)


def pf_device_dir(pf):
    """Return the resolved PCI device dir for a PF net interface, or None."""
    dev_link = os.path.join(SYS_CLASS_NET, pf, "device")
    if not os.path.exists(dev_link):
        return None
    return os.path.realpath(dev_link)


def sriov_numvfs_path(pf):
    dev_dir = pf_device_dir(pf)
    if dev_dir is None:
        return None
    return os.path.join(dev_dir, "sriov_numvfs")


def read_int_file(path):
    try:
        with open(path, "r") as f:
            return int(f.read().strip())
    except (OSError, ValueError):
        return None


def list_vf_bdfs(pf):
    """Return a list of VF PCI addresses (BDF strings) for the PF, or None.

    Enumerated purely from sysfs via the virtfnN symlinks.
    """
    dev_dir = pf_device_dir(pf)
    if dev_dir is None:
        return None

    try:
        entries = os.listdir(dev_dir)
    except OSError:
        return None
    virtfns = sorted(
        (e for e in entries if re.fullmatch(r"virtfn\d+", e)),
        key=lambda e: int(e[len("virtfn"):]),
    )
    vfs = []
    for vf in virtfns:
        bdf = resolve_basename_of_symlink(os.path.join(dev_dir, vf))
        if bdf:
            vfs.append(bdf)
    return vfs


def driver_of_bdf(bdf):
    """Return the driver name bound to a PCI device, or None if unbound."""
    return resolve_basename_of_symlink(
        os.path.join(SYS_BUS_PCI_DEVICES, bdf, "driver")
    )


def iommu_group_of_bdf(bdf):
    """Return the IOMMU group number (str) for a PCI device, or None."""
    return resolve_basename_of_symlink(
        os.path.join(SYS_BUS_PCI_DEVICES, bdf, "iommu_group")
    )


def vfio_devnode_for_group(group):
    """Return the /dev/vfio/<group> path (does not check existence)."""
    return os.path.join(DEV_VFIO, str(group))


def _read_proc_cmdline(pid):
    try:
        with open(os.path.join("/proc", pid, "cmdline"), "rb") as f:
            raw = f.read()
    except OSError:
        return ""
    return raw.replace(b"\x00", b" ").decode("utf-8", "replace").strip()


def _read_proc_text(path):
    try:
        with open(path, "r") as f:
            return f.read().strip()
    except OSError:
        return ""


def find_holders_of_path(target_path):
    """Scan /proc/<pid>/fd for open fds resolving to target_path.

    Returns a list of (pid, comm, cmdline) tuples for processes we can inspect.
    """
    holders = []
    try:
        target_real = os.path.realpath(target_path)
    except OSError:
        target_real = target_path

    for pid in os.listdir("/proc"):
        if not pid.isdigit():
            continue
        fd_dir = os.path.join("/proc", pid, "fd")
        try:
            fds = os.listdir(fd_dir)
        except OSError:
            continue
        for fd in fds:
            fpath = os.path.join(fd_dir, fd)
            try:
                dest = os.readlink(fpath)
            except OSError:
                continue
            if dest == target_path or os.path.realpath(fpath) == target_real:
                comm = _read_proc_text(os.path.join("/proc", pid, "comm"))
                cmdline = _read_proc_cmdline(pid)
                holders.append((int(pid), comm, cmdline))
                break
    return holders


# ---------------------------------------------------------------------------
# in-use analysis
# ---------------------------------------------------------------------------

def find_vfs_in_use(pf):
    """Return the list of VFs that are bound to vfio-pci AND held open.

    Result is a list of dicts: {bdf, iommu_group, vfio_node, holders}.
    A non-empty list means reconfiguring sriov_numvfs would tear those VFs
    down and would block in the kernel while a holder keeps the fd open.
    """
    in_use = []
    bdfs = list_vf_bdfs(pf) or []
    for bdf in bdfs:
        if driver_of_bdf(bdf) != "vfio-pci":
            continue
        grp = iommu_group_of_bdf(bdf)
        node = vfio_devnode_for_group(grp) if grp is not None else None
        if node is None or not os.path.exists(node):
            continue
        holders = find_holders_of_path(node)
        if holders:
            in_use.append({
                "bdf": bdf,
                "iommu_group": grp,
                "vfio_node": node,
                "holders": holders,
            })
    return in_use


def describe_holders(in_use):
    parts = []
    for vf in in_use:
        who = "; ".join(
            "pid=%d comm=%s cmd=%r" % (p, c, cmd)
            for (p, c, cmd) in vf["holders"]
        )
        parts.append("VF %s (group %s, %s) held-by[%s]"
                     % (vf["bdf"], vf["iommu_group"], vf["vfio_node"], who))
    return " | ".join(parts)


# ---------------------------------------------------------------------------
# apply
# ---------------------------------------------------------------------------

def write_sriov_numvfs(pf, num_vfs, teardown_first, settle):
    """Write the requested VF count to sriov_numvfs.

    The kernel requires sriov_numvfs to be 0 before setting a new non-zero
    value. If the current value is non-zero and differs from the target,
    teardown_first controls whether we write 0 before the target. This
    teardown is only reached after we have confirmed no VF is held open, so
    it will not hang.

    Returns True on success, False on failure.
    """
    path = sriov_numvfs_path(pf)
    if path is None:
        log_error("PF '%s' has no sriov_numvfs sysfs entry" % pf)
        return False

    current = read_int_file(path)

    writing = num_vfs
    try:
        if teardown_first and current not in (None, 0) and num_vfs != 0:
            writing = "0"
            with open(path, "w") as f:
                f.write(writing)
            if settle > 0:
                time.sleep(settle)
            writing = num_vfs
        with open(path, "w") as f:
            f.write(str(writing))
    except OSError as e:
        log_error("failed writing %s to %s: %s" % (writing, path, e))
        return False

    # Verify the kernel accepted the value.
    result = read_int_file(path)
    if result != num_vfs:
        log_error("sriov_numvfs on %s is %s after write, expected %d"
                    % (pf, result, num_vfs))
        return False
    return True


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

def configure(pf, num_vfs, teardown_first=True, settle=0.0):
    """Perform the safe (re)configuration. Returns a process exit code."""
    path = sriov_numvfs_path(pf)
    if path is None:
        log_error("PF '%s' not found (no /sys/class/net/%s/device)" % (pf, pf))
        return 1

    current = read_int_file(path)
    if current is None:
        log_error("could not read current sriov_numvfs for PF '%s' (%s)"
                    % (pf, path))
        return 1

    # 1) No change requested -> success, do nothing.
    if current == num_vfs:
        log_info("PF %s sriov_numvfs already %d; no change needed" % (pf, num_vfs))
        return 0

    # 2) A change is needed. Make sure it is safe (no vfio VF held open).
    in_use = find_vfs_in_use(pf)
    if in_use:
        log_error(
            "PF %s sriov_numvfs change %d -> %d refused: %d VF(s) bound to "
            "vfio-pci and in use; reconfiguring would hang. %s"
            % (pf, current, num_vfs, len(in_use), describe_holders(in_use))
        )
        return 1

    # 3) Safe to apply.
    if write_sriov_numvfs(pf, num_vfs, teardown_first, settle):
        log_info("PF %s sriov_numvfs changed %d -> %d successfully"
                    % (pf, current, num_vfs))
        return 0

    log_error("PF %s sriov_numvfs change %d -> %d failed to apply"
                % (pf, current, num_vfs))
    return 1


def parse_args(argv):
    ap = argparse.ArgumentParser(
        description="Safely set SR-IOV VF count on a PF, refusing to reconfigure "
                    "when a VF is bound to vfio-pci and held open.")
    ap.add_argument("--pf", metavar="IFNAME", required=True,
                    help="PF interface name, e.g. ens1f0")
    ap.add_argument("--num-vfs", metavar="N", type=int, required=True,
                    help="desired number of VFs, e.g. 8")
    ap.add_argument("--no-teardown", action="store_true",
                    help="do not write 0 before the new non-zero value "
                         "(by default the PF is reset to 0 first, as the kernel "
                         "requires, but only after confirming no VF is in use)")
    ap.add_argument("--settle", metavar="SECS", type=float, default=0.0,
                    help="seconds to wait between writing 0 and the new value "
                         "(default 0)")
    return ap.parse_args(argv)


def main(argv):
    args = parse_args(argv)

    if args.num_vfs < 0:
        setup_logging()
        log_error("--num-vfs must be >= 0 (got %d)" % args.num_vfs)
        return 1

    setup_logging()
    return configure(
        args.pf,
        args.num_vfs,
        teardown_first=not args.no_teardown,
        settle=args.settle,
    )


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except KeyboardInterrupt:
        sys.exit(1)
    except OSError as e:
        if _logger is None:
            setup_logging()
        if e.errno == errno.EACCES:
            log_error("permission denied (run as root)")
        else:
            log_error(str(e))
        sys.exit(1)

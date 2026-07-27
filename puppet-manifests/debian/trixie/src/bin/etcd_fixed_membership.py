#!/usr/bin/python3
#
# Copyright (c) 2026 Wind River Systems, Inc.
#
# SPDX-License-Identifier: Apache-2.0
#
# pylint: disable=no-else-return
"""etcd fixed-instance membership helper.

Used by the etcd-fixed systemd service to coordinate fixed-member cluster
bootstrap and join operations.

  - ExecStartPre: Validates cluster membership and prepares the
    ETCD_INITIAL_CLUSTER definition required for startup.
  - ExecStartPost (--post-start): Performs post-start health validation.

During initial deployment, fixed-0 on controller-0 bootstraps the cluster as
the first member. After controller-1 is unlocked, fixed-1 is added to the
cluster through 'etcdctl member add'.

The helper is fully idempotent. Existing members are not re-added, and once
the local data directory has been initialized, membership modifications are
skipped on subsequent starts. This prevents disruptive reconfiguration and
avoids startup dependencies that could lead to boot-time deadlocks.
"""

import json
import logging
import os
import re
import subprocess
import sys
import time

LOG = logging.getLogger("etcd-fixed-membership")


ETCDCTL = "/usr/bin/etcdctl"
ENV_FILE = "/etc/default/etcd-fixed"
CA_FILE = "/etc/etcd/ca.crt"
CERT_FILE = "/etc/etcd/etcd-client.crt"
KEY_FILE = "/etc/etcd/etcd-client.key"
SERVER_CERT_FILE = "/etc/etcd/etcd-server.crt"
SERVER_KEY_FILE = "/etc/etcd/etcd-server.key"
TRIES = 30
SLEEP = 2
COMMAND_TIMEOUT = 10
DIAL_TIMEOUT = 2
LOOPBACK_ENDPOINT = "https://127.0.0.1:2379"
CLIENT_PORT = "2379"
PEER_PORT = "2380"


def setup_logging():
    """Setup a logger."""
    LOGGER_FORMAT = "%(asctime)s.%(msecs)03d %(process)s %(filename)s [%(levelname)s] %(message)s"
    logging.basicConfig(format=LOGGER_FORMAT,
                        level=logging.INFO, datefmt="%FT%T")


def read_env(path):
    """Read a systemd EnvironmentFile into a dict."""
    values = {}
    with open(path, "r", encoding="utf-8") as env_file:
        for line in env_file:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            values[key] = value.strip().strip('"')
    return values


def write_env_value(path, key, value):
    """Update or append a key=value pair in an EnvironmentFile."""
    lines = []
    replaced = False
    with open(path, "r", encoding="utf-8") as env_file:
        for line in env_file:
            if line.startswith("%s=" % key):
                lines.append('%s="%s"\n' % (key, value))
                replaced = True
            else:
                lines.append(line)
    if not replaced:
        lines.append('%s="%s"\n' % (key, value))
    with open(path, "w", encoding="utf-8") as env_file:
        env_file.writelines(lines)


def clear_env_value(path, key):
    """Remove a key from an EnvironmentFile, if present."""
    with open(path, "r", encoding="utf-8") as env_file:
        lines = env_file.readlines()
    kept = [line for line in lines if not line.startswith("%s=" % key)]
    if len(kept) == len(lines):
        return False
    with open(path, "w", encoding="utf-8") as env_file:
        env_file.writelines(kept)
    return True


def preflight(env):
    """Validate everything that can fail, before the member is registered.

    Registration is the one step that cannot be undone. 'etcdctl member remove'
    needs a quorum, and adding a voter to a single-member cluster is exactly
    what takes the quorum requirement from 1-of-1 to 2-of-2 -- so if this member
    is registered and then fails to start, the cluster is wedged and the only
    way back is restoring the backing store from a snapshot.

    Everything fallible is therefore checked here, so that 'member add' is the
    last thing in the start-up path that can fail.
    """
    missing = [key for key in ("ETCD_NAME",
                               "ETCD_INITIAL_ADVERTISE_PEER_URLS",
                               "ETCD_DATA_DIR",
                               "ETCD_LISTEN_CLIENT_URLS",
                               "ETCD_ADVERTISE_CLIENT_URLS",
                               "ETCD_INITIAL_CLUSTER_TOKEN")
               if not env.get(key)]
    if missing:
        raise RuntimeError("%s is missing %s; refusing to register this member "
                           "because a failed start after registration cannot "
                           "be undone" % (ENV_FILE, ", ".join(missing)))

    data_dir = env.get("ETCD_DATA_DIR")
    parent = os.path.dirname(data_dir.rstrip("/"))
    if not os.path.isdir(parent):
        raise RuntimeError("data directory parent %s does not exist" % parent)
    if not os.access(parent, os.W_OK):
        raise RuntimeError("data directory parent %s is not writable" % parent)

    for description, path in (("CA certificate", CA_FILE),
                              ("client certificate", CERT_FILE),
                              ("client key", KEY_FILE),
                              ("server certificate", SERVER_CERT_FILE),
                              ("server key", SERVER_KEY_FILE)):
        if not os.access(path, os.R_OK):
            raise RuntimeError("%s %s is missing or unreadable"
                               % (description, path))

    if not os.access(ETCDCTL, os.X_OK):
        raise RuntimeError("%s is missing or not executable" % ETCDCTL)

    LOG.info("preflight checks passed; safe to register this member")


def run_etcdctl(args, endpoint=None, check=True):
    """Run etcdctl with TLS credentials against the given endpoint."""
    if endpoint is None:
        endpoint = get_cluster_endpoint()
    cmd = [
        ETCDCTL,
        "--endpoints", endpoint,
        "--cacert", CA_FILE,
        "--cert", CERT_FILE,
        "--key", KEY_FILE,
        "--command-timeout", "%ss" % COMMAND_TIMEOUT,
        "--dial-timeout", "%ss" % DIAL_TIMEOUT,
    ] + args
    try:
        proc = subprocess.run(
            cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
            env=dict(os.environ, ETCDCTL_API="3"), check=False,
            timeout=COMMAND_TIMEOUT + DIAL_TIMEOUT + 1)
    except subprocess.TimeoutExpired as exc:
        message = "etcdctl timed out after %ss" % (COMMAND_TIMEOUT + DIAL_TIMEOUT + 1)
        if check:
            raise RuntimeError(message) from exc
        proc = subprocess.CompletedProcess(cmd, 124, stdout="", stderr=message)
    if check and proc.returncode != 0:
        raise RuntimeError("%s failed: %s" % (" ".join(cmd), proc.stderr.strip()))
    return proc


def get_cluster_endpoint():
    """Determine the best endpoint to contact the existing cluster.

    For controller-0 (fixed-0) on fresh install, we can use our own local
    endpoint since we are the seed. For controller-1 or during upgrade,
    we try every non-self entry in ETCD_INITIAL_CLUSTER and return the
    first endpoint that actually answers.
    """
    env = read_env(ENV_FILE)
    name = env.get("ETCD_NAME", "")
    state = env.get("ETCD_INITIAL_CLUSTER_STATE", "new")

    if name == "fixed-0" and state == "new":
        # We ARE the seed on fresh install - use our own advertise URL
        return env.get("ETCD_ADVERTISE_CLIENT_URLS", LOOPBACK_ENDPOINT)

    # We need to contact an existing cluster member.
    # Try every non-self entry and return the first that responds.
    initial_cluster = env.get("ETCD_INITIAL_CLUSTER", "")
    for entry in initial_cluster.split(","):
        entry = entry.strip()
        if "=" not in entry:
            continue
        member_name, peer_url = entry.split("=", 1)
        if member_name != name:
            # Convert peer URL (2380) to client URL (2379)
            client_url = peer_url.replace(":" + PEER_PORT, ":" + CLIENT_PORT)
            proc = run_etcdctl(["endpoint", "health"], endpoint=client_url,
                               check=False)
            if proc.returncode == 0:
                LOG.info("using cluster endpoint %s", client_url)
                return client_url
            LOG.info("endpoint %s not reachable, trying next", client_url)

    # Fallback: localhost
    return LOOPBACK_ENDPOINT


def wait_for_endpoint(endpoint):
    """Wait for an etcd endpoint to become healthy."""
    for _ in range(TRIES):
        proc = run_etcdctl(["endpoint", "health"], endpoint=endpoint, check=False)
        if proc.returncode == 0:
            return True
        time.sleep(SLEEP)
    return False


def get_members(endpoint=None):
    """List current cluster members."""
    proc = run_etcdctl(["member", "list", "-w", "simple"], endpoint=endpoint)
    members = []
    for line in proc.stdout.splitlines():
        fields = [field.strip() for field in line.split(",")]
        if len(fields) < 4:
            continue
        members.append({
            "id": fields[0],
            "state": fields[1],
            "name": fields[2],
            "peer_urls": fields[3],
        })
    return members


def find_member(members, name, peer_url=None):
    """Find a member by name, or by peer URL while it is unstarted."""
    for member in members:
        if member["name"] == name:
            return member
    # An unstarted member may have an empty name but matching peer URL
    if peer_url:
        for member in members:
            if not member["name"] and peer_url in member["peer_urls"]:
                return member
    return None


def add_member(name, peer_url, endpoint):
    """Add a new member to the cluster. Idempotent."""
    args = ["member", "add", name, "--peer-urls", peer_url]
    proc = run_etcdctl(args, endpoint=endpoint, check=False)
    if proc.returncode != 0:
        if "already exists" in proc.stderr or "Peer URLs already exists" in proc.stderr:
            LOG.info("member %s already registered", name)
            return
        raise RuntimeError("failed to add member %s: %s" % (name, proc.stderr.strip()))
    LOG.info("member %s added to cluster", name)


def build_initial_cluster(endpoint, local_name, local_peer_url):
    """Build ETCD_INITIAL_CLUSTER from the actual cluster member list.

    Includes all named members with valid peer URLs, plus our own entry
    if not yet named (we were just added but haven't started).
    """
    members = get_members(endpoint=endpoint)
    cluster = []
    seen_names = set()

    for member in members:
        member_name = member["name"]
        member_peer = member.get("peer_urls", "")
        # Scheme-agnostic: an incumbent from an older release advertises
        # http://, and filtering on https:// dropped the only running peer
        # from ETCD_INITIAL_CLUSTER.
        if member_name and member_peer.startswith(("https://", "http://")):
            cluster.append("%s=%s" % (member_name, member_peer))
            seen_names.add(member_name)
        elif not member_name and local_peer_url in member_peer:
            # This is us - just added but not yet started
            cluster.append("%s=%s" % (local_name, local_peer_url))
            seen_names.add(local_name)

    # Ensure our own entry is present
    if local_name not in seen_names:
        cluster.append("%s=%s" % (local_name, local_peer_url))

    return ",".join(sorted(cluster))


def data_dir_initialized(env):
    """Return True when this fixed member already has persistent state."""
    data_dir = env.get("ETCD_DATA_DIR", "")
    member_db = os.path.join(data_dir, "member", "snap", "db")
    return bool(data_dir and os.path.isfile(member_db))


def handle_pre_start():  # pylint: disable=too-many-locals,too-many-branches,too-many-statements
    """ExecStartPre logic: ensure member is registered before etcd starts."""
    env = read_env(ENV_FILE)
    name = env.get("ETCD_NAME")
    peer_url = env.get("ETCD_INITIAL_ADVERTISE_PEER_URLS")

    if not name or not peer_url:
        raise RuntimeError("%s is missing ETCD_NAME or peer URL" % ENV_FILE)

    # Wait for the listen IP to appear on an interface before proceeding.
    # On boot the address may not be placed yet; etcd fails to bind without it.
    listen_urls = env.get("ETCD_LISTEN_PEER_URLS", "")
    match = re.search(r'https?://\[?([0-9a-fA-F:.]+)\]?:', listen_urls)
    if match:
        ip_addr = match.group(1)
        if ip_addr not in ("127.0.0.1", "::1"):
            for _ in range(60):
                try:
                    data = json.loads(subprocess.check_output(
                        ["ip", "-j", "addr", "show"],
                        stderr=subprocess.PIPE).decode("utf-8"))
                    found = any(
                        addr_info.get("local") == ip_addr
                        for iface in data
                        for addr_info in iface.get("addr_info", []))
                    if found:
                        break
                except (subprocess.CalledProcessError,
                        json.JSONDecodeError):
                    pass
                time.sleep(2)
            else:
                LOG.warning("IP %s not found on any interface after 120s",
                            ip_addr)

    # If data directory is already initialized, this is a restart (not first
    # boot). Skip membership operations to avoid boot-time deadlocks -- etcd
    # ignores --initial-cluster* on subsequent starts anyway.
    if data_dir_initialized(env):
        LOG.info("data directory initialized; starting directly (restart scenario)")
        return 0

    # For the bootstrap seed (fixed-0 with state=new), just start normally.
    initial_state = env.get("ETCD_INITIAL_CLUSTER_STATE", "new")
    if initial_state == "new":
        LOG.info("initial cluster state is 'new'; starting as seed")
        return 0

    # For members joining an existing cluster (state=existing):
    # 1. Wait for the cluster to be reachable
    # 2. Add ourselves if not already a member
    # 3. Rewrite ETCD_INITIAL_CLUSTER based on actual membership
    endpoint = get_cluster_endpoint()
    LOG.info("waiting for cluster endpoint %s", endpoint)
    if not wait_for_endpoint(endpoint):
        raise RuntimeError("cluster endpoint %s not reachable after %d attempts"
                           % (endpoint, TRIES))

    # Promote only learners that have actually started. A learner that has not
    # started carries no name and is not caught up; promoting it raises the
    # voter count while the member is absent. On a cluster with one running
    # voter that takes quorum from 1-of-1 to 1-of-2 and wedges it -- every
    # read then fails with "context deadline exceeded" and recovery needs
    # ETCD_FORCE_NEW_CLUSTER. The promote result is checked rather than
    # discarded, so a refusal is visible in the log instead of silent.
    #
    # Field positions are from "member list -w simple":
    #   ID, Status, Name, PeerURLs, ClientURLs, IsLearner
    # fields[0..2] are safe because they precede any URL; IsLearner is read as
    # fields[-1] because the URL columns may themselves contain commas. That is
    # why the length guard is < 6 rather than < 5.
    proc = run_etcdctl(["member", "list", "-w", "simple"], endpoint=endpoint, check=False)
    if proc.returncode == 0:
        for line in proc.stdout.splitlines():
            fields = [f.strip() for f in line.split(",")]
            if len(fields) < 6 or fields[-1].strip().lower() != "true":
                continue
            member_id, status, member_name = fields[0], fields[1], fields[2]
            if status != "started" or not member_name:
                LOG.info("not promoting learner %s: it has not started, so "
                         "promoting it would raise the voter count while the "
                         "member is absent", member_id)
                continue
            LOG.info("promoting learner %s (%s)", member_id, member_name)
            promote = run_etcdctl(["member", "promote", member_id],
                                  endpoint=endpoint, check=False)
            if promote.returncode != 0:
                LOG.info("learner %s (%s) is not ready for promotion: %s",
                         member_id, member_name, promote.stderr.strip())
                continue
            # Allow raft to propagate the voter membership change
            # before proceeding with our own member add.
            time.sleep(5)

    members = get_members(endpoint=endpoint)
    if find_member(members, name, peer_url) is None:
        # Last fallible step before the member is registered: see preflight().
        preflight(env)
        LOG.info("adding %s to cluster via %s", name, endpoint)
        add_member(name, peer_url, endpoint)

    # Rebuild initial cluster from actual membership
    initial_cluster = build_initial_cluster(endpoint, name, peer_url)
    write_env_value(ENV_FILE, "ETCD_INITIAL_CLUSTER", initial_cluster)
    write_env_value(ENV_FILE, "ETCD_INITIAL_CLUSTER_STATE", "existing")
    LOG.info("ETCD_INITIAL_CLUSTER set to: %s", initial_cluster)
    return 0


def handle_post_start():
    """ExecStartPost logic: verify member is healthy after start."""
    env = read_env(ENV_FILE)
    local_endpoint = env.get("ETCD_ADVERTISE_CLIENT_URLS", "")
    member_name = env.get("ETCD_NAME", "unknown")

    if not local_endpoint:
        LOG.warning("no advertise client URL, skipping health check")
        return 0

    LOG.info("waiting for member '%s' at %s to become healthy", member_name, local_endpoint)
    if wait_for_endpoint(local_endpoint):
        LOG.info("member '%s' is healthy", member_name)
        # ETCD_INITIAL_CLUSTER is consumed only on first start; clear it
        # so the env file does not advertise stale membership.
        if clear_env_value(ENV_FILE, "ETCD_INITIAL_CLUSTER"):
            LOG.info("cleared ETCD_INITIAL_CLUSTER from %s; it is consumed "
                     "only on first start", ENV_FILE)
        return 0

    LOG.warning("member '%s' did not become healthy within timeout", member_name)
    # Let systemd handle restart
    return 1


def main():
    """Dispatch pre-start and post-start etcd membership operations."""
    setup_logging()
    for path in [ETCDCTL, CA_FILE, CERT_FILE, KEY_FILE,
                 SERVER_CERT_FILE, SERVER_KEY_FILE]:
        if not os.path.exists(path):
            raise RuntimeError("%s is absent" % path)

    if not os.path.exists(ENV_FILE):
        raise RuntimeError("%s is absent" % ENV_FILE)

    if "--post-start" in sys.argv[1:]:
        return handle_post_start()
    if "--pre-start" in sys.argv[1:]:
        return handle_pre_start()
    # Default to pre-start for backward compatibility
    return handle_pre_start()


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:  # pylint: disable=broad-except
        LOG.error("%s", exc)
        sys.exit(1)

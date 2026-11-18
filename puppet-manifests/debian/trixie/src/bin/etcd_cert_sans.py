#!/usr/bin/python3
#
# Copyright (c) 2026 Wind River Systems, Inc.
#
# SPDX-License-Identifier: Apache-2.0
#
"""Regenerate local etcd certificates using host's bind addresses.

A system upgraded from a single-instance release carries a certificate whose
subjectAltName lists only the floating and loopback addresses, while the
fixed instance binds the controller cluster-host address.

The addresses given are unioned with those the certificate already carries,
so none is dropped. The CA, validity and extension set match
kube-cert-rotation.sh. Nothing is done when all are already present.
"""

import argparse
import ipaddress
import os
import re
import shutil
import subprocess
import sys
import tempfile

ETCD_DIR = '/etc/etcd'
CA_CERT = os.path.join(ETCD_DIR, 'ca.crt')
CA_KEY = os.path.join(ETCD_DIR, 'ca.key')
APISERVER_DIR = '/etc/kubernetes/pki'
CERTS = ((ETCD_DIR, 'etcd-server'),
         (APISERVER_DIR, 'apiserver-etcd-client'))
FIXED_ENV_FILE = '/etc/default/etcd-fixed'
DAYS = '365'
LOOPBACK = ('127.0.0.1', '::1')

# Certificate parameters. These must stay in agreement with the two other
# paths that issue an etcd member certificate: the puppet membership exec in
# platform/manifests/etcd.pp and the renewal block in kube-cert-rotation.sh.
# Key usage, extended key usage and the one-year validity match what those
# paths produce so a certificate regenerated here is identical to the issued
# one.
CONFIG = """[req]
prompt = no
x509_extensions = v3_req
distinguished_name = dn
[dn]
CN = %(cn)s
[v3_req]
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = TLS Web Server Authentication, TLS Web Client Authentication
subjectAltName = @alt_names
[alt_names]
%(alt)s
"""


# openssl is local and CPU-bound; bounded so a stuck call fails the run.
OPENSSL_TIMEOUT = 30


def cert_ip_sans(path):
    """Return the IP addresses in a certificate's subjectAltName."""
    try:
        out = subprocess.check_output(
            ['openssl', 'x509', '-in', path, '-noout', '-text'],
            stderr=subprocess.STDOUT,
            timeout=OPENSSL_TIMEOUT).decode('utf-8', 'replace')
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired,
            OSError) as exc:
        print("WARNING: cannot read SANs from %s: %s" % (path, exc))
        return []
    return re.findall(r'IP Address:([0-9A-Fa-f:.]+)', out)


def canonical(address):
    """Return an address as an ip_address, so two spellings compare equal.

    openssl prints an IPv6 SAN expanded and upper case, the address given is
    compressed and lower case.
    """
    try:
        return ipaddress.ip_address('%s' % address)
    except ValueError:
        return None


def unique(addresses):
    """Return the valid addresses, brackets removed, each listed once.

    Two spellings of one address count as the same address; the first
    spelling seen is kept.
    """
    result = []
    seen = set()
    for address in addresses:
        if not address:
            continue
        address = address.strip('[]')
        key = canonical(address)
        if key is None or key in seen:
            continue
        seen.add(key)
        result.append(address)
    return result


def subject_cn(path):
    """Return the common name in a certificate's subject, or None.

    The common name carries the etcd member name, which is not the
    certificate's file name: the floating member is 'controller' in
    etcd-server.crt. Reading it back keeps a reissue from renaming the member.
    """
    try:
        out = subprocess.check_output(
            ['openssl', 'x509', '-in', path, '-noout', '-subject'],
            stderr=subprocess.STDOUT,
            timeout=OPENSSL_TIMEOUT).decode('utf-8', 'replace')
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired,
            OSError) as exc:
        print("WARNING: cannot read the subject of %s: %s" % (path, exc))
        return None
    found = re.search(r'CN\s*=\s*([^,/\n]+)', out)
    return found.group(1).strip() if found else None


def local_fixed_member(address=None):
    """Return this host's fixed etcd member name and the address it binds.

    Both are read from the member's own environment file, so this host is
    described by the configuration the member actually runs with. Returns
    (None, None) on a system with no fixed member.

    A caller that knows the address the member is about to bind passes it
    as address. During the simplex to duplex conversion the certificate is
    reissued before the environment file is rewritten, so the file still
    names the simplex address and cannot be used for the new one.
    """
    try:
        with open(FIXED_ENV_FILE) as handle:
            env = handle.read()
    except OSError:
        return None, None

    name = re.search(r'^ETCD_NAME="?([^"\n]+)', env, re.M)
    peer = re.search(r'^ETCD_LISTEN_PEER_URLS="?([^"\n,]+)', env, re.M)
    if not name or not peer:
        return None, None

    if address:
        return name.group(1).strip(), address.strip('[]')

    # https://192.168.206.2:2380 or https://[aefd:205::2]:2380
    address = re.match(r'https?://(\[[^\]]+\]|[^:/]+)', peer.group(1))
    if not address:
        return None, None
    return name.group(1).strip(), address.group(1).strip('[]')


def regenerate(cert_dir, name, addresses, cn=None):
    """Regenerate one certificate, signed by the etcd CA."""
    key = os.path.join(cert_dir, '%s.key' % name)
    if not os.path.exists(key):
        # A controller being added runs this before kubeadm creates
        # /etc/kubernetes/pki; the join creates this certificate.
        print("skipping %s: %s is not present" % (name, key))
        return False

    if cn is None:
        cn = subject_cn(os.path.join(cert_dir, '%s.crt' % name))

    alt = '\n'.join('IP.%d = %s' % (n, a)
                    for n, a in enumerate(addresses, start=1))
    work = tempfile.mkdtemp(prefix='etcd-cert-')
    try:
        conf = os.path.join(work, '%s_csr.conf' % name)
        with open(conf, 'w') as handle:
            handle.write(CONFIG % {'cn': cn or name, 'alt': alt})

        csr = os.path.join(work, '%s.csr' % name)
        new = os.path.join(work, '%s.crt' % name)

        subprocess.check_call(
            ['openssl', 'req', '-new', '-key', key, '-out', csr,
             '-config', conf],
            stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT,
            timeout=OPENSSL_TIMEOUT)
        subprocess.check_call(
            ['openssl', 'x509', '-req', '-in', csr, '-CA', CA_CERT,
             '-CAkey', CA_KEY, '-CAcreateserial', '-out', new,
             '-days', DAYS, '-extensions', 'v3_req', '-extfile', conf],
            stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT,
            timeout=OPENSSL_TIMEOUT)

        install(new, os.path.join(cert_dir, '%s.crt' % name))
    finally:
        shutil.rmtree(work, ignore_errors=True)
    return True


def install(new, target):
    """Replace target with new in one rename, keeping target's mode and owner.

    Replaced only once openssl has succeeded, so a failure leaves the working
    certificate in place. A running etcd reads its certificate on every TLS
    handshake, so the file is never seen half written.
    """
    staged = target + '.new'
    shutil.copyfile(new, staged)
    if os.path.exists(target):
        stat = os.stat(target)
        os.chmod(staged, stat.st_mode & 0o7777)
        os.chown(staged, stat.st_uid, stat.st_gid)
    os.replace(staged, target)


def maintain_local_member(address=None, floating=None):
    """Name this host's addresses in its own fixed member certificate.

    A fixed member's certificate names the address that member binds and,
    when given, the cluster-host floating address. It is reissued from those
    rather than from the union the shared certificates carry. address
    overrides the one read from the environment file; see
    local_fixed_member. Returns 1 on failure, 0 otherwise.

    The floating address is needed because the certificate is also the
    member's peer client certificate, and etcd rejects a peer connection
    whose source address is not among that certificate's IP SANs. On the
    controller holding the floating address the member dials the co-located
    floating member from it, and may dial the other controller from it.
    """
    # A caller that names the unit address knows every address the member
    # needs, so anything else on the certificate is stale and is dropped.
    explicit = address is not None
    name, address = local_fixed_member(address)
    if not name or not address:
        return 0

    # The pair is etcd-<member>.crt/.key; the certificate CN is the member.
    pair = 'etcd-%s' % name
    cert = os.path.join(ETCD_DIR, '%s.crt' % pair)
    if not os.path.exists(cert):
        print("no per-member certificate at %s; skipping member %s"
              % (cert, name))
        return 0

    if canonical(address.strip('[]')) is None:
        print("ERROR: %s is not an IP address for member %s" % (address, name))
        return 1
    wanted = unique([address, floating])
    present = cert_ip_sans(cert)
    held = set(a for a in map(canonical, present) if a is not None)
    missing = [a for a in wanted if canonical(a) not in held]
    loopback = set(map(canonical, LOOPBACK))
    others = [a for a in present
              if canonical(a) not in loopback and
              canonical(a) not in set(map(canonical, wanted))]
    stale = others if explicit else []
    if not missing and not stale:
        print("member %s already names %s" % (name, ', '.join(wanted)))
        return 0

    # The unit address first, as kube-cert-rotation.sh may read it from
    # there. Without the unit address from the caller, the address read from
    # the environment file may be the floating one, so the addresses the
    # certificate already names are kept rather than dropped.
    kept = [] if explicit else others
    sans = unique(wanted + kept + list(LOOPBACK))
    if stale:
        print("member %s: dropping stale SAN: %s" % (name, ', '.join(stale)))
    print("regenerating %s for member %s; missing SAN: %s"
          % (cert, name, ', '.join(missing) or '-'))
    # A failure is fatal even when only the floating address is missing:
    # without it the peers reject this member's snapshots, the floating
    # member stays a learner and controller-1 cannot join. Failing here
    # reports that on the host that has the problem.
    return reissue_member(pair, name, sans)


def reissue_member(pair, name, sans):
    """Reissue member name's certificate pair with sans.

    Returns 1 on failure, 0 otherwise.
    """
    cert = os.path.join(ETCD_DIR, '%s.crt' % pair)
    if not os.path.exists(CA_KEY):
        print("ERROR: cannot reissue %s: %s is not present" % (cert, CA_KEY))
        return 1
    try:
        done = regenerate(ETCD_DIR, pair, sans, cn=name)
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired,
            OSError) as exc:
        print("ERROR: failed to regenerate %s: %s" % (name, exc))
        return 1
    if not done:
        # The certificate exists but its key does not, so it cannot be
        # reissued here. Report it rather than claiming success.
        print("ERROR: %s was not regenerated" % cert)
        return 1
    print("regenerated %s with SANs %s" % (name, ', '.join(sans)))
    return 0


def parse_args(argv):
    """Return the parsed command line, or raise ValueError.

    Positional arguments are the addresses for the shared certificates.
    --local-address and --floating-address describe this host's fixed member
    and must be IP addresses when given.
    """
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('addresses', nargs='*',
                        help="addresses the shared certificates must name")
    parser.add_argument('--local-address',
                        help="address this host's fixed member binds")
    parser.add_argument('--floating-address',
                        help="cluster-host floating address")
    try:
        args = parser.parse_intermixed_args(argv)
    except SystemExit as exc:
        raise ValueError("invalid arguments: %s" % ' '.join(argv)) from exc
    for option in ('local_address', 'floating_address'):
        value = getattr(args, option)
        if value is not None and canonical(value.strip('[]')) is None:
            raise ValueError("--%s needs an IP address, got '%s'"
                             % (option.replace('_', '-'), value))
    return args


def main():
    try:
        args = parse_args(sys.argv[1:])
    except ValueError as exc:
        print("ERROR: %s" % exc)
        return 1

    # The member is checked even with no shared addresses to add: its
    # certificate is separate from the shared ones.
    rc = maintain_local_member(args.local_address, args.floating_address)

    wanted = [a for a in args.addresses if a]
    if not wanted:
        print("no addresses given for the shared certificates")
        return rc

    server = os.path.join(ETCD_DIR, '%s.crt' % CERTS[0][1])
    present = cert_ip_sans(server)
    held = set(a for a in map(canonical, present) if a is not None)
    missing = [a for a in wanted if canonical(a) not in held]
    if not missing:
        print("etcd certificate already names %s" % ', '.join(wanted))
        return rc

    # Unioned canonically, so one address in two spellings is listed once.
    sans = []
    seen = set()
    for address in list(present) + wanted + list(LOOPBACK):
        key = canonical(address)
        if key is None or key in seen:
            continue
        seen.add(key)
        sans.append(address)

    print("regenerating etcd certificates; missing SANs: %s"
          % ', '.join(missing))
    for cert_dir, name in CERTS:
        try:
            done = regenerate(cert_dir, name, sans)
        except (subprocess.CalledProcessError, subprocess.TimeoutExpired,
                OSError) as exc:
            print("ERROR: failed to regenerate %s: %s" % (name, exc))
            return 1
        if done:
            print("regenerated %s with SANs %s" % (name, ', '.join(sans)))
    return rc


if __name__ == '__main__':
    sys.exit(main())

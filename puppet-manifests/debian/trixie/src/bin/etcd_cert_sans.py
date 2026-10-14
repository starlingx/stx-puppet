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


def local_fixed_member():
    """Return this host's fixed etcd member name and the address it binds.

    Both are read from the member's own environment file, so this host is
    described by the configuration the member actually runs with. Returns
    (None, None) on a system with no fixed member.
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

        # Replaced only once openssl has succeeded, so a failure leaves the
        # working certificate in place.
        shutil.copyfile(new, os.path.join(cert_dir, '%s.crt' % name))
    finally:
        shutil.rmtree(work, ignore_errors=True)
    return True


def maintain_local_member():
    """Name this host's address in its own fixed member certificate.

    A fixed member's certificate names one address, the one that member binds,
    so it is reissued from that address rather than from the union the shared
    certificates carry. Returns 1 on failure, 0 otherwise.
    """
    name, address = local_fixed_member()
    if not name or not address:
        return 0

    cert = os.path.join(ETCD_DIR, 'etcd-%s.crt' % name)
    if not os.path.exists(cert):
        print("no per-member certificate at %s; skipping member %s"
              % (cert, name))
        return 0

    held = set(a for a in map(canonical, cert_ip_sans(cert)) if a is not None)
    if canonical(address) in held:
        print("member %s already names %s" % (name, address))
        return 0

    sans = [address] + list(LOOPBACK)
    print("regenerating %s for member %s; missing SAN: %s"
          % (cert, name, address))
    try:
        regenerate(ETCD_DIR, name, sans)
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired,
            OSError) as exc:
        print("ERROR: failed to regenerate %s: %s" % (name, exc))
        return 1
    print("regenerated %s with SANs %s" % (name, ', '.join(sans)))
    return 0


def main():
    wanted = [a for a in sys.argv[1:] if a]
    if not wanted:
        print("no addresses given; nothing to do")
        return 0

    rc = maintain_local_member()

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

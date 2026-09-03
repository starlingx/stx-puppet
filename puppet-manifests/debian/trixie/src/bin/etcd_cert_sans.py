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
DAYS = '365'
LOOPBACK = ('127.0.0.1', '::1')

CONFIG = """[req]
prompt = no
x509_extensions = v3_req
distinguished_name = dn
[dn]
CN = %(cn)s
[v3_req]
keyUsage = keyEncipherment, dataEncipherment
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


def regenerate(cert_dir, name, addresses):
    """Regenerate one certificate, signed by the etcd CA."""
    key = os.path.join(cert_dir, '%s.key' % name)
    if not os.path.exists(key):
        # A controller being added runs this before kubeadm creates
        # /etc/kubernetes/pki; the join creates this certificate.
        print("skipping %s: %s is not present" % (name, key))
        return False

    alt = '\n'.join('IP.%d = %s' % (n, a)
                    for n, a in enumerate(addresses, start=1))
    work = tempfile.mkdtemp(prefix='etcd-cert-')
    try:
        conf = os.path.join(work, '%s_csr.conf' % name)
        with open(conf, 'w') as handle:
            handle.write(CONFIG % {'cn': name, 'alt': alt})

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


def main():
    wanted = [a for a in sys.argv[1:] if a]
    if not wanted:
        print("no addresses given; nothing to do")
        return 0

    server = os.path.join(ETCD_DIR, '%s.crt' % CERTS[0][1])
    present = cert_ip_sans(server)
    held = set(a for a in map(canonical, present) if a is not None)
    missing = [a for a in wanted if canonical(a) not in held]
    if not missing:
        print("etcd certificate already names %s" % ', '.join(wanted))
        return 0

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
    return 0


if __name__ == '__main__':
    sys.exit(main())

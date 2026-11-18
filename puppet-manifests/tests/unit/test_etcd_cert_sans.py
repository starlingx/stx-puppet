#
# Copyright (c) 2026 Wind River Systems, Inc.
#
# SPDX-License-Identifier: Apache-2.0
#

"""Unit tests for etcd_cert_sans.py and the certificate step of
etcd_duplex_migration.py.

The member certificate tests issue real certificates from a throwaway CA
with openssl, so the reissue is checked end to end.
"""

import hashlib
import importlib.util
import io
import os
import shutil
import subprocess
import sys
import tempfile
import types
import unittest
from contextlib import redirect_stdout
from unittest import mock

BIN = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                   '..', '..', 'debian', 'trixie', 'src', 'bin')


def load(name):
    spec = importlib.util.spec_from_file_location(
        name.replace('.py', ''), os.path.join(BIN, name))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def sh(*cmd):
    subprocess.check_call(cmd, stdout=subprocess.DEVNULL,
                          stderr=subprocess.DEVNULL)


def md5(path):
    with open(path, 'rb') as h:
        return hashlib.md5(h.read()).hexdigest()


def pubkey(path):
    return subprocess.check_output(
        ['openssl', 'x509', '-in', path, '-noout', '-pubkey'])


def subject(path):
    return subprocess.check_output(
        ['openssl', 'x509', '-in', path, '-noout', '-subject']).decode()


class Base(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.mkdtemp()
        sh('openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
           '-keyout', os.path.join(self.d, 'ca.key'),
           '-out', os.path.join(self.d, 'ca.crt'), '-subj', '/CN=etcd-ca',
           '-days', '2')
        self.m = load('etcd_cert_sans.py')
        self.m.ETCD_DIR = self.d
        self.m.CA_CERT = os.path.join(self.d, 'ca.crt')
        self.m.CA_KEY = os.path.join(self.d, 'ca.key')
        self.m.CERTS = ((self.d, 'etcd-server'),)
        self.m.FIXED_ENV_FILE = os.path.join(self.d, 'etcd-fixed')

    def tearDown(self):
        shutil.rmtree(self.d, ignore_errors=True)

    def issue(self, name, cn, sans):
        key = os.path.join(self.d, name + '.key')
        sh('openssl', 'genrsa', '-out', key, '2048')
        ext = os.path.join(self.d, 'ext')
        with open(ext, 'w') as h:
            h.write('subjectAltName=' + ','.join('IP:' + a for a in sans))
        csr = os.path.join(self.d, name + '.csr')
        sh('openssl', 'req', '-new', '-key', key, '-subj', '/CN=' + cn,
           '-out', csr)
        sh('openssl', 'x509', '-req', '-in', csr, '-CA', self.m.CA_CERT,
           '-CAkey', self.m.CA_KEY, '-CAcreateserial', '-days', '2',
           '-out', os.path.join(self.d, name + '.crt'), '-extfile', ext)

    def env(self, name, peer):
        with open(self.m.FIXED_ENV_FILE, 'w') as h:
            h.write('ETCD_NAME="%s"\nETCD_LISTEN_PEER_URLS="%s"\n'
                    % (name, peer))

    def member(self, *a, **k):
        out = io.StringIO()
        with redirect_stdout(out):
            rc = self.m.maintain_local_member(*a, **k)
        return rc, out.getvalue()

    def sans(self, name):
        return [str(self.m.canonical(a)) for a in
                self.m.cert_ip_sans(os.path.join(self.d, name + '.crt'))]


class MemberV4(Base):
    def setUp(self):
        super().setUp()
        self.env('fixed-0', 'https://192.168.206.1:2380')

    def test_sx_to_dx_names_unit_and_floating(self):
        self.issue('etcd-fixed-0', 'fixed-0', ['192.168.206.1', '127.0.0.1'])
        crt = os.path.join(self.d, 'etcd-fixed-0.crt')
        before = pubkey(crt)
        rc, out = self.member('192.168.206.2', '192.168.206.1')
        self.assertEqual(rc, 0, out)
        self.assertEqual(self.sans('etcd-fixed-0'),
                         ['192.168.206.2', '192.168.206.1', '127.0.0.1', '::1'])
        self.assertIn('CN = fixed-0', subject(crt))
        self.assertEqual(before, pubkey(crt))  # key kept
        sh('openssl', 'verify', '-CAfile', self.m.CA_CERT, crt)

    def test_repairs_unit_only_cert(self):
        # State left by 1001458 issuers / 1016223 PS2: unit address only.
        self.issue('etcd-fixed-0', 'fixed-0',
                   ['192.168.206.2', '127.0.0.1', '::1'])
        rc, out = self.member('192.168.206.2', '192.168.206.1')
        self.assertEqual(rc, 0, out)
        self.assertIn('missing SAN: 192.168.206.1', out)
        self.assertIn('192.168.206.1', self.sans('etcd-fixed-0'))

    def test_noop_when_both_present(self):
        self.issue('etcd-fixed-0', 'fixed-0',
                   ['192.168.206.2', '192.168.206.1', '127.0.0.1', '::1'])
        crt = os.path.join(self.d, 'etcd-fixed-0.crt')
        h = md5(crt)
        rc, out = self.member('192.168.206.2', '192.168.206.1')
        self.assertEqual(rc, 0)
        self.assertIn('already names', out)
        self.assertEqual(h, md5(crt))

    def test_without_floating_checks_unit_only(self):
        self.issue('etcd-fixed-0', 'fixed-0',
                   ['192.168.206.2', '127.0.0.1', '::1'])
        crt = os.path.join(self.d, 'etcd-fixed-0.crt')
        h = md5(crt)
        rc, out = self.member('192.168.206.2')
        self.assertEqual((rc, h), (0, md5(crt)), out)

    def test_floating_equal_to_unit_listed_once(self):
        self.issue('etcd-fixed-0', 'fixed-0', ['10.0.0.9'])
        rc, out = self.member('192.168.206.2', '192.168.206.2')
        self.assertEqual(rc, 0, out)
        # listed once; the stale address is dropped
        self.assertEqual(self.sans('etcd-fixed-0'),
                         ['192.168.206.2', '127.0.0.1', '::1'])

    def test_address_from_env_when_not_given(self):
        self.env('fixed-1', 'https://192.168.206.3:2380')
        self.issue('etcd-fixed-1', 'fixed-1', ['192.168.206.3'])
        rc, out = self.member(None, '192.168.206.1')
        self.assertEqual(rc, 0, out)
        self.assertEqual(self.sans('etcd-fixed-1')[:2],
                         ['192.168.206.3', '192.168.206.1'])

    def test_missing_key_fails(self):
        self.issue('etcd-fixed-0', 'fixed-0', ['192.168.206.1'])
        os.remove(os.path.join(self.d, 'etcd-fixed-0.key'))
        rc, out = self.member('192.168.206.2', '192.168.206.1')
        self.assertEqual(rc, 1)
        self.assertIn('was not regenerated', out)

    def test_invalid_address_fails(self):
        self.issue('etcd-fixed-0', 'fixed-0', ['192.168.206.1'])
        rc, out = self.member('not-an-ip', '192.168.206.1')
        self.assertEqual(rc, 1)
        self.assertIn('is not an IP address', out)

    def test_no_member_cert_skips(self):
        rc, out = self.member('192.168.206.2', '192.168.206.1')
        self.assertEqual(rc, 0)
        self.assertIn('no per-member certificate', out)

    def test_no_env_file_skips(self):
        os.remove(self.m.FIXED_ENV_FILE)
        rc, _ = self.member('192.168.206.2', '192.168.206.1')
        self.assertEqual(rc, 0)


class MemberV6(Base):
    def setUp(self):
        super().setUp()
        self.env('fixed-0', 'https://[aefd:205::1]:2380')

    def test_v6_unit_and_floating(self):
        self.issue('etcd-fixed-0', 'fixed-0', ['aefd:205::1', '::1'])
        rc, out = self.member('[aefd:205::2]', 'aefd:205::1')
        self.assertEqual(rc, 0, out)
        self.assertEqual(self.sans('etcd-fixed-0'),
                         ['aefd:205::2', 'aefd:205::1', '127.0.0.1', '::1'])

    def test_v6_noop_across_spellings(self):
        self.issue('etcd-fixed-0', 'fixed-0',
                   ['AEFD:0205:0:0:0:0:0:2', 'aefd:205::1', '127.0.0.1'])
        crt = os.path.join(self.d, 'etcd-fixed-0.crt')
        h = md5(crt)
        rc, out = self.member('aefd:205::2', 'AEFD:205::1')
        self.assertEqual((rc, h), (0, md5(crt)), out)


class Main(Base):
    def run_main(self, argv):
        out = io.StringIO()
        with mock.patch.object(sys, 'argv', ['x'] + argv), \
                redirect_stdout(out):
            rc = self.m.main()
        return rc, out.getvalue()

    def test_parse_args_forms(self):
        a = self.m.parse_args(['1.1.1.1', '--floating-address=192.168.206.1',
                               '2.2.2.2', '--local-address', '[aefd::2]'])
        self.assertEqual((a.addresses, a.floating_address, a.local_address),
                         (['1.1.1.1', '2.2.2.2'], '192.168.206.1', '[aefd::2]'))
        for bad in (['--floating-address'], ['--local-address', 'x'],
                    ['--floating-address', ''], ['--bogus', '1.1.1.1']):
            with self.assertRaises(ValueError, msg=bad):
                self.m.parse_args(bad)

    def test_main_bad_options_fail(self):
        for argv in (['1.1.1.1', '--floating-address'],
                     ['1.1.1.1', '--local-address', 'nope']):
            rc, out = self.run_main(argv)
            self.assertEqual(rc, 1, argv)
            self.assertIn('ERROR', out)

    def test_main_member_only_without_positional(self):
        self.env('fixed-0', 'https://192.168.206.2:2380')
        self.issue('etcd-fixed-0', 'fixed-0', ['192.168.206.2'])
        rc, out = self.run_main(['--floating-address', '192.168.206.1'])
        self.assertEqual(rc, 0, out)
        self.assertIn('192.168.206.1', self.sans('etcd-fixed-0'))

    def test_main_end_to_end(self):
        self.env('fixed-0', 'https://192.168.206.1:2380')
        self.issue('etcd-fixed-0', 'fixed-0', ['192.168.206.1'])
        self.issue('etcd-server', 'controller',
                   ['192.168.206.1', '127.0.0.1', '::1'])
        rc, out = self.run_main(['--floating-address', '192.168.206.1',
                                 '192.168.206.2', '192.168.206.3',
                                 '--local-address', '192.168.206.2'])
        self.assertEqual(rc, 0, out)
        self.assertEqual(self.sans('etcd-fixed-0'),
                         ['192.168.206.2', '192.168.206.1', '127.0.0.1', '::1'])
        self.assertIn('CN = controller',
                      subject(os.path.join(self.d, 'etcd-server.crt')))
        self.assertEqual(set(self.sans('etcd-server')),
                         {'192.168.206.1', '192.168.206.2', '192.168.206.3',
                          '127.0.0.1', '::1'})
        # options never leak into the shared certificate SAN union
        self.assertNotIn('--floating-address', out.split('missing SANs')[-1])


class DuplexCaller(unittest.TestCase):
    def setUp(self):
        self.m = load('etcd_duplex_migration.py')
        self.d = tempfile.mkdtemp()
        self.m.HOSTS = os.path.join(self.d, 'hosts')
        with open(self.m.HOSTS, 'w') as h:
            h.write('192.168.206.1 controller-cluster-host\n'
                    '192.168.206.2 controller-0-cluster-host\n'
                    '192.168.206.3 controller-1-cluster-host\n')

    def tearDown(self):
        shutil.rmtree(self.d, ignore_errors=True)

    def cmd(self, host, floating):
        proc = types.SimpleNamespace(returncode=0, stdout='', stderr='')
        with mock.patch.object(self.m, 'run', return_value=proc) as run, \
                mock.patch.object(self.m.socket, 'gethostname',
                                  return_value=host):
            rc = self.m.handle_certificates(
                types.SimpleNamespace(floating_address=floating))
        self.assertEqual(rc, 0)
        return run.call_args[0][0]

    def test_passes_floating_and_local(self):
        c = self.cmd('controller-0', '192.168.206.1')
        self.assertEqual(c[1:], ['--floating-address', '192.168.206.1',
                                 '--local-address', '192.168.206.2',
                                 '192.168.206.2', '192.168.206.3'])

    def test_passes_floating_without_local(self):
        c = self.cmd('weird-host', '192.168.206.1')
        self.assertEqual(c[1:], ['--floating-address', '192.168.206.1',
                                 '192.168.206.2', '192.168.206.3'])

    def test_missing_peer_entry_still_repairs_member(self):
        with open(self.m.HOSTS, 'w') as h:
            h.write('192.168.206.1 controller-cluster-host\n'
                    '192.168.206.2 controller-0-cluster-host\n')
        c = self.cmd('controller-0', '192.168.206.1')
        self.assertEqual(c[1:], ['--floating-address', '192.168.206.1',
                                 '--local-address', '192.168.206.2'])
        # No shared addresses are passed while controller-1 has none.
        self.assertNotIn('192.168.206.3', c)

    def test_no_floating(self):
        c = self.cmd('controller-1', None)
        self.assertEqual(c[1:], ['--local-address', '192.168.206.3',
                                 '192.168.206.2', '192.168.206.3'])


class MemberEdgeCases(Base):
    def test_conversion_early_certs_runtime_is_noop(self):
        # SX cert names the simplex address; conductor applies certs::runtime
        # before unlock: positional this_addr=.206.2, --floating-address .206.1,
        # no --local-address, env still on the simplex address.
        self.env('fixed-0', 'https://192.168.206.1:2380')
        self.issue('etcd-fixed-0', 'fixed-0', ['192.168.206.1', '127.0.0.1', '::1'])
        crt = os.path.join(self.d, 'etcd-fixed-0.crt')
        h = md5(crt)
        rc, out = self.member(None, '192.168.206.1')
        self.assertEqual((rc, h), (0, md5(crt)), out)
        # then the unlock-time step with --local-address fixes it, unit first
        rc, out = self.member('192.168.206.2', '192.168.206.1')
        self.assertEqual(rc, 0, out)
        self.assertEqual(self.sans('etcd-fixed-0')[0], '192.168.206.2')

    def test_loopback_first_env_then_unlock_restores_unit_first(self):
        self.env('fixed-0', 'https://127.0.0.1:2380,https://192.168.206.1:2380')
        self.issue('etcd-fixed-0', 'fixed-0', ['192.168.206.1'])
        rc, _ = self.member(None, '192.168.206.1')
        self.assertEqual(rc, 0)
        rc, _ = self.member('192.168.206.2', '192.168.206.1')
        self.assertEqual(rc, 0)
        self.assertEqual(self.sans('etcd-fixed-0')[:2], ['192.168.206.2', '192.168.206.1'])

    def test_file_mode_kept(self):
        self.env('fixed-0', 'https://192.168.206.2:2380')
        self.issue('etcd-fixed-0', 'fixed-0', ['192.168.206.2'])
        crt = os.path.join(self.d, 'etcd-fixed-0.crt')
        os.chmod(crt, 0o644)
        key = os.path.join(self.d, 'etcd-fixed-0.key')
        os.chmod(key, 0o600)
        kh = md5(key)
        self.assertEqual(self.member('192.168.206.2', '192.168.206.1')[0], 0)
        self.assertEqual(oct(os.stat(crt).st_mode & 0o777), '0o644')
        self.assertEqual((oct(os.stat(key).st_mode & 0o777), md5(key)), ('0o600', kh))

    def test_stale_address_dropped_when_unit_address_given(self):
        # After a cluster-host pool change the old unit address must not
        # stay on the certificate.
        self.env('fixed-0', 'https://192.168.206.2:2380')
        self.issue('etcd-fixed-0', 'fixed-0',
                   ['10.9.9.9', '192.168.206.2', '192.168.206.1'])
        rc, out = self.member('192.168.206.2', '192.168.206.1')
        self.assertEqual(rc, 0, out)
        self.assertIn('dropping stale SAN: 10.9.9.9', out)
        self.assertEqual(self.sans('etcd-fixed-0'),
                         ['192.168.206.2', '192.168.206.1',
                          '127.0.0.1', '::1'])

    def test_held_address_kept_when_address_from_env_file(self):
        # Without --local-address the env file may name the floating
        # address, so nothing already on the certificate is dropped.
        self.env('fixed-0', 'https://192.168.206.1:2380')
        self.issue('etcd-fixed-0', 'fixed-0', ['192.168.206.2'])
        self.assertEqual(self.member(None, '192.168.206.1')[0], 0)
        self.assertEqual(self.sans('etcd-fixed-0'),
                         ['192.168.206.1', '192.168.206.2',
                          '127.0.0.1', '::1'])

    def test_only_floating_missing_without_ca_key_fails(self):
        self.env('fixed-0', 'https://192.168.206.2:2380')
        self.issue('etcd-fixed-0', 'fixed-0', ['192.168.206.2'])
        os.remove(self.m.CA_KEY)
        crt = os.path.join(self.d, 'etcd-fixed-0.crt')
        h = md5(crt)
        rc, out = self.member('192.168.206.2', '192.168.206.1')
        self.assertEqual((rc, h), (1, md5(crt)), out)
        self.assertIn('ERROR', out)

    def test_unit_missing_without_ca_key_fails(self):
        self.env('fixed-0', 'https://192.168.206.1:2380')
        self.issue('etcd-fixed-0', 'fixed-0', ['192.168.206.1'])
        os.remove(self.m.CA_KEY)
        rc, out = self.member('192.168.206.2', '192.168.206.1')
        self.assertEqual(rc, 1, out)

    def test_replace_is_atomic_rename(self):
        self.env('fixed-0', 'https://192.168.206.2:2380')
        self.issue('etcd-fixed-0', 'fixed-0', ['192.168.206.2'])
        crt = os.path.join(self.d, 'etcd-fixed-0.crt')
        ino = os.stat(crt).st_ino
        self.assertEqual(self.member('192.168.206.2', '192.168.206.1')[0], 0)
        self.assertNotEqual(ino, os.stat(crt).st_ino)
        self.assertFalse(os.path.exists(crt + '.new'))

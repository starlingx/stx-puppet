#
# Copyright (c) 2026 Wind River Systems, Inc.
#
# SPDX-License-Identifier: Apache-2.0
#
"""Tests for the remove_vg_dm_mappings.sh helper.

The script is executed for real with a fake ``dmsetup`` placed first in
PATH. The fake answers ``dmsetup info ... --select vg_name="<vg>"`` from a
fixture table (one ``<dm name> <vg name>`` pair per line) and records every
``dmsetup remove`` call, so the tests check which mappings are removed and
in which order without touching device-mapper.

Device-mapper doubles every hyphen inside VG and LV names, so the VG "a-b"
with LV "c" is the mapping "a--b-c".
"""
import os
import shutil
import subprocess
import tempfile
import unittest

_TESTS_DIR = os.path.dirname(os.path.abspath(__file__))
_PUPPET_MANIFESTS_DIR = os.path.abspath(os.path.join(_TESTS_DIR, '..', '..'))
BULLSEYE_SCRIPT_PATH = os.path.join(
    _PUPPET_MANIFESTS_DIR,
    'debian', 'bullseye', 'src', 'modules', 'platform', 'files',
    'remove_vg_dm_mappings.sh')
TRIXIE_SCRIPT_PATH = os.path.join(
    _PUPPET_MANIFESTS_DIR,
    'debian', 'trixie', 'src', 'modules', 'platform', 'files',
    'remove_vg_dm_mappings.sh')

FAKE_DMSETUP = r'''#!/bin/bash
# Fake dmsetup. Env: DM_FIXTURE (table), DM_REMOVED (log), DM_FAIL_ON (name).
if [ "$1" = info ]; then
    select=""
    while [ $# -gt 0 ]; do
        [ "$1" = --select ] && select="$2"
        shift
    done
    vg="${select#vg_name=\"}"
    vg="${vg%\"}"
    while read -r name owner; do
        [ "${owner}" = "${vg}" ] && echo "  ${name}"
    done < "${DM_FIXTURE}"
    exit 0
fi
if [ "$1" = remove ]; then
    [ "$2" = --force ] || exit 2
    echo "$3" >> "${DM_REMOVED}"
    [ "$3" = "${DM_FAIL_ON}" ] && exit 1
    exit 0
fi
exit 2
'''

# VG "lvmcsi" and a second VG whose name extends it ("lvmcsi-thin"), a
# hyphenated VG ("lvm-provisioner") and a VG with the same pool name.
FIXTURE = [
    ('lvmcsi-pool_tmeta', 'lvmcsi'),
    ('lvmcsi-pool_tdata', 'lvmcsi'),
    ('lvmcsi-pool-tpool', 'lvmcsi'),
    ('lvmcsi-pool', 'lvmcsi'),
    ('lvmcsi-data', 'lvmcsi'),
    ('lvmcsi--thin-pool_tmeta', 'lvmcsi-thin'),
    ('lvmcsi--thin-pool_tdata', 'lvmcsi-thin'),
    ('lvmcsi--thin-pool-tpool', 'lvmcsi-thin'),
    ('lvmcsi--thin-pool', 'lvmcsi-thin'),
    ('lvmcsi--thin-data', 'lvmcsi-thin'),
    ('lvm--provisioner-pool_tmeta', 'lvm-provisioner'),
    ('lvm--provisioner-pool_tdata', 'lvm-provisioner'),
    ('lvm--provisioner-pool-tpool', 'lvm-provisioner'),
    ('lvm--provisioner-pool', 'lvm-provisioner'),
    ('lvm--provisioner-vol', 'lvm-provisioner'),
    ('cgts--vg-lvmcsi--pool', 'cgts-vg'),
]


class _RemoveVgDmMappingsTests:
    """Run remove_vg_dm_mappings.sh against a fake dmsetup.

    Mixed into one TestCase per distro; ``script_path`` selects the copy.
    """

    script_path = None

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        fake = os.path.join(self.tmp, 'dmsetup')
        with open(fake, 'w') as handle:
            handle.write(FAKE_DMSETUP)
        os.chmod(fake, 0o755)
        self.fixture = os.path.join(self.tmp, 'fixture')
        with open(self.fixture, 'w') as handle:
            handle.write(''.join('%s %s\n' % pair for pair in FIXTURE))
        self.removed_log = os.path.join(self.tmp, 'removed')
        open(self.removed_log, 'w').close()

    def _run(self, *args, fail_on=''):
        env = dict(os.environ)
        env.update({
            'PATH': self.tmp + os.pathsep + env.get('PATH', ''),
            'DM_FIXTURE': self.fixture,
            'DM_REMOVED': self.removed_log,
            'DM_FAIL_ON': fail_on,
        })
        result = subprocess.run(
            ['bash', self.script_path] + list(args), env=env,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            universal_newlines=True, check=False)
        with open(self.removed_log) as handle:
            removed = handle.read().split()
        return result, removed

    def test_removes_only_the_requested_vg(self):
        """A VG whose name is extended by another VG must not hit it."""
        result, removed = self._run('lvmcsi')
        self.assertEqual(0, result.returncode)
        self.assertCountEqual(
            ['lvmcsi-data', 'lvmcsi-pool', 'lvmcsi-pool-tpool',
             'lvmcsi-pool_tdata', 'lvmcsi-pool_tmeta'], removed)
        self.assertFalse([name for name in removed if '--thin' in name])

    def test_removing_the_longer_vg_leaves_the_shorter_one(self):
        result, removed = self._run('lvmcsi-thin')
        self.assertEqual(0, result.returncode)
        self.assertEqual(5, len(removed))
        self.assertTrue(all(name.startswith('lvmcsi--thin-')
                            for name in removed))

    def test_hyphenated_vg_name_is_found(self):
        result, removed = self._run('lvm-provisioner')
        self.assertEqual(0, result.returncode)
        self.assertCountEqual(
            ['lvm--provisioner-vol', 'lvm--provisioner-pool',
             'lvm--provisioner-pool-tpool', 'lvm--provisioner-pool_tdata',
             'lvm--provisioner-pool_tmeta'], removed)

    def test_same_pool_name_in_another_vg_is_untouched(self):
        _, removed = self._run('lvmcsi')
        self.assertNotIn('cgts--vg-lvmcsi--pool', removed)

    def test_removal_order_is_lvs_then_tpool_then_hidden(self):
        """The tpool is busy while LVs exist; _tdata/_tmeta while tpool."""
        _, removed = self._run('lvmcsi')
        tpool = removed.index('lvmcsi-pool-tpool')
        hidden = [removed.index('lvmcsi-pool_tdata'),
                  removed.index('lvmcsi-pool_tmeta')]
        lvs = [removed.index('lvmcsi-data'), removed.index('lvmcsi-pool')]
        self.assertLess(max(lvs), tpool)
        self.assertLess(tpool, min(hidden))

    def test_vg_without_mappings_removes_nothing(self):
        result, removed = self._run('unknown-vg')
        self.assertEqual(0, result.returncode)
        self.assertEqual([], removed)

    def test_removal_failure_is_tolerated(self):
        """A failing remove must not stop the others nor the exit code."""
        result, removed = self._run('lvmcsi', fail_on='lvmcsi-data')
        self.assertEqual(0, result.returncode)
        self.assertEqual(5, len(removed))

    def test_missing_argument_is_rejected(self):
        result, removed = self._run()
        self.assertEqual(1, result.returncode)
        self.assertIn('Usage', result.stderr)
        self.assertEqual([], removed)


@unittest.skipUnless(os.path.isfile(BULLSEYE_SCRIPT_PATH),
                     'bullseye remove_vg_dm_mappings.sh not present')
class RemoveVgDmMappingsBullseyeTest(_RemoveVgDmMappingsTests,
                                     unittest.TestCase):
    """Shared tests against the bullseye copy of the script."""

    script_path = BULLSEYE_SCRIPT_PATH


@unittest.skipUnless(os.path.isfile(TRIXIE_SCRIPT_PATH),
                     'trixie remove_vg_dm_mappings.sh not present')
class RemoveVgDmMappingsTrixieTest(_RemoveVgDmMappingsTests,
                                   unittest.TestCase):
    """Shared tests against the trixie copy of the script."""

    script_path = TRIXIE_SCRIPT_PATH

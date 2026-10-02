#
# Copyright (c) 2026 Wind River Systems, Inc.
#
# SPDX-License-Identifier: Apache-2.0
#
"""Unit tests for configure_sriov_numvfs.py (CGTS-107733).

configure_sriov_numvfs.py safely sets a PF's sriov_numvfs, refusing to
reconfigure (and never hanging) when a VF is bound to vfio-pci and still
held open by a userspace process. It only exists in the trixie source; on
sources that lack it (bullseye, discontinued) the whole module is skipped.

The tests exercise the module against a fake sysfs/procfs tree built under a
temp directory, with the module's SYS_CLASS_NET / SYS_BUS_PCI_DEVICES /
DEV_VFIO roots redirected into it. No real SR-IOV hardware is required.
"""
import os
import shutil
import tempfile
import unittest
from unittest.mock import patch

# configure_sriov_numvfs only exists in the trixie source. Import it defensively
# so this test module stays importable (and simply skips) on bullseye, where
# the file is absent. The import path mirrors the project convention: tests
# import via debian.bullseye.src.bin, and conftest swaps that to trixie when
# STX_DISTRO=trixie.
try:
    from debian.bullseye.src.bin import configure_sriov_numvfs as csn
    HAS_MODULE = True
except ImportError:
    csn = None
    HAS_MODULE = False

requires_module = unittest.skipUnless(
    HAS_MODULE,
    'configure_sriov_numvfs not present in this source (bullseye)')


class _FakeSysfs:
    """Builds a fake sysfs/procfs tree and redirects the module roots to it.

    Layout created under a temp root:
      <root>/net/<pf>/device -> <root>/pci/<pf_bdf>     (PF device dir)
      <root>/pci/<pf_bdf>/sriov_numvfs                  (int file)
      <root>/pci/<pf_bdf>/virtfnN -> <root>/pci/<vf_bdf>
      <root>/pci/<vf_bdf>/driver -> <root>/drivers/<drv>
      <root>/pci/<vf_bdf>/iommu_group -> <root>/groups/<grp>
      <root>/vfio/<grp>                                 (vfio group node)
    """

    def __init__(self):
        self.root = tempfile.mkdtemp()
        self.net = os.path.join(self.root, 'net')
        self.pci = os.path.join(self.root, 'pci')
        self.vfio = os.path.join(self.root, 'vfio')
        for d in (self.net, self.pci, self.vfio):
            os.makedirs(d)
        self._orig = (csn.SYS_CLASS_NET, csn.SYS_BUS_PCI_DEVICES, csn.DEV_VFIO)
        csn.SYS_CLASS_NET = self.net
        csn.SYS_BUS_PCI_DEVICES = self.pci
        csn.DEV_VFIO = self.vfio

    def restore(self):
        (csn.SYS_CLASS_NET,
         csn.SYS_BUS_PCI_DEVICES,
         csn.DEV_VFIO) = self._orig
        shutil.rmtree(self.root, ignore_errors=True)

    def add_pf(self, pf, numvfs, pf_bdf='0000:c9:00.0', vf_specs=None):
        """Create a PF with the given sriov_numvfs and optional VFs.

        vf_specs: list of (driver, group) for each VF (in virtfn order).
        Returns the sriov_numvfs file path.
        """
        pf_dev = os.path.join(self.pci, pf_bdf)
        os.makedirs(pf_dev, exist_ok=True)
        netdir = os.path.join(self.net, pf)
        os.makedirs(netdir, exist_ok=True)
        os.symlink(pf_dev, os.path.join(netdir, 'device'))
        numvfs_path = os.path.join(pf_dev, 'sriov_numvfs')
        with open(numvfs_path, 'w') as handle:
            handle.write(str(numvfs))
        for index, spec in enumerate(vf_specs or []):
            self._add_vf(pf_dev, index, spec)
        return numvfs_path

    def _add_vf(self, pf_dev, index, spec):
        """Create one VF under a PF: virtfn link, driver, iommu_group, node.

        spec is a (driver, group) tuple.
        """
        driver, group = spec
        vf_dev = os.path.join(self.pci, '%s-vf%d' % (os.path.basename(pf_dev),
                                                     index))
        os.makedirs(vf_dev, exist_ok=True)
        os.symlink(vf_dev, os.path.join(pf_dev, 'virtfn%d' % index))
        if driver:
            drv = os.path.join(self.root, 'drivers', driver)
            os.makedirs(drv, exist_ok=True)
            os.symlink(drv, os.path.join(vf_dev, 'driver'))
        grp = os.path.join(self.root, 'groups', str(group))
        os.makedirs(grp, exist_ok=True)
        os.symlink(grp, os.path.join(vf_dev, 'iommu_group'))
        node = os.path.join(self.vfio, str(group))
        if not os.path.exists(node):
            open(node, 'w').close()


@requires_module
class TestSysfsHelpers(unittest.TestCase):
    """pf_device_dir / sriov_numvfs_path / read_int_file / list_vf_bdfs."""

    def setUp(self):
        self.fs = _FakeSysfs()
        self.addCleanup(self.fs.restore)
        csn.setup_logging()

    def test_pf_device_dir_and_numvfs_path(self):
        self.fs.add_pf('ens1f0', 8, pf_bdf='0000:c9:00.0')
        dev_dir = csn.pf_device_dir('ens1f0')
        self.assertTrue(dev_dir.endswith('0000:c9:00.0'))
        self.assertEqual(csn.sriov_numvfs_path('ens1f0'),
                         os.path.join(dev_dir, 'sriov_numvfs'))

    def test_pf_device_dir_missing(self):
        self.assertIsNone(csn.pf_device_dir('nosuchif'))
        self.assertIsNone(csn.sriov_numvfs_path('nosuchif'))

    def test_read_int_file(self):
        path = self.fs.add_pf('ens1f0', 8)
        self.assertEqual(csn.read_int_file(path), 8)

    def test_read_int_file_bad(self):
        bad = os.path.join(self.fs.root, 'does-not-exist')
        self.assertIsNone(csn.read_int_file(bad))
        garbage = os.path.join(self.fs.root, 'garbage')
        with open(garbage, 'w') as f:
            f.write('not-an-int')
        self.assertIsNone(csn.read_int_file(garbage))

    def test_list_vf_bdfs_sorted(self):
        self.fs.add_pf('ens1f0', 3, pf_bdf='0000:c9:00.0',
                       vf_specs=[('iavf', 10), ('iavf', 11), ('vfio-pci', 12)])
        bdfs = csn.list_vf_bdfs('ens1f0')
        self.assertEqual(bdfs, ['0000:c9:00.0-vf0',
                                '0000:c9:00.0-vf1',
                                '0000:c9:00.0-vf2'])

    def test_list_vf_bdfs_missing_pf(self):
        self.assertIsNone(csn.list_vf_bdfs('nosuchif'))

    def test_driver_and_group_of_bdf(self):
        self.fs.add_pf('ens1f0', 1, pf_bdf='0000:c9:00.0',
                       vf_specs=[('vfio-pci', 42)])
        bdf = '0000:c9:00.0-vf0'
        self.assertEqual(csn.driver_of_bdf(bdf), 'vfio-pci')
        self.assertEqual(csn.iommu_group_of_bdf(bdf), '42')


@requires_module
class TestFindVfsInUse(unittest.TestCase):
    """find_vfs_in_use: only vfio-pci VFs that are actually held count."""

    def setUp(self):
        self.fs = _FakeSysfs()
        self.addCleanup(self.fs.restore)
        csn.setup_logging()

    def test_no_vfs(self):
        self.fs.add_pf('ens1f0', 0)
        self.assertEqual(csn.find_vfs_in_use('ens1f0'), [])

    def test_vfio_vf_not_held(self):
        self.fs.add_pf('ens1f0', 2, vf_specs=[('vfio-pci', 10),
                                              ('vfio-pci', 11)])
        with patch.object(csn, 'find_holders_of_path', return_value=[]):
            self.assertEqual(csn.find_vfs_in_use('ens1f0'), [])

    def test_non_vfio_driver_ignored(self):
        self.fs.add_pf('ens1f0', 2, vf_specs=[('iavf', 10), ('ixgbevf', 11)])
        # Even if something held the node, non-vfio VFs are never in use.
        with patch.object(csn, 'find_holders_of_path',
                          return_value=[(999, 'x', 'y')]):
            self.assertEqual(csn.find_vfs_in_use('ens1f0'), [])

    def test_vfio_vf_held_is_reported(self):
        self.fs.add_pf('ens1f0', 2, vf_specs=[('vfio-pci', 10), ('iavf', 11)])

        def holders(node):
            # Only the vfio-pci VF's group-10 node has a holder.
            return [(999, 'contrail-vrouter', '/contrail-vrouter-dpdk')] \
                if node.endswith('/10') else []

        with patch.object(csn, 'find_holders_of_path', side_effect=holders):
            in_use = csn.find_vfs_in_use('ens1f0')
        self.assertEqual(len(in_use), 1)
        self.assertEqual(in_use[0]['bdf'], '0000:c9:00.0-vf0')
        self.assertEqual(in_use[0]['iommu_group'], '10')
        self.assertEqual(in_use[0]['holders'][0][0], 999)

    def test_describe_holders_formats_pid_and_comm(self):
        in_use = [{
            'bdf': '0000:c9:01.6',
            'iommu_group': '31',
            'vfio_node': '/dev/vfio/31',
            'holders': [(999, 'contrail-vrouter', '/contrail-vrouter-dpdk')],
        }]
        desc = csn.describe_holders(in_use)
        self.assertIn('0000:c9:01.6', desc)
        self.assertIn('group 31', desc)
        self.assertIn('pid=999', desc)
        self.assertIn('contrail-vrouter', desc)


@requires_module
class TestFindHoldersOfPath(unittest.TestCase):
    """find_holders_of_path: scan /proc/<pid>/fd for a target node."""

    def setUp(self):
        csn.setup_logging()

    def test_detects_holder_via_proc_fd(self):
        root = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, root, True)
        node = os.path.join(root, 'vfio_group_10')
        open(node, 'w').close()
        # Hold the node open from this very process; find_holders_of_path
        # scans the real /proc, so our own pid must show up.
        fd = open(node, 'r')
        self.addCleanup(fd.close)
        holders = csn.find_holders_of_path(node)
        pids = [h[0] for h in holders]
        self.assertIn(os.getpid(), pids)

    def test_no_holder_returns_empty(self):
        root = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, root, True)
        node = os.path.join(root, 'unheld_node')
        open(node, 'w').close()
        self.assertEqual(csn.find_holders_of_path(node), [])


@requires_module
class TestWriteSriovNumvfs(unittest.TestCase):
    """write_sriov_numvfs: 0->N transition, teardown, verification."""

    def setUp(self):
        self.fs = _FakeSysfs()
        self.addCleanup(self.fs.restore)
        csn.setup_logging()

    def test_set_from_zero(self):
        self.fs.add_pf('ens1f0', 0)
        ok = csn.write_sriov_numvfs('ens1f0', 8, teardown_first=True,
                                    settle=0.0)
        self.assertTrue(ok)
        self.assertEqual(csn.read_int_file(csn.sriov_numvfs_path('ens1f0')), 8)

    def test_change_tears_down_first(self):
        self.fs.add_pf('ens1f0', 4)
        path = csn.sriov_numvfs_path('ens1f0')
        writes = []
        real_open = open

        def tracking_open(p, *a, **k):
            if p == path and (a and a[0] == 'w'):
                # Record each value written to sriov_numvfs.
                fh = real_open(p, *a, **k)
                orig_write = fh.write

                def wr(data):
                    writes.append(data)
                    return orig_write(data)
                fh.write = wr
                return fh
            return real_open(p, *a, **k)

        with patch('builtins.open', side_effect=tracking_open):
            ok = csn.write_sriov_numvfs('ens1f0', 8, teardown_first=True,
                                        settle=0.0)
        self.assertTrue(ok)
        # current(4)!=0 and target(8)!=0 -> write "0" then "8".
        self.assertEqual(writes, ['0', '8'])

    def test_no_teardown_when_disabled(self):
        self.fs.add_pf('ens1f0', 4)
        path = csn.sriov_numvfs_path('ens1f0')
        writes = []
        real_open = open

        def tracking_open(p, *a, **k):
            if p == path and (a and a[0] == 'w'):
                fh = real_open(p, *a, **k)
                orig_write = fh.write

                def wr(data):
                    writes.append(data)
                    return orig_write(data)
                fh.write = wr
                return fh
            return real_open(p, *a, **k)

        with patch('builtins.open', side_effect=tracking_open):
            ok = csn.write_sriov_numvfs('ens1f0', 8, teardown_first=False,
                                        settle=0.0)
        self.assertTrue(ok)
        # teardown disabled -> only the target value is written.
        self.assertEqual(writes, ['8'])

    def test_missing_pf_returns_false(self):
        with patch.object(csn, 'log_error'):
            self.assertFalse(
                csn.write_sriov_numvfs('nosuchif', 8, True, 0.0))

    def test_write_error_returns_false(self):
        self.fs.add_pf('ens1f0', 0)
        with patch('builtins.open', side_effect=OSError('EBUSY')), \
             patch.object(csn, 'log_error'):
            self.assertFalse(
                csn.write_sriov_numvfs('ens1f0', 8, True, 0.0))

    def test_teardown_write_error_reports_zero_not_target(self):
        # current=4, target=8 -> the teardown write (0) runs first. If it
        # fails, the error must mention writing 0, not the final count 8.
        # read_int_file is mocked to report the current value (4) so the
        # teardown branch is taken; the write open() then raises.
        self.fs.add_pf('ens1f0', 4)
        with patch.object(csn, 'read_int_file', return_value=4), \
             patch('builtins.open', side_effect=OSError('EBUSY')), \
             patch.object(csn, 'log_error') as mock_err:
            ok = csn.write_sriov_numvfs('ens1f0', 8, teardown_first=True,
                                        settle=0.0)
        self.assertFalse(ok)
        msg = mock_err.call_args[0][0]
        self.assertIn('failed writing 0', msg)
        self.assertNotIn('failed writing 8', msg)

    def test_set_write_error_reports_target(self):
        # current=0 -> no teardown; the only write is the target. A failure
        # there must mention the target count.
        self.fs.add_pf('ens1f0', 0)
        with patch.object(csn, 'read_int_file', return_value=0), \
             patch('builtins.open', side_effect=OSError('EBUSY')), \
             patch.object(csn, 'log_error') as mock_err:
            ok = csn.write_sriov_numvfs('ens1f0', 8, teardown_first=True,
                                        settle=0.0)
        self.assertFalse(ok)
        self.assertIn('failed writing 8', mock_err.call_args[0][0])


@requires_module
class TestConfigure(unittest.TestCase):
    """configure(): the no-change / safe-apply / refuse decision + exit code."""

    def setUp(self):
        self.fs = _FakeSysfs()
        self.addCleanup(self.fs.restore)
        csn.setup_logging()

    def test_no_change_returns_zero(self):
        self.fs.add_pf('ens1f0', 8)
        with patch.object(csn, 'find_vfs_in_use') as mock_inuse, \
             patch.object(csn, 'write_sriov_numvfs') as mock_write:
            rc = csn.configure('ens1f0', 8)
        self.assertEqual(rc, 0)
        mock_inuse.assert_not_called()
        mock_write.assert_not_called()

    def test_missing_pf_returns_one(self):
        rc = csn.configure('nosuchif', 8)
        self.assertEqual(rc, 1)

    def test_safe_change_applies_and_returns_zero(self):
        self.fs.add_pf('ens1f0', 4, vf_specs=[('vfio-pci', 10)])
        with patch.object(csn, 'find_vfs_in_use', return_value=[]), \
             patch.object(csn, 'write_sriov_numvfs',
                          return_value=True) as mock_write:
            rc = csn.configure('ens1f0', 8)
        self.assertEqual(rc, 0)
        mock_write.assert_called_once()

    def test_refuses_when_vf_in_use_returns_one(self):
        self.fs.add_pf('ens1f0', 4, vf_specs=[('vfio-pci', 10)])
        in_use = [{
            'bdf': '0000:c9:00.0-vf0',
            'iommu_group': '10',
            'vfio_node': '/dev/vfio/10',
            'holders': [(999, 'contrail-vrouter', '/contrail-vrouter-dpdk')],
        }]
        with patch.object(csn, 'find_vfs_in_use', return_value=in_use), \
             patch.object(csn, 'write_sriov_numvfs') as mock_write:
            rc = csn.configure('ens1f0', 8)
        self.assertEqual(rc, 1)
        # Must NOT attempt the write when a VF is held open.
        mock_write.assert_not_called()

    def test_write_failure_returns_one(self):
        self.fs.add_pf('ens1f0', 4)
        with patch.object(csn, 'find_vfs_in_use', return_value=[]), \
             patch.object(csn, 'write_sriov_numvfs', return_value=False):
            rc = csn.configure('ens1f0', 8)
        self.assertEqual(rc, 1)

    def test_unreadable_numvfs_returns_one(self):
        self.fs.add_pf('ens1f0', 0)
        with patch.object(csn, 'read_int_file', return_value=None):
            rc = csn.configure('ens1f0', 8)
        self.assertEqual(rc, 1)


@requires_module
class TestMain(unittest.TestCase):
    """main() / argument parsing and exit codes."""

    def setUp(self):
        self.fs = _FakeSysfs()
        self.addCleanup(self.fs.restore)

    def test_main_no_change(self):
        self.fs.add_pf('ens1f0', 8)
        rc = csn.main(['--pf', 'ens1f0', '--num-vfs', '8'])
        self.assertEqual(rc, 0)

    def test_main_refuses_when_in_use(self):
        self.fs.add_pf('ens1f0', 4, vf_specs=[('vfio-pci', 10)])
        in_use = [{
            'bdf': '0000:c9:00.0-vf0', 'iommu_group': '10',
            'vfio_node': '/dev/vfio/10',
            'holders': [(999, 'dpdk', '/dpdk')],
        }]
        with patch.object(csn, 'find_vfs_in_use', return_value=in_use):
            rc = csn.main(['--pf', 'ens1f0', '--num-vfs', '8'])
        self.assertEqual(rc, 1)

    def test_main_negative_num_vfs(self):
        rc = csn.main(['--pf', 'ens1f0', '--num-vfs', '-1'])
        self.assertEqual(rc, 1)

    def test_main_requires_args(self):
        with self.assertRaises(SystemExit):
            csn.main(['--pf', 'ens1f0'])
        with self.assertRaises(SystemExit):
            csn.main(['--num-vfs', '8'])

    def test_main_no_teardown_flag(self):
        self.fs.add_pf('ens1f0', 4)
        with patch.object(csn, 'find_vfs_in_use', return_value=[]), \
             patch.object(csn, 'write_sriov_numvfs',
                          return_value=True) as mock_write:
            rc = csn.main(['--pf', 'ens1f0', '--num-vfs', '8', '--no-teardown'])
        self.assertEqual(rc, 0)
        # teardown_first (3rd positional arg to write_sriov_numvfs) must be
        # False when --no-teardown is given.
        args, _kwargs = mock_write.call_args
        self.assertFalse(args[2])


@requires_module
class TestWriteTimeout(unittest.TestCase):
    """A blocked write must not hang configure(); it fails via OSError/verify.

    configure_sriov_numvfs uses a plain write (no fork) but the apply step
    re-reads and verifies the value. This test confirms a write that does not
    take effect is reported as a failure rather than silently succeeding.
    """

    def setUp(self):
        self.fs = _FakeSysfs()
        self.addCleanup(self.fs.restore)
        csn.setup_logging()

    def test_value_not_applied_is_failure(self):
        # Writer that accepts the write but the value never changes (verify
        # mismatch) -> write_sriov_numvfs must return False.
        self.fs.add_pf('ens1f0', 4)
        with patch.object(csn, 'read_int_file',
                          side_effect=[4, 4]), \
             patch('builtins.open', create=True) as mock_open_, \
             patch.object(csn, 'log_error'):
            mock_open_.return_value.__enter__.return_value.write = \
                lambda *_a, **_k: None
            ok = csn.write_sriov_numvfs('ens1f0', 8, teardown_first=False,
                                        settle=0.0)
        self.assertFalse(ok)


if __name__ == '__main__':
    unittest.main()

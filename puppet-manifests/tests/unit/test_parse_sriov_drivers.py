#
# Copyright (c) 2026 Wind River Systems, Inc.
#
# SPDX-License-Identifier: Apache-2.0
#


"""Unit tests for parse_sriov.py edge cases."""

import json
import os
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import MagicMock
from unittest.mock import mock_open
from unittest.mock import patch

import yaml

from debian.bullseye.src.bin import parse_sriov


class TestSriovLoadDriver(unittest.TestCase):
    """Tests for load_driver()."""

    @patch('debian.bullseye.src.bin.parse_sriov.execute_command',
           return_value=(True, ''))
    def test_load_driver_vfio_pci(self, mock_exec):
        """Should run modprobe vfio-pci with special params
        and echo commands.
        """
        with patch('builtins.print'):
            result = parse_sriov.load_driver('vfio-pci')
        self.assertTrue(result)
        self.assertEqual(mock_exec.call_count, 3)
        first_call = mock_exec.call_args_list[0][0][0]
        self.assertIn('vfio-pci', first_call)
        self.assertIn('enable_sriov=1', first_call)

    @patch('debian.bullseye.src.bin.parse_sriov.execute_command',
           return_value=(True, ''))
    def test_load_driver_regular(self, mock_exec):
        """Should run modprobe for a regular driver like iavf."""
        with patch('builtins.print'):
            result = parse_sriov.load_driver('iavf')
        self.assertTrue(result)
        mock_exec.assert_called_once_with(['/usr/sbin/modprobe', 'iavf'])

    def test_load_driver_none(self):
        """Should return True for NONE driver."""
        with patch('builtins.print'):
            result = parse_sriov.load_driver('NONE')
        self.assertTrue(result)

    @patch('debian.bullseye.src.bin.parse_sriov.execute_command',
           return_value=(False, 'modprobe failed'))
    def test_load_driver_vfio_modprobe_fails(self, _mock_exec):
        """Should return False if vfio-pci modprobe fails."""
        with patch('builtins.print'):
            result = parse_sriov.load_driver('vfio-pci')
        self.assertFalse(result)

    @patch('debian.bullseye.src.bin.parse_sriov.execute_command')
    def test_load_driver_vfio_enable_sriov_fails(self, mock_exec):
        """Should return False if enable_sriov echo fails."""
        mock_exec.side_effect = [(True, ''), (False, 'echo failed')]
        with patch('builtins.print'):
            result = parse_sriov.load_driver('vfio-pci')
        self.assertFalse(result)

    @patch('debian.bullseye.src.bin.parse_sriov.execute_command')
    def test_load_driver_vfio_disable_idle_fails(self, mock_exec):
        """Should return False if disable_idle_d3 echo fails."""
        mock_exec.side_effect = [(True, ''), (True, ''), (False, 'echo failed')]
        with patch('builtins.print'):
            result = parse_sriov.load_driver('vfio-pci')
        self.assertFalse(result)

    @patch('debian.bullseye.src.bin.parse_sriov.load_module',
           return_value=(False, 'fail'))
    def test_load_driver_regular_fails(self, _mock_mod):
        """Should return False if regular modprobe fails."""
        with patch('builtins.print'):
            result = parse_sriov.load_driver('ixgbevf')
        self.assertFalse(result)


class TestSriovBind(unittest.TestCase):
    """Tests for sriov_bind()."""

    @patch('debian.bullseye.src.bin.parse_sriov.execute_command',
           return_value=(True, ''))
    @patch('debian.bullseye.src.bin.parse_sriov.load_driver', return_value=True)
    def test_sriov_bind_chunking(self, _mock_load, mock_exec):
        """Should chunk addresses into groups of 15."""
        addrs = [f'0000:07:02.{i}' for i in range(20)]
        with patch('builtins.print'):
            result = parse_sriov.sriov_bind('iavf', addrs)
        self.assertTrue(result)
        self.assertEqual(mock_exec.call_count, 2)

    @patch('debian.bullseye.src.bin.parse_sriov.load_driver', return_value=True)
    def test_sriov_bind_none_driver(self, _mock_load):
        """Should skip dpdk-devbind for NONE driver."""
        addrs = ['0000:07:02.0', '0000:07:02.1']
        with patch('builtins.print'):
            result = parse_sriov.sriov_bind('NONE', addrs)
        self.assertTrue(result)

    @patch('debian.bullseye.src.bin.parse_sriov.load_driver', return_value=False)
    def test_sriov_bind_load_driver_fails(self, _mock_load):
        """Should return False if load_driver fails."""
        result = parse_sriov.sriov_bind('iavf', ['0000:07:02.0'])
        self.assertFalse(result)

    @patch('debian.bullseye.src.bin.parse_sriov.execute_command',
           return_value=(False, 'bind error'))
    @patch('debian.bullseye.src.bin.parse_sriov.load_driver', return_value=True)
    def test_sriov_bind_exec_fails(self, _mock_load, _mock_exec):
        """Should return False if dpdk-devbind fails."""
        with patch('builtins.print'):
            result = parse_sriov.sriov_bind('iavf', ['0000:07:02.0'])
        self.assertFalse(result)


class TestSriovReadWriteFiles(unittest.TestCase):
    """Tests for _read_int_from_file and _write_int_to_file."""

    def test_read_int_from_file_success(self):
        """Should read and return an integer from file."""
        with patch('builtins.open', mock_open(read_data='42\n')):
            result = parse_sriov._read_int_from_file('/sys/fake/path')
        self.assertEqual(result, 42)

    def test_read_int_from_file_oserror(self):
        """Should return None on OSError."""
        with patch('builtins.open', side_effect=OSError('no file')), \
             patch('builtins.print'):
            result = parse_sriov._read_int_from_file('/sys/fake/path')
        self.assertIsNone(result)

    def test_read_int_from_file_valueerror(self):
        """Should return None on ValueError."""
        with patch('builtins.open', mock_open(read_data='notanint\n')), \
             patch('builtins.print'):
            result = parse_sriov._read_int_from_file('/sys/fake/path')
        self.assertIsNone(result)

    def test_write_int_to_file_success(self):
        """Should write integer to file and return True."""
        mock_file = mock_open()
        with patch('builtins.open', mock_file):
            result = parse_sriov._write_int_to_file('/sys/fake/path', 4)
        self.assertTrue(result)
        mock_file().write.assert_called_once_with('4')

    def test_write_int_to_file_oserror(self):
        """Should return False on OSError."""
        with patch('builtins.open', side_effect=OSError('perm denied')), \
             patch('builtins.print'):
            result = parse_sriov._write_int_to_file('/sys/fake/path', 4)
        self.assertFalse(result)


class TestSriovGetPfNetdevs(unittest.TestCase):
    """Tests for _get_pf_netdevs()."""

    @patch('os.path.isdir', return_value=True)
    @patch('os.listdir', return_value=['eth0', 'eth1'])
    @patch('os.path.join', side_effect=lambda *a: '/'.join(a))
    @patch('os.path.isdir')
    def test_get_pf_netdevs_returns_dirs(self, mock_isdir2, _mock_join, _mock_ls, _mock_isdir1):
        """Should return list of net device names."""
        # First call is the net_dir check (already
        # patched), subsequent are per-entry
        mock_isdir2.return_value = True
        result = parse_sriov._get_pf_netdevs('0000:18:00.0')
        self.assertIn('eth0', result)
        self.assertIn('eth1', result)

    @patch('os.path.isdir', return_value=False)
    def test_get_pf_netdevs_no_dir(self, _mock_isdir):
        """Should return empty list if net dir doesn't exist."""
        result = parse_sriov._get_pf_netdevs('0000:18:00.0')
        self.assertEqual(result, [])


class TestSriovIfaceIsUp(unittest.TestCase):
    """Tests for _iface_is_up()."""

    @patch('debian.bullseye.src.bin.parse_sriov.execute_command',
           return_value=(True, 'stdout: 2: eth0: <UP,BROADCAST> mtu 1500'))
    def test_iface_is_up_true(self, _mock_exec):
        """Should return True when UP is in output."""
        self.assertTrue(parse_sriov._iface_is_up('eth0'))

    @patch('debian.bullseye.src.bin.parse_sriov.execute_command',
           return_value=(True, 'stdout: 2: eth0: <BROADCAST> mtu 1500'))
    def test_iface_is_up_false(self, _mock_exec):
        """Should return False when UP is not in output."""
        self.assertFalse(parse_sriov._iface_is_up('eth0'))

    @patch('debian.bullseye.src.bin.parse_sriov.execute_command',
           return_value=(False, ''))
    def test_iface_is_up_cmd_fails(self, _mock_exec):
        """Should return False when command fails."""
        self.assertFalse(parse_sriov._iface_is_up('eth0'))


class TestSriovEnsurePfNetdevsUp(unittest.TestCase):
    """Tests for _ensure_pf_netdevs_up()."""

    def test_no_up_requirement(self):
        """Should return True immediately if up_requirement is False."""
        result = parse_sriov._ensure_pf_netdevs_up('0000:18:00.0', False)
        self.assertTrue(result)

    @patch('debian.bullseye.src.bin.parse_sriov._get_pf_netdevs', return_value=[])
    def test_no_netdevs(self, _mock_get):
        """Should return True if no netdevs found."""
        result = parse_sriov._ensure_pf_netdevs_up('0000:18:00.0', True)
        self.assertTrue(result)

    @patch('debian.bullseye.src.bin.parse_sriov.time.sleep')
    @patch('debian.bullseye.src.bin.parse_sriov._iface_is_up',
           side_effect=[False, False, True])
    @patch('debian.bullseye.src.bin.parse_sriov.execute_command',
           return_value=(True, ''))
    @patch('debian.bullseye.src.bin.parse_sriov._get_pf_netdevs',
           return_value=['eth0'])
    def test_retries_until_up(self, _mock_get, _mock_exec, _mock_up, _mock_sleep):
        """Should retry checking iface until it's up."""
        result = parse_sriov._ensure_pf_netdevs_up('0000:18:00.0', True)
        self.assertTrue(result)


class TestSriovEnableSriovForPf(unittest.TestCase):
    """Tests for _enable_sriov_for_pf()."""

    @patch('builtins.print')
    def test_skip_zero_numvfs(self, _mock_print):
        """Should skip if num_vfs is 0."""
        result = parse_sriov._enable_sriov_for_pf('0000:18:00.0', 0, False)
        self.assertTrue(result)

    @patch('builtins.print')
    def test_skip_none_numvfs(self, _mock_print):
        """Should skip if num_vfs is None."""
        result = parse_sriov._enable_sriov_for_pf('0000:18:00.0', None, False)
        self.assertTrue(result)

    @patch('builtins.print')
    @patch('debian.bullseye.src.bin.parse_sriov._write_int_to_file',
           return_value=True)
    @patch('debian.bullseye.src.bin.parse_sriov._read_int_from_file',
           return_value=0)
    def test_enable_success(self, _mock_read, mock_write, _mock_print):
        """Should write 0 then num_vfs and return True."""
        result = parse_sriov._enable_sriov_for_pf('0000:18:00.0', 4, False)
        self.assertTrue(result)
        self.assertEqual(mock_write.call_count, 2)

    @patch('builtins.print')
    @patch('debian.bullseye.src.bin.parse_sriov._write_int_to_file',
           return_value=False)
    @patch('debian.bullseye.src.bin.parse_sriov._read_int_from_file',
           return_value=0)
    def test_enable_write_zero_fails(self, _mock_read, _mock_write, _mock_print):
        """Should return False if writing 0 fails."""
        result = parse_sriov._enable_sriov_for_pf('0000:18:00.0', 4, False)
        self.assertFalse(result)

    @patch('builtins.print')
    @patch('debian.bullseye.src.bin.parse_sriov._write_int_to_file',
           side_effect=[True, False])
    @patch('debian.bullseye.src.bin.parse_sriov._read_int_from_file',
           return_value=0)
    def test_enable_write_numvfs_fails(self, _mock_read, _mock_write, _mock_print):
        """Should return False if writing num_vfs fails."""
        result = parse_sriov._enable_sriov_for_pf('0000:18:00.0', 4, False)
        self.assertFalse(result)

    @patch('builtins.print')
    @patch('debian.bullseye.src.bin.parse_sriov._write_int_to_file',
           return_value=True)
    @patch('debian.bullseye.src.bin.parse_sriov._ensure_pf_netdevs_up',
           return_value=True)
    @patch('debian.bullseye.src.bin.parse_sriov._read_int_from_file',
           return_value=0)
    def test_enable_with_up_requirement(self, _mock_read, mock_up, _mock_write, _mock_print):
        """Should call _ensure_pf_netdevs_up when
        up_requirement is True.
        """
        result = parse_sriov._enable_sriov_for_pf('0000:18:00.0', 4, True, sriov_name='fh0')
        self.assertTrue(result)
        mock_up.assert_called_once()


class TestSriovEnableFromConfigs(unittest.TestCase):
    """Tests for enable_sriov_from_configs()."""

    @patch('builtins.print')
    @patch('debian.bullseye.src.bin.parse_sriov._enable_sriov_for_pf',
           return_value=True)
    def test_valid_configs(self, mock_pf, _mock_print):
        """Should call _enable_sriov_for_pf for each config entry."""
        configs = {
            'pf0': {'addr': '0000:07:00.0', 'num_vfs': 4},
            'pf1': {'addr': '0000:08:00.0', 'num_vfs': 8, 'up_requirement': True},
        }
        result = parse_sriov.enable_sriov_from_configs(configs)
        self.assertTrue(result)
        self.assertEqual(mock_pf.call_count, 2)

    @patch('builtins.print')
    def test_missing_addr(self, _mock_print):
        """Should return False if addr is missing."""
        configs = {'pf0': {'num_vfs': 4}}
        result = parse_sriov.enable_sriov_from_configs(configs)
        self.assertFalse(result)

    @patch('builtins.print')
    def test_non_dict_entry(self, _mock_print):
        """Should return False if config entry is not a dict."""
        configs = {'pf0': 'invalid'}
        result = parse_sriov.enable_sriov_from_configs(configs)
        self.assertFalse(result)


class TestSriovGetSriovEntries(unittest.TestCase):
    """Tests for get_sriov_entries() edge cases."""

    def test_empty_vf_config(self):
        """Should handle entries with no vf_config."""
        configs = {
            'sriov0': {
                'port_name': 'eth0',
                'num_vfs': 4,
                'vf_config': {}
            }
        }
        with patch('builtins.print'):
            ok, (entries, rates, *_rest) = parse_sriov.get_sriov_entries(configs)
        self.assertTrue(ok)
        self.assertEqual(len(entries), 0)
        self.assertEqual(len(rates), 0)

    def test_driver_null_becomes_none(self):
        """Should map 'null' driver to DRIVER_NONE."""
        configs = {
            'sriov0': {
                'port_name': 'eth0',
                'num_vfs': 1,
                'vf_config': {
                    '0000:07:02.0': {'driver': 'null', 'addr': '0000:07:02.0'}
                }
            }
        }
        with patch('builtins.print'):
            ok, (entries, *_rest) = parse_sriov.get_sriov_entries(configs)
        self.assertTrue(ok)
        self.assertIn('NONE', entries)

    def test_driver_undef_becomes_none(self):
        """Should map 'undef' driver to DRIVER_NONE."""
        configs = {
            'sriov0': {
                'port_name': 'eth0',
                'num_vfs': 1,
                'vf_config': {
                    '0000:07:02.0': {'driver': 'undef', 'addr': '0000:07:02.0'}
                }
            }
        }
        with patch('builtins.print'):
            ok, (entries, *_rest) = parse_sriov.get_sriov_entries(configs)
        self.assertTrue(ok)
        self.assertIn('NONE', entries)


class TestSriovLoadConfigFile(unittest.TestCase):
    """Tests for _load_config_file()."""

    def test_load_json(self):
        """Should load a valid JSON file."""
        data = {'key': 'value'}
        with tempfile.NamedTemporaryFile(mode='w', suffix='.json', delete=False) as f:
            json.dump(data, f)
            fname = f.name
        try:
            result = parse_sriov._load_config_file(fname)
            self.assertEqual(result, data)
        finally:
            os.remove(fname)

    def test_load_yaml(self):
        """Should load a valid YAML file."""
        data = {'key': 'value'}
        with tempfile.NamedTemporaryFile(mode='w', suffix='.yaml', delete=False) as f:
            yaml.dump(data, f)
            fname = f.name
        try:
            result = parse_sriov._load_config_file(fname)
            self.assertEqual(result, data)
        finally:
            os.remove(fname)

    def test_unsupported_extension(self):
        """Should sys.exit for unsupported file extension."""
        with tempfile.NamedTemporaryFile(mode='w', suffix='.txt', delete=False) as f:
            f.write('data')
            fname = f.name
        try:
            with patch('builtins.print'), self.assertRaises(SystemExit):
                parse_sriov._load_config_file(fname)
        finally:
            os.remove(fname)


class TestSriovExecuteCommand(unittest.TestCase):
    """Tests for parse_sriov.execute_command()."""

    @patch('debian.bullseye.src.bin.parse_sriov.subprocess.run')
    def test_success_with_stdout(self, mock_run):
        """Should return True and stdout on success."""
        mock_run.return_value = MagicMock(stdout='output', stderr='', returncode=0)
        ok, msg = parse_sriov.execute_command(['echo', 'hi'])
        self.assertTrue(ok)
        self.assertIn('output', msg)

    @patch('debian.bullseye.src.bin.parse_sriov.subprocess.run')
    def test_stderr_with_skipping(self, mock_run):
        """Should return True if stderr contains 'skipping'."""
        mock_run.return_value = MagicMock(stdout='', stderr='Device skipping', returncode=0)
        ok, _ = parse_sriov.execute_command(['cmd'])
        self.assertTrue(ok)

    @patch('debian.bullseye.src.bin.parse_sriov.subprocess.run')
    def test_stderr_without_skipping(self, mock_run):
        """Should return False if stderr has real error."""
        mock_run.return_value = MagicMock(stdout='', stderr='real error', returncode=0)
        ok, _ = parse_sriov.execute_command(['cmd'])
        self.assertFalse(ok)

    @patch('debian.bullseye.src.bin.parse_sriov.subprocess.run',
           side_effect=subprocess.CalledProcessError(1, 'cmd', stderr='fail'))
    def test_called_process_error(self, _mock_run):
        """Should return False on CalledProcessError."""
        ok, msg = parse_sriov.execute_command(['cmd'])
        self.assertFalse(ok)
        self.assertIn('CalledProcessError', msg)

    @patch('debian.bullseye.src.bin.parse_sriov.subprocess.run',
           side_effect=subprocess.TimeoutExpired('cmd', 30))
    def test_timeout_expired(self, _mock_run):
        """Should return False on TimeoutExpired."""
        ok, msg = parse_sriov.execute_command(['cmd'])
        self.assertFalse(ok)
        self.assertIn('TimeoutExpired', msg)


class TestSriovChunkList(unittest.TestCase):
    """Tests for chunk_list()."""

    def test_exact_chunks(self):
        """Should split evenly when list size is multiple
        of chunk size.
        """
        result = list(parse_sriov.chunk_list(list(range(6)), 3))
        self.assertEqual(len(result), 2)
        self.assertEqual(result[0], [0, 1, 2])

    def test_remainder_chunk(self):
        """Should include remainder in last chunk."""
        result = list(parse_sriov.chunk_list(list(range(5)), 3))
        self.assertEqual(len(result), 2)
        self.assertEqual(result[1], [3, 4])

    def test_empty_list(self):
        """Should yield nothing for empty list."""
        result = list(parse_sriov.chunk_list([], 3))
        self.assertEqual(result, [])


class TestSriovMainFunction(unittest.TestCase):
    """Tests for parse_sriov.main() to cover lines 584-634."""

    @patch('builtins.print')
    @patch('os.geteuid', return_value=1)
    def test_not_root_exits(self, _mock_euid, _mock_print):
        """Exits when not root."""
        with self.assertRaises(SystemExit):
            parse_sriov.main()

    @patch('builtins.print')
    @patch('os.geteuid', return_value=0)
    def test_wrong_argc_exits(self, _mock_euid, _mock_print):
        """Exits with wrong number of args."""
        with patch.object(
            sys, 'argv', ['parse_sriov']
        ):
            with self.assertRaises(SystemExit):
                parse_sriov.main()

    @patch('builtins.print')
    @patch('os.geteuid', return_value=0)
    def test_invalid_mode_exits(self, _mock_euid, _mock_print):
        """Exits with invalid mode."""
        with patch.object(
            sys, 'argv', ['parse_sriov', 'bad', 'f.json']
        ):
            with self.assertRaises(SystemExit):
                parse_sriov.main()

    def test_vfs_mode_two_args(self):
        """Verify vfs mode runs with 2 args."""
        with patch('builtins.print'), \
             patch('os.geteuid', return_value=0), \
             patch('os.path.isfile', return_value=True), \
             patch.object(parse_sriov, '_load_config_file',
                          return_value={'platform::network::interfaces'
                                        '::sriov::sriov_config': {}}) as mock_load, \
             patch.object(parse_sriov, 'parse_and_process_sriov_config',
                          return_value=(True, {})), \
             patch.object(parse_sriov, 'print_dpdk_status'), \
             patch.object(sys, 'argv', ['parse_sriov', 'f.json']):
            with self.assertRaises(SystemExit) as ctx:
                parse_sriov.main()
            self.assertEqual(ctx.exception.code, 0)
        mock_load.assert_called_once()

    def test_enable_mode_three_args(self):
        """Verify enable mode runs with 3 args."""
        with patch('builtins.print'), \
             patch('os.geteuid', return_value=0), \
             patch('os.path.isfile', return_value=True), \
             patch.object(parse_sriov, '_load_config_file',
                          return_value={'platform::network::interfaces'
                                        '::sriov::sriov_config': {}}), \
             patch.object(parse_sriov, 'enable_sriov_from_data',
                          return_value=True) as mock_enable, \
             patch.object(parse_sriov, 'print_dpdk_status'), \
             patch.object(sys, 'argv', ['parse_sriov', 'enable', 'f.json']):
            with self.assertRaises(SystemExit) as ctx:
                parse_sriov.main()
            self.assertEqual(ctx.exception.code, 0)
        mock_enable.assert_called_once()


class TestSriovParseAndProcessError(unittest.TestCase):
    """Test parse_and_process_sriov_config error path."""

    @patch('builtins.print')
    def test_key_error_returns_false(self, _mock_print):
        """Returns (False, []) on KeyError."""
        data = {'platform::network::interfaces'
                '::sriov::sriov_config': {'pf1': {
                    'sriov_numvfs': 2,
                    'vf_config': {'bad': 'data'}
                }}}
        result, _ = (
            parse_sriov.parse_and_process_sriov_config(data)
        )
        self.assertFalse(result)

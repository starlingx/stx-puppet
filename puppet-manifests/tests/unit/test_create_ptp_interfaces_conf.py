#
# Copyright (c) 2026 Wind River Systems, Inc.
#
# SPDX-License-Identifier: Apache-2.0
#


"""Coverage tests for create_ptp_interfaces_conf.py."""

import unittest
from unittest.mock import mock_open
from unittest.mock import patch

try:
    import debian.bullseye.src.modules.platform.files.create_ptp_interfaces_conf as ptp_conf
except ImportError:
    ptp_conf = None


@unittest.skipIf(ptp_conf is None, "create_ptp_interfaces_conf not importable")
class TestPtpReadAllConfigFiles(unittest.TestCase):
    """Tests for read_all_config_files()."""

    @patch('debian.bullseye.src.modules.platform.files.create_ptp_interfaces_conf.glob',
           return_value=[])
    def test_no_config_files(self, _mock_glob):
        """Should return empty set when no config files found."""
        result = ptp_conf.read_all_config_files('/etc/ptp/')
        self.assertEqual(result, set())

    @patch('builtins.open', mock_open(read_data='[global]\n[eth0]\n[eth1]\n'))
    @patch('debian.bullseye.src.modules.platform.files.create_ptp_interfaces_conf.glob',
           return_value=['/etc/ptp/ptp4l-inst1.conf'])
    def test_reads_ports(self, _mock_glob):
        """Should extract port names from config sections."""
        result = ptp_conf.read_all_config_files('/etc/ptp/')
        self.assertIn('eth0', result)
        self.assertIn('eth1', result)
        self.assertNotIn('global', result)

    @patch('builtins.open', mock_open(read_data='[global]\n[unicast_master_table]\n[eth2]\n'))
    @patch('debian.bullseye.src.modules.platform.files.create_ptp_interfaces_conf.glob',
           return_value=['/etc/ptp/ptp4l-inst1.conf'])
    def test_excludes_special_sections(self, _mock_glob):
        """Should exclude global and unicast_master_table sections."""
        result = ptp_conf.read_all_config_files('/etc/ptp/')
        self.assertNotIn('unicast_master_table', result)
        self.assertIn('eth2', result)


@unittest.skipIf(ptp_conf is None, "create_ptp_interfaces_conf not importable")
class TestPtpReadPhc2sysCmdlines(unittest.TestCase):
    """Tests for read_phc2sys_cmdlines()."""

    @patch('debian.bullseye.src.modules.platform.files.create_ptp_interfaces_conf.glob',
           return_value=[])
    def test_no_files(self, _mock_glob):
        """Should return empty set when no phc2sys files found."""
        result = ptp_conf.read_phc2sys_cmdlines('/etc/ptp/')
        self.assertEqual(result, set())

    @patch('builtins.open', mock_open(read_data='OPTIONS="-s eth0 -w"\n'))
    @patch('debian.bullseye.src.modules.platform.files.create_ptp_interfaces_conf.glob',
           return_value=['/etc/ptp/phc2sys-instance-1'])
    def test_extracts_source_port(self, _mock_glob):
        """Should extract port name after -s flag."""
        result = ptp_conf.read_phc2sys_cmdlines('/etc/ptp/')
        self.assertIn('eth0', result)

    @patch('builtins.open', mock_open(read_data='OPTIONS="-w -c eth1"\n'))
    @patch('debian.bullseye.src.modules.platform.files.create_ptp_interfaces_conf.glob',
           return_value=['/etc/ptp/phc2sys-instance-1'])
    def test_no_s_flag(self, _mock_glob):
        """Should not extract port if -s flag is absent."""
        result = ptp_conf.read_phc2sys_cmdlines('/etc/ptp/')
        self.assertNotIn('eth1', result)


@unittest.skipIf(ptp_conf is None, "create_ptp_interfaces_conf not importable")
class TestPtpGetPortsPhcIndex(unittest.TestCase):
    """Tests for get_ports_phc_index()."""

    @patch('subprocess.check_output',
           return_value=b'Time stamping parameters:\nPTP Hardware Clock: 3\n')
    def test_returns_phc_index(self, _mock_sub):
        """Should return the PHC index string."""
        result = ptp_conf.get_ports_phc_index('eth0')
        self.assertEqual(result, '3')

    @patch('subprocess.check_output', return_value=b'No PTP info\n')
    def test_no_phc_info(self, _mock_sub):
        """Should return empty string if no PHC line found."""
        result = ptp_conf.get_ports_phc_index('eth0')
        self.assertEqual(result, '')


@unittest.skipIf(ptp_conf is None, "create_ptp_interfaces_conf not importable")
class TestPtpGetBasePort(unittest.TestCase):
    """Tests for get_base_port()."""

    @patch('debian.bullseye.src.modules.platform.files.create_ptp_interfaces_conf.glob',
           return_value=['/sys/class/net/enp19s0f0/device/ptp/ptp0'])
    def test_returns_base_port(self, _mock_glob):
        """Should extract base port name from sysfs path."""
        result = ptp_conf.get_base_port('0')
        self.assertEqual(result, 'enp19s0f0')

    @patch('debian.bullseye.src.modules.platform.files.create_ptp_interfaces_conf.glob',
           return_value=[])
    def test_no_ptp_device(self, _mock_glob):
        """Should return empty string if no PTP device found."""
        result = ptp_conf.get_base_port('99')
        self.assertEqual(result, '')


@unittest.skipIf(ptp_conf is None, "create_ptp_interfaces_conf not importable")
class TestPtpMain(unittest.TestCase):
    """Tests for create_ptp_interfaces_conf main()."""

    @patch.object(ptp_conf, 'get_base_port', return_value='enp19s0f0')
    @patch.object(ptp_conf, 'get_ports_phc_index', return_value='0')
    @patch.object(ptp_conf, 'read_phc2sys_cmdlines', return_value=set())
    @patch.object(ptp_conf, 'read_all_config_files', return_value={'enp19s0f0'})
    def test_main_normal_flow(self, _mock_read, _mock_phc2sys, _mock_phc, _mock_base):
        """Should write ptp-interfaces.conf with port info."""
        mock_file = mock_open()
        with patch('sys.argv', ['prog', '/etc/ptp/', '/etc/ptp/opts/']), \
             patch('builtins.open', mock_file):
            return_code = ptp_conf.main()
        self.assertEqual(return_code, 0)
        handle = mock_file()
        written = ''.join(call[0][0] for call in handle.write.call_args_list)
        self.assertIn('[enp19s0f0]', written)
        self.assertIn('phc_index 0', written)
        self.assertIn('base_port enp19s0f0', written)

    @patch.object(ptp_conf, 'read_all_config_files',
                  side_effect=Exception('read error'))
    @patch('builtins.print')
    def test_main_exception_returns_zero(self, _mock_print, _mock_read):
        """Should return 0 even on exception (doesn't stop puppet)."""
        with patch('sys.argv', ['prog', '/etc/ptp/', '/etc/ptp/opts/']):
            return_code = ptp_conf.main()
        self.assertEqual(return_code, 0)

    @patch.object(ptp_conf, 'get_base_port', return_value='')
    @patch.object(ptp_conf, 'get_ports_phc_index', return_value='')
    @patch.object(ptp_conf, 'read_phc2sys_cmdlines', return_value=set())
    @patch.object(ptp_conf, 'read_all_config_files', return_value={'eth0'})
    def test_main_empty_phc_and_base(self, _mock_read, _mock_phc2sys, _mock_phc, _mock_base):
        """Should skip writing phc_index and base_port when empty."""
        mock_file = mock_open()
        with patch('sys.argv', ['prog', '/etc/ptp/', '/etc/ptp/opts/']), \
             patch('builtins.open', mock_file):
            return_code = ptp_conf.main()
        self.assertEqual(return_code, 0)
        handle = mock_file()
        written = ''.join(call[0][0] for call in handle.write.call_args_list)
        self.assertIn('[eth0]', written)
        self.assertNotIn('phc_index', written)
        self.assertNotIn('base_port', written)

    @patch.object(ptp_conf, 'get_base_port', return_value='enp19s0f0')
    @patch.object(ptp_conf, 'get_ports_phc_index', return_value='3')
    @patch.object(ptp_conf, 'read_phc2sys_cmdlines', return_value={'eth1'})
    @patch.object(ptp_conf, 'read_all_config_files', return_value={'eth0'})
    def test_main_merges_phc2sys_ports(self, _mock_read, _mock_phc2sys, _mock_phc, _mock_base):
        """Should include ports from both config files and
        phc2sys cmdlines.
        """
        mock_file = mock_open()
        with patch('sys.argv', ['prog', '/etc/ptp/', '/etc/ptp/opts/']), \
             patch('builtins.open', mock_file):
            return_code = ptp_conf.main()
        self.assertEqual(return_code, 0)
        handle = mock_file()
        written = ''.join(call[0][0] for call in handle.write.call_args_list)
        self.assertIn('[eth0]', written)
        self.assertIn('[eth1]', written)


if __name__ == '__main__':
    unittest.main()

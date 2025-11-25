#
# Copyright (c) 2025 Wind River Systems, Inc.
#
# SPDX-License-Identifier: Apache-2.0
#

import io
import json
import os
import src.bin.parse_sriov as parse_sriov
import sys
import tempfile
import unittest
import yaml
from unittest.mock import patch
from unittest.mock import MagicMock


def valid_python_format_config():
    return {
        'platform::network::interfaces::sriov::sriov_config': {
            'sriov0': {
                'addr': '0000:07:00.0',
                'device_id': '1571',
                'num_vfs': 7,
                'port_name': 'enp0s3',
                'up_requirement': False,
                'vf_config': {
                    '0000:07:02.0': {
                        'addr': '0000:07:02.0',
                        'driver': 'iavf',
                        'max_tx_rate': 1001,
                        'vfnumber': 0
                    },
                    '0000:07:02.1': {
                        'addr': '0000:07:02.1',
                        'driver': 'iavf'
                    },
                    '0000:07:02.2': {
                        'addr': '0000:07:02.2',
                        'driver': 'vfio-pci',
                        'max_tx_rate': 1002,
                        'vfnumber': 2
                    },
                    '0000:07:02.3': {
                        'addr': '0000:07:02.3',
                        'driver': 'vfio-pci'
                    },
                    '0000:07:02.4': {
                        'addr': '0000:07:02.4',
                        'driver': 'ixgbevf'
                    },
                    '0000:07:02.5': {
                        'addr': '0000:07:02.5',
                        'driver': 'ixgbevf',
                        'max_tx_rate': 1003,
                        'vfnumber': 5
                    },
                    '0000:07:02.6': {
                        'addr': '0000:07:02.6',
                        'driver': None,
                        'max_tx_rate': 1030,
                        'vfnumber': 6
                    }
                }
            },
            'sriov1': {
                'addr': '0000:05:00.0',
                'device_id': '1572',
                'num_vfs': 6,
                'port_name': 'enp0s8',
                'up_requirement': False,
                'vf_config': {
                    '0000:05:02.0': {
                        'addr': '0000:05:02.0',
                        'driver': 'iavf'
                    },
                    '0000:05:02.1': {
                        'addr': '0000:05:02.1',
                        'driver': 'iavf',
                        'max_tx_rate': 1004,
                        'vfnumber': 1
                    },
                    '0000:05:02.2': {
                        'addr': '0000:05:02.2',
                        'driver': 'vfio-pci'
                    },
                    '0000:05:02.3': {
                        'addr': '0000:05:02.3',
                        'driver': 'vfio-pci',
                        'max_tx_rate': 1005,
                        'vfnumber': 3
                    },
                    '0000:05:02.4': {
                        'addr': '0000:05:02.4',
                        'driver': 'ixgbevf'
                    },
                    '0000:05:02.5': {
                        'addr': '0000:05:02.5',
                        'driver': 'ixgbevf',
                        'max_tx_rate': 1006,
                        'vfnumber': 5
                    }
                }
            }
        }
    }


# pylint: disable=too-many-instance-attributes
class MockHelper:
    def __init__(self, returncode=0, stdout='', stderr=''):
        self.returncode = returncode
        self.mock_stdout = stdout
        self.mock_stderr = stderr
        self._stdout_backup = None
        self._stringio = None
        self.subprocess_patcher = None
        self.mock_run = None
        self.call_args = []

    def __enter__(self):

        # For stdout
        self._stdout_backup = sys.stdout
        self._stringio = io.StringIO()
        sys.stdout = self._stringio

        # For subprocess.run
        self.subprocess_patcher = patch('src.bin.parse_sriov.subprocess.run',
                                         side_effect=self._side_effect)
        self.mock_run = self.subprocess_patcher.start()

        return self

    def __exit__(self, exc_type, exc_value, traceback):
        # Restore stdout
        sys.stdout = self._stdout_backup

        # Stop subprocess patcher
        if self.subprocess_patcher:
            self.subprocess_patcher.stop()

    def _side_effect(self, *args, **kwargs):
        self.call_args.append((args, kwargs))
        mock_result = MagicMock()
        mock_result.returncode = self.returncode
        mock_result.stdout = self.mock_stdout
        mock_result.stderr = self.mock_stderr
        return mock_result

    def get_output(self):
        """Return captured stdout as a list of lines"""
        return self._stringio.getvalue().splitlines()

    def get_output_str(self):
        """Return captured stdout as a single string"""
        return self._stringio.getvalue()

    def get_called_commands(self):
        """Return list of command-line argument lists"""
        return [args[0] for args, _ in self.call_args]


###########################################
# Tests for parse_and_process_sriov_config
class TestParseAndProcessSriovConfig(unittest.TestCase):

    def test_valid_sriov_vf_config(self):
        data = valid_python_format_config()
        expected_entries = {
            'iavf': [
                '0000:07:02.0', '0000:07:02.1', '0000:05:02.0', '0000:05:02.1'
            ],
            'vfio-pci': [
                '0000:07:02.2', '0000:07:02.3', '0000:05:02.2', '0000:05:02.3'
            ],
            'ixgbevf': [
                '0000:07:02.4', '0000:07:02.5', '0000:05:02.4', '0000:05:02.5'
            ],
            'NONE': [
                '0000:07:02.6'
            ]
        }

        expected_commands = [
            ['/usr/sbin/modprobe', 'iavf'],
            ['/usr/share/starlingx/scripts/dpdk-devbind.py', '--bind=iavf',
             '0000:07:02.0', '0000:07:02.1', '0000:05:02.0', '0000:05:02.1'],
            ['/usr/sbin/modprobe', 'vfio-pci', 'enable_sriov=1', 'disable_idle_d3=1'],
            ['/bin/sh', '-c', 'echo 1 > /sys/module/vfio_pci/parameters/enable_sriov'],
            ['/bin/sh', '-c', 'echo 1 > /sys/module/vfio_pci/parameters/disable_idle_d3'],
            ['/usr/share/starlingx/scripts/dpdk-devbind.py', '--bind=vfio-pci',
             '0000:07:02.2', '0000:07:02.3', '0000:05:02.2', '0000:05:02.3'],
            ['/usr/sbin/modprobe', 'ixgbevf'],
            ['/usr/share/starlingx/scripts/dpdk-devbind.py', '--bind=ixgbevf',
             '0000:07:02.4', '0000:07:02.5', '0000:05:02.4', '0000:05:02.5'],
            ['ip', 'link', 'set', 'enp0s3', 'vf', '0', 'max_tx_rate', '1001'],
            ['ip', 'link', 'set', 'enp0s3', 'vf', '2', 'max_tx_rate', '1002'],
            ['ip', 'link', 'set', 'enp0s3', 'vf', '5', 'max_tx_rate', '1003'],
            ['ip', 'link', 'set', 'enp0s3', 'vf', '6', 'max_tx_rate', '1030'],
            ['ip', 'link', 'set', 'enp0s8', 'vf', '1', 'max_tx_rate', '1004'],
            ['ip', 'link', 'set', 'enp0s8', 'vf', '3', 'max_tx_rate', '1005'],
            ['ip', 'link', 'set', 'enp0s8', 'vf', '5', 'max_tx_rate', '1006']]

        expected_outputs = [
            'Driver bound: iavf',
            'sriov_vf_bind driver: iavf - VFs:0000:07:02.0 0000:07:02.1 0000:05:02.0 0000:05:02.1',
            'Driver bound: vfio-pci',
            'sriov_vf_bind driver: vfio-pci - VFs:0000:07:02.2 0000:07:02.3 0000:05:02.2 '
            '0000:05:02.3',
            'Driver bound: ixgbevf',
            'sriov_vf_bind driver: ixgbevf - VFs:0000:07:02.4 0000:07:02.5 0000:05:02.4 '
            '0000:05:02.5',
            'Driver Not informed.',
            'IGNORE sriov_vf_bind for VFs:0000:07:02.6',
            'sriov_vf_ratelimit: 1001 port: enp0s3 vf: 0',
            'sriov_vf_ratelimit: 1002 port: enp0s3 vf: 2',
            'sriov_vf_ratelimit: 1003 port: enp0s3 vf: 5',
            'sriov_vf_ratelimit: 1030 port: enp0s3 vf: 6',
            'sriov_vf_ratelimit: 1004 port: enp0s8 vf: 1',
            'sriov_vf_ratelimit: 1005 port: enp0s8 vf: 3',
            'sriov_vf_ratelimit: 1006 port: enp0s8 vf: 5']

        with MockHelper(stdout="") as mock_helper:
            result, entries = parse_sriov.parse_and_process_sriov_config(data)

        # must return TRUE
        self.assertTrue(result)

        # Compare each VF Address for all Drivers
        for driver in expected_entries:
            self.assertEqual(
                sorted(entries.get(driver, [])),
                sorted(expected_entries[driver]),
                msg=f"VF Address mismatched for driver '{driver}'"
            )

        # Check stdout ( ERRORS / LOGS )
        output_lines = mock_helper.get_output()
        print(f'output_lines: {output_lines}')
        self.assertEqual(
            output_lines,
            expected_outputs,
            msg="Output did not match"
        )

        # Check subprocess calls ( Commands executed )
        commands = mock_helper.get_called_commands()
        print(f'commands: {commands}')
        self.assertEqual(
            commands,
            expected_commands,
            msg="Executed commands did not match"
        )

    def test_empty_config(self):
        data = {'platform::network::interfaces::sriov::sriov_config': {}}

        with MockHelper(stdout="") as mock_helper:
            result, entries = parse_sriov.parse_and_process_sriov_config(data)

        # Return True because empty config is valid
        self.assertTrue(result)
        self.assertEqual(entries, [])
        self.assertEqual(mock_helper.get_output(), [])
        self.assertEqual(mock_helper.get_called_commands(), [])

        data = ""
        with MockHelper(stdout="") as mock_helper:
            result, entries = parse_sriov.parse_and_process_sriov_config(data)

        # Return True because empty config is valid
        self.assertTrue(result)
        self.assertEqual(entries, [])
        self.assertEqual(mock_helper.get_output(), [])
        self.assertEqual(mock_helper.get_called_commands(), [])

    def test_invalid_data_type(self):
        data = "string"

        with MockHelper(stdout="") as mock_helper:
            result, entries = parse_sriov.parse_and_process_sriov_config(data)

        # Return False because code will not fail since the config is "empty"
        self.assertFalse(result)
        self.assertEqual(entries, [])
        self.assertIn("Error: data is not a dictionary",
                         mock_helper.get_output_str())
        self.assertEqual(mock_helper.get_called_commands(), [])

    def test_invalid_config_key(self):
        data = {'platform::network::interfaces::sriov::sr_': {}}
        with MockHelper(stdout="") as mock_helper:
            result, entries = parse_sriov.parse_and_process_sriov_config(data)

        # Return True because wrong key is like empty config
        self.assertTrue(result)
        self.assertEqual(entries, [])
        self.assertEqual(mock_helper.get_output(), [])
        self.assertEqual(mock_helper.get_called_commands(), [])

    def test_malformed_data_no_driver_name(self):
        data = {
            'platform::network::interfaces::sriov::sriov_config': {
                'sriov0': {
                    'vf_config': ["Error"]
                }
            }
        }
        with MockHelper(stdout="") as mock_helper:
            result, entries = parse_sriov.parse_and_process_sriov_config(data)

        # Function will return False
        self.assertFalse(result)
        self.assertEqual(entries, [])
        self.assertEqual(mock_helper.get_called_commands(), [])

        self.assertIn("Error: get_sriov_entries: port_name for sriov0 must not be empty",
                      mock_helper.get_output_str())


#####################################################################
# Tests for get_sriov_entries
class TestGetSriovEntries(unittest.TestCase):

    def test_get_sriov_entries(self):
        data = valid_python_format_config()
        sriov_configs = data.get('platform::network::interfaces::sriov::sriov_config', {})
        expected_sriov_entries = {
            'iavf': [
                '0000:07:02.0', '0000:07:02.1', '0000:05:02.0', '0000:05:02.1'],
            'vfio-pci': [
                '0000:07:02.2', '0000:07:02.3', '0000:05:02.2', '0000:05:02.3'],
            'ixgbevf': [
                '0000:07:02.4', '0000:07:02.5', '0000:05:02.4', '0000:05:02.5'],
            'NONE': [
                '0000:07:02.6'
            ]
        }

        expected_rate_entries = [
                {'port': 'enp0s3', 'vfnumber': 0, 'max_tx_rate': 1001},
                {'port': 'enp0s3', 'vfnumber': 2, 'max_tx_rate': 1002},
                {'port': 'enp0s3', 'vfnumber': 5, 'max_tx_rate': 1003},
                {'port': 'enp0s3', 'vfnumber': 6, 'max_tx_rate': 1030},
                {'port': 'enp0s8', 'vfnumber': 1, 'max_tx_rate': 1004},
                {'port': 'enp0s8', 'vfnumber': 3, 'max_tx_rate': 1005},
                {'port': 'enp0s8', 'vfnumber': 5, 'max_tx_rate': 1006}]

        with MockHelper(stdout="") as mock_helper:
            result, (entries, rates) = parse_sriov.get_sriov_entries(sriov_configs)

        # check entries
        for driver in expected_sriov_entries:
            self.assertEqual(
                sorted(entries.get(driver, [])),
                sorted(expected_sriov_entries[driver]),
                msg=f"VF Address mismatched for driver '{driver}'"
            )

        # check rates list
        rates_sorted = sorted(rates, key=lambda x: (x['port'], x['vfnumber']))
        self.assertEqual(
            rates_sorted,
            expected_rate_entries,
            msg="Rate list is different")

        # Function will return True
        self.assertTrue(result)
        self.assertEqual(mock_helper.get_output(), [])
        self.assertEqual(mock_helper.get_called_commands(), [])

    def test_get_sriov_entries_non_dict_input_prints_error(self):
        data = "should-be-a-dict"
        with MockHelper(stdout="") as mock_helper:
            result, (entries, rates) = parse_sriov.get_sriov_entries(data)

        # Function will return False
        self.assertFalse(result)
        self.assertEqual(entries, [])
        self.assertEqual(rates, [])
        self.assertIn("Error: get_sriov_entries: sriov_configs must be a dictionary",
                       mock_helper.get_output_str())

    def test_get_sriov_entries_invalid_config_detail_type(self):
        config = {'sriov0': "should-be-a-dict"}
        with MockHelper(stdout="") as mock_helper:
            result, (entries, rates) = parse_sriov.get_sriov_entries(config)

        # Function will return False
        self.assertFalse(result)
        self.assertEqual(entries, [])
        self.assertEqual(rates, [])
        self.assertIn("Error: get_sriov_entries: config_details for sriov0 must be a dictionary",
                      mock_helper.get_output_str())

    def test_get_sriov_entries_missing_port_name(self):
        config = {'sriov0': {'vf_config': ["should-be-a-dict"]}}
        with MockHelper(stdout="") as mock_helper:
            result, (entries, rates) = parse_sriov.get_sriov_entries(config)

        # Function will return False
        self.assertFalse(result)
        self.assertEqual(entries, [])
        self.assertEqual(rates, [])
        self.assertIn("Error: get_sriov_entries: port_name for sriov0 must not be empty",
                       mock_helper.get_output_str())

    def test_get_sriov_entries_invalid_vf_details_type(self):
        config = {
            'sriov0': {
                'port_name': 'eth0',
                'vf_config': {'0000:00:00.1': "should-be-a-dict"}
            }
        }
        with MockHelper(stdout="") as mock_helper:
            result, (entries, rates) = parse_sriov.get_sriov_entries(config)

        # Function will return False
        self.assertFalse(result)
        self.assertEqual(entries, [])
        self.assertEqual(rates, [])
        self.assertIn("Error: get_sriov_entries: vf_details for sriov0 must be a dictionary",
                      mock_helper.get_output_str())


#####################################################################
# Tests for set_max_tx_rate
class TestSetMaxTxRate(unittest.TestCase):

    def test_set_max_tx_rate_failure(self):
        """Test set_max_tx_rate when execute_command always fails."""

        with patch('src.bin.parse_sriov.execute_command',
                   return_value=(False, "mock error")) as mock_exec, \
             patch('src.bin.parse_sriov.time.sleep', return_value=None), \
             MockHelper(stdout="") as mock_helper:

            result = parse_sriov.set_max_tx_rate("eth0", 3, 1500)

        # Function should retry 5 times
        self.assertEqual(mock_exec.call_count, 5)

        # Must return False since all retries failed
        self.assertFalse(result)

        output_lines = mock_helper.get_output()
        self.assertIn("ERROR: sriov_vf_ratelimit: 1500 port: eth0 vf: 3 msg: mock error",
                      output_lines[-1],
                      msg="Final error message not printed as expected")

    def test_set_max_tx_rate_eventually_succeeds(self):
        """Test set_max_tx_rate succeeds after retries."""

        # Simulate first call fails, second call succeeds
        with patch('src.bin.parse_sriov.execute_command',
                   side_effect=[(False, "err1"), (True, "ok")]) as mock_exec, \
             patch('src.bin.parse_sriov.time.sleep', return_value=None), \
             MockHelper(stdout="") as mock_helper:

            result = parse_sriov.set_max_tx_rate("eth1", 1, 2000)

        # Function should stop after the successful second call
        self.assertEqual(mock_exec.call_count, 2)

        self.assertTrue(result)

        output_lines = mock_helper.get_output()
        self.assertIn("sriov_vf_ratelimit: 2000 port: eth1 vf: 1",
                      output_lines[-1],
                      msg="Expected success message not printed")


###########################################
# Tests for parse_sriov main function
class TestMainFunction(unittest.TestCase):

    def setUp(self):
        # Patch os.geteuid so main() thinks we are running as root
        self.geteuid_patcher = patch('src.bin.parse_sriov.os.geteuid', return_value=0)
        self.mock_geteuid = self.geteuid_patcher.start()

    def tearDown(self):
        # Stop the os.geteuid patch
        self.geteuid_patcher.stop()

    def test_main_with_valid_json(self):
        data = valid_python_format_config()

        with tempfile.NamedTemporaryFile(mode='w', suffix='.json', delete=False) as tf:
            json.dump(data, tf, indent=3)
            temp_filename = tf.name

        try:
            with patch.object(sys, 'argv', ['parse_sriov', temp_filename]), \
                 MockHelper(stdout="") as mock_helper, \
                 self.assertRaises(SystemExit) as cm:
                parse_sriov.main()

            # entries were already validated in test_valid_sriov_vf_config
            output_lines = mock_helper.get_output()
            commands = mock_helper.get_called_commands()
            self.assertEqual(len(output_lines), 15)
            self.assertEqual(len(commands), 15)

            self.assertEqual(cm.exception.code, 0)

        finally:
            os.remove(temp_filename)

    def test_main_with_valid_yaml(self):
        data = valid_python_format_config()

        with tempfile.NamedTemporaryFile(mode='w', suffix='.yaml', delete=False) as tf:
            yaml.dump(data, tf)
            temp_filename = tf.name

        try:
            with patch.object(sys, 'argv', ['parse_sriov', temp_filename]), \
                 MockHelper(stdout="") as mock_helper, \
                 self.assertRaises(SystemExit) as cm:
                parse_sriov.main()

            self.assertEqual(cm.exception.code, 0)

            # entries were already validated in test_valid_sriov_vf_config
            output_lines = mock_helper.get_output()
            commands = mock_helper.get_called_commands()
            self.assertEqual(len(output_lines), 15)
            self.assertEqual(len(commands), 15)
        finally:
            os.remove(temp_filename)

    def test_main_with_empty_yaml(self):
        data = ""

        with tempfile.NamedTemporaryFile(mode='w', suffix='.yaml', delete=False) as tf:
            yaml.dump(data, tf)
            temp_filename = tf.name

        try:
            with patch.object(sys, 'argv', ['parse_sriov', temp_filename]), \
                 MockHelper(stdout="") as mock_helper, \
                 self.assertRaises(SystemExit) as cm:
                parse_sriov.main()

            self.assertEqual(cm.exception.code, 0)
            self.assertIn("No SRIOV entries found.",
                          mock_helper.get_output_str())

        finally:
            os.remove(temp_filename)

    def test_main_function_with_invalid_yaml_file(self):
        with tempfile.NamedTemporaryFile(mode='w+', suffix='.yaml', delete=False) as tmp_file:
            # Invalid Yaml format:
            tmp_file.write('bad:\n  - yaml:\n    - :')
            temp_filename = tmp_file.name

        try:
            with patch.object(sys, 'argv', ['parse_sriov', temp_filename]), \
                 MockHelper(stdout="") as mock_helper, \
                 self.assertRaises(SystemExit) as cm:
                parse_sriov.main()

            # Must return Error
            self.assertEqual(cm.exception.code, 1)
            self.assertIn("Error reading or parsing file: ParserError: "
                          "while parsing a block mapping",
                          mock_helper.get_output_str())

        finally:
            os.remove(temp_filename)

    def test_main_function_with_invalid_json_file(self):
        with tempfile.NamedTemporaryFile(mode='w+', suffix='.json', delete=False) as tmp_file:
            tmp_file.write('{ invalid json }')  # malformed JSON
            temp_filename = tmp_file.name

        try:
            with patch.object(sys, 'argv', ['parse_sriov', temp_filename]), \
                 MockHelper(stdout="") as mock_helper, \
                 self.assertRaises(SystemExit) as cm:
                parse_sriov.main()

            # Must return Error
            self.assertEqual(cm.exception.code, 1)
            self.assertIn("Error reading or parsing file: JSONDecodeError: "
                          "Expecting property name enclosed in double quotes",
                          mock_helper.get_output_str())
        finally:
            os.remove(temp_filename)

    def test_main_oserror(self):
        with tempfile.NamedTemporaryFile(mode='w', suffix='.json', delete=False) as tmp_file:
            temp_filename = tmp_file.name

        try:
            with patch.object(sys, 'argv', ['parse_sriov', temp_filename]), \
                 patch("builtins.open", side_effect=OSError("Permission denied")), \
                 MockHelper(stdout="") as mock_helper, \
                 self.assertRaises(SystemExit) as cm:
                parse_sriov.main()

            # Must return Error
            self.assertEqual(cm.exception.code, 1)
            self.assertIn("Error reading or parsing file: OSError: Permission denied",
                          mock_helper.get_output_str())
        finally:
            os.remove(temp_filename)

    def test_main_file_not_found(self):
        temp_filename = "/tmp/file_not_found.yaml"

        with patch.object(sys, 'argv', ['parse_sriov', temp_filename]), \
             MockHelper(stdout="") as mock_helper, \
             self.assertRaises(SystemExit) as cm:
            parse_sriov.main()

        # Must return Error
        self.assertEqual(cm.exception.code, 1)
        self.assertIn("Error: File not found:",
                        mock_helper.get_output_str())

    def test_main_with_enable_success(self):
        data = valid_python_format_config()

        with tempfile.NamedTemporaryFile(mode='w', suffix='.yaml',
                                         delete=False) as tf:
            yaml.dump(data, tf)
            temp_filename = tf.name

        try:
            with patch.object(sys, 'argv',
                              ['parse_sriov', 'enable', temp_filename]), \
                 patch('src.bin.parse_sriov.enable_sriov_from_data',
                       return_value=True) as mock_enable, \
                 MockHelper(stdout="") as mock_helper, \
                 self.assertRaises(SystemExit) as cm:
                parse_sriov.main()

            self.assertEqual(cm.exception.code, 0)

            mock_enable.assert_called_once()
            called_args = mock_enable.call_args[0][0]
            self.assertIsInstance(called_args, dict)
            self.assertEqual(mock_helper.get_output(), [])

        finally:
            os.remove(temp_filename)

    def test_main_with_enable_failure(self):
        data = valid_python_format_config()

        with tempfile.NamedTemporaryFile(mode='w', suffix='.json',
                                         delete=False) as tf:
            json.dump(data, tf, indent=3)
            temp_filename = tf.name

        try:
            with patch.object(sys, 'argv',
                              ['parse_sriov', 'enable', temp_filename]), \
                 patch('src.bin.parse_sriov.enable_sriov_from_data',
                       return_value=False), \
                 MockHelper(stdout="") as mock_helper, \
                 self.assertRaises(SystemExit) as cm:
                parse_sriov.main()

            self.assertEqual(cm.exception.code, 1)
            self.assertEqual(mock_helper.get_output(), [])

        finally:
            os.remove(temp_filename)


#####################################################################
# Tests for enable_sriov_from_data / enable_sriov_from_configs
class TestEnableSriovFunctions(unittest.TestCase):

    def test_enable_sriov_from_data_valid(self):
        data = {
            'platform::network::interfaces::sriov::sriov_config': {
                'pf0': {
                    'addr': '0000:07:00.0',
                    'num_vfs': 4,
                    'up_requirement': False,
                },
                'pf1': {
                    'addr': '0000:08:00.0',
                    'num_vfs': 8,
                    'up_requirement': True,
                },
            }
        }

        sriov_cfg = data.get(
            'platform::network::interfaces::sriov::sriov_config', {}
        )

        with patch('src.bin.parse_sriov.enable_sriov_from_configs',
                   return_value=True) as mock_enable, \
             MockHelper(stdout='') as mock_helper:

            result = parse_sriov.enable_sriov_from_data(data)

        self.assertTrue(result)
        mock_enable.assert_called_once_with(sriov_cfg)
        self.assertEqual(mock_helper.get_output(), [])

    def test_enable_sriov_from_data_empty_or_missing(self):
        data = {}
        with patch('src.bin.parse_sriov.enable_sriov_from_configs') \
                as mock_enable, \
             MockHelper(stdout='') as mock_helper:
            result = parse_sriov.enable_sriov_from_data(data)

        self.assertTrue(result)
        mock_enable.assert_not_called()
        self.assertEqual(mock_helper.get_output(), [])

        data = {
            'platform::network::interfaces::sriov::sriov_config': {}
        }
        with patch('src.bin.parse_sriov.enable_sriov_from_configs') \
                as mock_enable, \
             MockHelper(stdout='') as mock_helper:
            result = parse_sriov.enable_sriov_from_data(data)

        self.assertTrue(result)
        mock_enable.assert_not_called()
        self.assertEqual(mock_helper.get_output(), [])

    def test_enable_sriov_from_data_invalid_type(self):
        data = 'not-a-dict'

        with MockHelper(stdout='') as mock_helper:
            result = parse_sriov.enable_sriov_from_data(data)

        self.assertFalse(result)
        self.assertIn('Error: data is not a dictionary: str',
                      mock_helper.get_output_str())

    def test_enable_sriov_from_configs_success(self):
        sriov_configs = {
            'pf0': {
                'addr': '0000:07:00.0',
                'num_vfs': 4,
                'up_requirement': False,
            },
            'pf1': {
                'addr': '0000:08:00.0',
                'num_vfs': 8,
                'up_requirement': True,
            },
        }

        with patch('src.bin.parse_sriov._enable_sriov_for_pf',
                   return_value=True) as mock_pf, \
             MockHelper(stdout='') as mock_helper:

            result = parse_sriov.enable_sriov_from_configs(sriov_configs)

        self.assertTrue(result)
        # Deve chamar uma vez por PF
        self.assertEqual(mock_pf.call_count, 2)
        mock_pf.assert_any_call('0000:07:00.0', 4, False, sriov_name='pf0')
        mock_pf.assert_any_call('0000:08:00.0', 8, True, sriov_name='pf1')
        self.assertEqual(mock_helper.get_output(), [])

    def test_enable_sriov_from_configs_missing_addr(self):
        sriov_configs = {
            'pf0': {
                'num_vfs': 4,
                'up_requirement': False,
            }
        }

        with patch('src.bin.parse_sriov._enable_sriov_for_pf') as mock_pf, \
             MockHelper(stdout='') as mock_helper:

            result = parse_sriov.enable_sriov_from_configs(sriov_configs)

        self.assertFalse(result)
        mock_pf.assert_not_called()
        self.assertIn(
            "ERROR: sriov_enable: missing 'addr' for 'pf0' "
            '(PF PCI address required)',
            mock_helper.get_output_str()
        )

    def test_enable_sriov_from_configs_invalid_entry_type(self):
        sriov_configs = {
            'pf0': 'invalid'
        }

        with patch('src.bin.parse_sriov._enable_sriov_for_pf') as mock_pf, \
             MockHelper(stdout='') as mock_helper:

            result = parse_sriov.enable_sriov_from_configs(sriov_configs)

        self.assertFalse(result)
        mock_pf.assert_not_called()
        self.assertIn(
            "ERROR: sriov_enable: config for 'pf0' must be a dictionary",
            mock_helper.get_output_str()
        )

    def test_enable_sriov_from_configs_partial_failure(self):
        sriov_configs = {
            'pf0': {
                'addr': '0000:07:00.0',
                'num_vfs': 4,
                'up_requirement': False,
            },
            'pf1': {
                'addr': '0000:08:00.0',
                'num_vfs': 8,
                'up_requirement': True,
            },
        }

        side_effect = [
            True,
            False,
        ]

        with patch('src.bin.parse_sriov._enable_sriov_for_pf',
                   side_effect=side_effect) as mock_pf, \
             MockHelper(stdout='') as mock_helper:

            result = parse_sriov.enable_sriov_from_configs(sriov_configs)

        self.assertFalse(result)
        self.assertEqual(mock_pf.call_count, 2)
        mock_pf.assert_any_call('0000:07:00.0', 4, False, sriov_name='pf0')
        mock_pf.assert_any_call('0000:08:00.0', 8, True, sriov_name='pf1')
        self.assertEqual(mock_helper.get_output(), [])


if __name__ == '__main__':
    unittest.main()

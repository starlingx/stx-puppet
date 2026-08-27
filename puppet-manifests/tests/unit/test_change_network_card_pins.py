#
# Copyright (c) 2026 Wind River Systems, Inc.
#
# SPDX-License-Identifier: Apache-2.0
#


"""Unit tests for change_network_card_pins.py edge cases."""

import sys
import unittest
from unittest import mock
from unittest.mock import MagicMock
from unittest.mock import mock_open
from unittest.mock import patch

# Mock pynetlink before importing - not available in CI
sys.modules['pynetlink'] = mock.MagicMock()
import debian.bullseye.src.modules.platform.files.change_network_card_pins as cncp  # noqa: E402


class TestCncpGetClockId(unittest.TestCase):
    """Tests for get_clock_id()."""

    @patch('os.path.exists', return_value=True)
    @patch('builtins.open', mock_open(read_data='0123456789abcdef\n'))
    def test_get_clock_id_success(self, _mock_exists):
        """Should convert hex phys_switch_id to integer."""
        result = cncp.get_clock_id('eth0')
        self.assertEqual(result, int('0x0123456789abcdef', 16))

    @patch('os.path.exists', return_value=False)
    def test_get_clock_id_no_file(self, _mock_exists):
        """Should raise Exception if sysfs file does not exist."""
        with self.assertRaises(Exception) as ctx:  # noqa: H202
            cncp.get_clock_id('eth99')
        self.assertIn('Invalid network interface', str(ctx.exception))

    @patch('os.path.exists', return_value=True)
    @patch('builtins.open', mock_open(read_data='\n'))
    def test_get_clock_id_empty_data(self, _mock_exists):
        """Should raise Exception if phys_switch_id is empty."""
        with self.assertRaises(Exception) as ctx:  # noqa: H202
            cncp.get_clock_id('eth0')
        self.assertIn('Invalid network interface', str(ctx.exception))

    @patch('os.path.exists', return_value=True)
    @patch('builtins.open', mock_open(read_data='ff\n'))
    def test_get_clock_id_short_hex(self, _mock_exists):
        """Should handle short hex values."""
        result = cncp.get_clock_id('eth0')
        self.assertEqual(result, 0xff)


class TestCncpMain(unittest.TestCase):
    """Tests for change_network_card_pins main()."""

    @patch.object(cncp, 'get_clock_id', return_value=12345)
    @patch('builtins.print')
    def test_main_success(self, _mock_print, _mock_clock):
        """Should return 0 on successful pin configuration."""
        mock_dpll = MagicMock()
        mock_pins = MagicMock()
        mock_pin = MagicMock()
        mock_pin.pin_id = 42
        mock_pins.__len__ = lambda self_: 1
        mock_pins.__iter__ = lambda self_: iter([mock_pin])
        mock_dpll.get_all_pins.return_value.filter_by_device_clock_id.return_value \
            .filter_by_pin_board_label.return_value = mock_pins
        with patch('sys.argv', ['prog', 'eth0', 'SMA1', 'input']), \
             patch.object(cncp, 'NetlinkDPLL', return_value=mock_dpll):
            return_code = cncp.main()
        self.assertEqual(return_code, 0)
        mock_dpll.set_pin_direction.assert_called_once_with(42, 'input')

    @patch.object(cncp, 'get_clock_id', side_effect=Exception('no file'))
    @patch('builtins.print')
    def test_main_get_clock_id_fails(self, _mock_print, _mock_clock):
        """Should return -1 when get_clock_id raises."""
        with patch('sys.argv', ['prog', 'eth99', 'SMA1', 'input']):
            return_code = cncp.main()
        self.assertEqual(return_code, -1)

    @patch.object(cncp, 'get_clock_id', return_value=12345)
    @patch('builtins.print')
    def test_main_no_pins_found(self, _mock_print, _mock_clock):
        """Should return -1 when no matching pins found."""
        mock_dpll = MagicMock()
        mock_pins = MagicMock()
        mock_pins.__len__ = lambda self_: 0
        mock_dpll.get_all_pins.return_value.filter_by_device_clock_id.return_value \
            .filter_by_pin_board_label.return_value = mock_pins
        with patch('sys.argv', ['prog', 'eth0', 'INVALID', 'input']), \
             patch.object(cncp, 'NetlinkDPLL', return_value=mock_dpll):
            return_code = cncp.main()
        self.assertEqual(return_code, -1)

    @patch.object(cncp, 'get_clock_id', return_value=12345)
    @patch('builtins.print')
    def test_main_set_pin_direction_fails(self, _mock_print, _mock_clock):
        """Should return -1 when set_pin_direction raises."""
        mock_dpll = MagicMock()
        mock_pins = MagicMock()
        mock_pin = MagicMock()
        mock_pin.pin_id = 42
        mock_pins.__len__ = lambda self_: 1
        mock_pins.__iter__ = lambda self_: iter([mock_pin])
        mock_dpll.get_all_pins.return_value.filter_by_device_clock_id.return_value \
            .filter_by_pin_board_label.return_value = mock_pins
        mock_dpll.set_pin_direction.side_effect = Exception('netlink error')
        with patch('sys.argv', ['prog', 'eth0', 'SMA1', 'output']), \
             patch.object(cncp, 'NetlinkDPLL', return_value=mock_dpll):
            return_code = cncp.main()
        self.assertEqual(return_code, -1)

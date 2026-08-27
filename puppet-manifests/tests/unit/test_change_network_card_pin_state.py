#
# Copyright (c) 2026 Wind River Systems, Inc.
#
# SPDX-License-Identifier: Apache-2.0
#
"""Tests for change_network_card_pin_state module."""

import importlib.util
import os
import sys
import types
import unittest
from unittest import mock

_TESTS_DIR = os.path.dirname(os.path.abspath(__file__))
_PUPPET_MANIFESTS_DIR = os.path.abspath(os.path.join(_TESTS_DIR, '..', '..'))
SCRIPT_PATH = os.path.join(
    _PUPPET_MANIFESTS_DIR,
    'debian', 'bullseye', 'src', 'modules', 'platform', 'files',
    'change_network_card_pin_state.py')

_SCRIPT_EXISTS = os.path.isfile(SCRIPT_PATH)


class FakePin:  # pylint: disable=too-few-public-methods
    def __init__(self, pin_id):
        self.pin_id = pin_id


class FakePinSet:
    def __init__(self, pins=None):
        self._pins = pins or []

    def filter_by_pin_package_label(self, label):  # pylint: disable=unused-argument
        return self._pins

    def __len__(self):
        return len(self._pins)

    def __iter__(self):
        return iter(self._pins)


class FakeNetlinkDPLL:
    def __init__(self):
        self.set_pin_calls = []

    def get_all_pins(self):
        """Return all pins."""
        _ = self.set_pin_calls  # access instance state
        return FakePinSet([FakePin(42)])

    def set_pin_state(self, pin_id, state):
        self.set_pin_calls.append((pin_id, state))


def _load_module():
    """Load the script as a module with pynetlink stubbed."""
    fake_pynetlink = types.ModuleType('pynetlink')
    fake_pynetlink.NetlinkDPLL = FakeNetlinkDPLL
    with mock.patch.dict(sys.modules, {'pynetlink': fake_pynetlink}):
        spec = importlib.util.spec_from_file_location(
            'change_network_card_pin_state', SCRIPT_PATH)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
    return mod


@unittest.skipUnless(_SCRIPT_EXISTS, "Script not present in this distro")
class TestMain(unittest.TestCase):

    def setUp(self):
        self.mod = _load_module()

    @mock.patch('sys.argv', ['prog', '--pin_package_label', 'REF4P',
                              '--state', 'disconnected'])
    def test_main_success(self):
        """Verify main returns 0 on successful pin change."""
        return_code = self.mod.main()
        self.assertEqual(return_code, 0)

    @mock.patch('sys.argv', ['prog', '--pin_package_label', 'REF4P',
                              '--state', 'selectable'])
    def test_main_no_pins(self):
        """Verify main returns 0 when no pins are found."""
        with mock.patch.object(FakeNetlinkDPLL, 'get_all_pins',
                               return_value=FakePinSet([])):
            return_code = self.mod.main()
        self.assertEqual(return_code, 0)

    @mock.patch('sys.argv', ['prog', '--pin_package_label', 'REF4P',
                              '--state', 'disconnected'])
    def test_main_exception(self):
        """Verify main returns 1 when an exception occurs."""
        with mock.patch.object(FakeNetlinkDPLL, 'get_all_pins',
                               side_effect=RuntimeError('fail')):
            return_code = self.mod.main()
        self.assertEqual(return_code, 1)

#
# Copyright (c) 2026 Wind River Systems, Inc.
#
# SPDX-License-Identifier: Apache-2.0
#


# @patch decorators inject unused mock args, tests access private methods,
# and dynamically loaded modules have no visible members to pylint.

"""Unit tests for dual-stack-*.py scripts.

These scripts contain utility functions for managing
Kubernetes dual-stack networking configuration. The scripts
have module-level side effects (time.sleep, sys.exit) that
must be mocked during import.
"""

import os
import tempfile
import unittest
from unittest.mock import MagicMock
from unittest.mock import mock_open
from unittest.mock import patch


def _safe_import(module_name):
    """Import a dual-stack module safely.

    Delegates to the shared safe_import_module helper.

    Args:
        module_name: Dotted module name to import.

    Returns:
        The loaded module object.
    """
    from tests.test_helpers import safe_import_module
    return safe_import_module(module_name)


# Attempt to import each module safely; set to None on failure.
try:
    calico = _safe_import('debian.bullseye.src.bin.dual-stack-calico')
except (ImportError, SyntaxError, AttributeError, OSError):
    calico = None

try:
    kubeadm = _safe_import('debian.bullseye.src.bin.dual-stack-kubeadm')
except (ImportError, SyntaxError, AttributeError, OSError):
    kubeadm = None

try:
    kubelet = _safe_import('debian.bullseye.src.bin.dual-stack-kubelet')
except (ImportError, SyntaxError, AttributeError, OSError):
    kubelet = None

try:
    kubeproxy = _safe_import('debian.bullseye.src.bin.dual-stack-kubeproxy')
except (ImportError, SyntaxError, AttributeError, OSError):
    kubeproxy = None

try:
    multus = _safe_import('debian.bullseye.src.bin.dual-stack-multus')
except (ImportError, SyntaxError, AttributeError, OSError):
    multus = None


@unittest.skipIf(calico is None, "dual-stack-calico could not be imported")
class TestGetYamlDataCalico(unittest.TestCase):
    """Tests for get_yaml_data from dual-stack-calico."""

    @patch('subprocess.run')
    def test_valid_yaml_returned(self, mock_run):
        """get_yaml_data returns parsed YAML on successful command."""
        mock_run.return_value = MagicMock(
            returncode=0, stdout=b'key: value\n')
        result = calico.get_yaml_data(['cmd'])
        self.assertEqual(result, {'key': 'value'})

    @patch('subprocess.run')
    def test_returns_empty_dict_default(self, mock_run):
        """get_yaml_data returns empty dict when command
        always fails.
        """
        mock_run.return_value = MagicMock(returncode=1)
        with patch('time.sleep'):
            result = calico.get_yaml_data(['cmd'], attempts=1)
        self.assertEqual(result, {})

    @patch('subprocess.run')
    def test_retry_then_succeed(self, mock_run):
        """get_yaml_data retries on failure then returns
        data on success.
        """
        fail = MagicMock(returncode=1)
        success = MagicMock(returncode=0, stdout=b'a: 1\n')
        mock_run.side_effect = [fail, success]
        with patch('time.sleep'):
            result = calico.get_yaml_data(['cmd'], attempts=3)
        self.assertEqual(result, {'a': 1})
        self.assertEqual(mock_run.call_count, 2)

    @patch('subprocess.run')
    def test_sleep_called_on_failure(self, mock_run):
        """get_yaml_data sleeps 5 seconds between retries."""
        fail = MagicMock(returncode=1)
        success = MagicMock(returncode=0, stdout=b'x: 1\n')
        mock_run.side_effect = [fail, success]
        with patch('time.sleep') as mock_sleep:
            calico.get_yaml_data(['cmd'], attempts=3)
        self.assertEqual(mock_sleep.call_args[0][0], 5)

    @patch('subprocess.run')
    def test_complex_yaml(self, mock_run):
        """get_yaml_data correctly parses multi-level YAML."""
        yaml_bytes = b'top:\n  nested: true\nitems:\n- a\n- b\n'
        mock_run.return_value = MagicMock(returncode=0, stdout=yaml_bytes)
        result = calico.get_yaml_data(['cmd'])
        self.assertEqual(result['top']['nested'], True)
        self.assertEqual(result['items'], ['a', 'b'])

    @patch('subprocess.run')
    def test_single_attempt_success(self, mock_run):
        """get_yaml_data succeeds on first attempt with attempts=1."""
        mock_run.return_value = MagicMock(
            returncode=0, stdout=b'ok: true\n')
        result = calico.get_yaml_data(['cmd'], attempts=1)
        self.assertEqual(result, {'ok': True})
        self.assertEqual(mock_run.call_count, 1)

    @patch('subprocess.run')
    def test_empty_yaml_output(self, mock_run):
        """get_yaml_data handles empty YAML output
        (returns None data).
        """
        mock_run.return_value = MagicMock(returncode=0, stdout=b'')
        result = calico.get_yaml_data(['cmd'])
        self.assertIsNone(result)


@unittest.skipIf(kubeadm is None, "dual-stack-kubeadm could not be imported")
class TestGetYamlDataKubeadm(unittest.TestCase):
    """Tests for get_yaml_data from dual-stack-kubeadm."""

    @patch('subprocess.run')
    def test_valid_yaml(self, mock_run):
        """get_yaml_data in kubeadm returns parsed YAML on success."""
        mock_run.return_value = MagicMock(
            returncode=0, stdout=b'data: hello\n')
        result = kubeadm.get_yaml_data(['cmd'])
        self.assertEqual(result, {'data': 'hello'})

    @patch('subprocess.run')
    def test_retry_on_failure(self, mock_run):
        """get_yaml_data in kubeadm retries on command failure."""
        fail = MagicMock(returncode=1)
        success = MagicMock(returncode=0, stdout=b'v: 2\n')
        mock_run.side_effect = [fail, fail, success]
        with patch('time.sleep'):
            result = kubeadm.get_yaml_data(['cmd'], attempts=5)
        self.assertEqual(result, {'v': 2})


@unittest.skipIf(kubelet is None, "dual-stack-kubelet could not be imported")
class TestGetYamlDataKubelet(unittest.TestCase):
    """Tests for get_yaml_data from dual-stack-kubelet."""

    @patch('subprocess.run')
    def test_valid_yaml(self, mock_run):
        """get_yaml_data in kubelet returns parsed YAML on success."""
        mock_run.return_value = MagicMock(
            returncode=0, stdout=b'status: ok\n')
        result = kubelet.get_yaml_data(['cmd'])
        self.assertEqual(result, {'status': 'ok'})

    @patch('subprocess.run')
    def test_all_attempts_fail(self, mock_run):
        """get_yaml_data in kubelet returns empty dict
        when all attempts fail.
        """
        mock_run.return_value = MagicMock(returncode=1)
        with patch('time.sleep'):
            result = kubelet.get_yaml_data(['cmd'], attempts=2)
        self.assertEqual(result, {})


@unittest.skipIf(kubeproxy is None, "dual-stack-kubeproxy could not be imported")
class TestGetYamlDataKubeproxy(unittest.TestCase):
    """Tests for get_yaml_data from dual-stack-kubeproxy."""

    @patch('subprocess.run')
    def test_valid_yaml(self, mock_run):
        """get_yaml_data in kubeproxy returns parsed YAML on success."""
        mock_run.return_value = MagicMock(
            returncode=0, stdout=b'proxy: true\n')
        result = kubeproxy.get_yaml_data(['cmd'])
        self.assertEqual(result, {'proxy': True})

    @patch('subprocess.run')
    def test_retry_then_succeed(self, mock_run):
        """get_yaml_data in kubeproxy retries then succeeds."""
        fail = MagicMock(returncode=1)
        success = MagicMock(returncode=0, stdout=b'r: 1\n')
        mock_run.side_effect = [fail, success]
        with patch('time.sleep'):
            result = kubeproxy.get_yaml_data(['cmd'], attempts=3)
        self.assertEqual(result, {'r': 1})


@unittest.skipIf(calico is None, "dual-stack-calico could not be imported")
class TestIsValidIpCalico(unittest.TestCase):
    """Tests for is_valid_ip from dual-stack-calico."""

    def test_valid_ipv4(self):
        """is_valid_ip returns True for a valid IPv4 address."""
        self.assertTrue(calico.is_valid_ip('192.168.1.1'))

    def test_valid_ipv6(self):
        """is_valid_ip returns True for a valid IPv6 address."""
        self.assertTrue(calico.is_valid_ip('fd01::1'))

    def test_valid_ipv6_full(self):
        """is_valid_ip returns True for a full IPv6 address."""
        self.assertTrue(calico.is_valid_ip('2001:0db8:85a3:0000:0000:8a2e:0370:7334'))

    def test_invalid_ip(self):
        """is_valid_ip returns False for an invalid address."""
        self.assertFalse(calico.is_valid_ip('not-an-ip'))

    def test_empty_string(self):
        """is_valid_ip returns False for an empty string."""
        self.assertFalse(calico.is_valid_ip(''))

    def test_ipv4_loopback(self):
        """is_valid_ip returns True for IPv4 loopback."""
        self.assertTrue(calico.is_valid_ip('127.0.0.1'))

    def test_ipv6_loopback(self):
        """is_valid_ip returns True for IPv6 loopback."""
        self.assertTrue(calico.is_valid_ip('::1'))


@unittest.skipIf(kubeadm is None, "dual-stack-kubeadm could not be imported")
class TestIsValidIpKubeadm(unittest.TestCase):
    """Tests for is_valid_ip from dual-stack-kubeadm."""

    def test_valid_ipv4(self):
        """is_valid_ip in kubeadm returns True for valid IPv4."""
        self.assertTrue(kubeadm.is_valid_ip('10.0.0.1'))

    def test_valid_ipv6(self):
        """is_valid_ip in kubeadm returns True for valid IPv6."""
        self.assertTrue(kubeadm.is_valid_ip('fe80::1'))

    def test_invalid(self):
        """is_valid_ip in kubeadm returns False for garbage input."""
        self.assertFalse(kubeadm.is_valid_ip('xyz'))


@unittest.skipIf(kubelet is None, "dual-stack-kubelet could not be imported")
class TestIsValidIpKubelet(unittest.TestCase):
    """Tests for is_valid_ip from dual-stack-kubelet."""

    def test_valid_ipv4(self):
        """is_valid_ip in kubelet returns True for valid IPv4."""
        self.assertTrue(kubelet.is_valid_ip('172.16.0.1'))

    def test_invalid(self):
        """is_valid_ip in kubelet returns False for invalid input."""
        self.assertFalse(kubelet.is_valid_ip('bad'))

    def test_empty(self):
        """is_valid_ip in kubelet returns False for empty string."""
        self.assertFalse(kubelet.is_valid_ip(''))


@unittest.skipIf(kubeadm is None, "dual-stack-kubeadm could not be imported")
class TestIsValidNetworkKubeadm(unittest.TestCase):
    """Tests for is_valid_network from dual-stack-kubeadm."""

    def test_valid_ipv4_cidr(self):
        """is_valid_network returns True for valid IPv4 CIDR."""
        self.assertTrue(kubeadm.is_valid_network('10.0.0.0/24'))

    def test_valid_ipv6_cidr(self):
        """is_valid_network returns True for valid IPv6 CIDR."""
        self.assertTrue(kubeadm.is_valid_network('fd01::/64'))

    def test_invalid_cidr(self):
        """is_valid_network returns False for invalid CIDR."""
        self.assertFalse(kubeadm.is_valid_network('not-a-network'))

    def test_plain_ipv4_address(self):
        """is_valid_network returns True for a plain IPv4
        (treated as /32).
        """
        self.assertTrue(kubeadm.is_valid_network('192.168.1.1'))

    def test_empty_string(self):
        """is_valid_network returns False for empty string."""
        self.assertFalse(kubeadm.is_valid_network(''))


@unittest.skipIf(kubeproxy is None, "dual-stack-kubeproxy could not be imported")
class TestIsValidNetworkKubeproxy(unittest.TestCase):
    """Tests for is_valid_network from dual-stack-kubeproxy."""

    def test_valid_ipv4_cidr(self):
        """is_valid_network in kubeproxy returns True
        for valid IPv4 CIDR.
        """
        self.assertTrue(kubeproxy.is_valid_network('172.16.0.0/16'))

    def test_valid_ipv6_cidr(self):
        """is_valid_network in kubeproxy returns True
        for valid IPv6 CIDR.
        """
        self.assertTrue(kubeproxy.is_valid_network('fd00::/48'))

    def test_invalid(self):
        """is_valid_network in kubeproxy returns False for garbage."""
        self.assertFalse(kubeproxy.is_valid_network('garbage'))


@unittest.skipIf(calico is None, "dual-stack-calico could not be imported")
class TestPrependTimestampLineCalico(unittest.TestCase):
    """Tests for prepend_timestamp_line from dual-stack-calico."""

    def test_inserts_timestamp_at_top(self):
        """prepend_timestamp_line inserts a timestamp
        comment as first line.
        """
        with tempfile.NamedTemporaryFile(mode='w', suffix='.yaml',
                                         delete=False) as file_handle:
            file_handle.write('line1\nline2\n')
            tmpname = file_handle.name
        try:
            calico.prepend_timestamp_line(tmpname)
            with open(tmpname, 'r', encoding='utf-8') as file_handle:
                first_line = file_handle.readline()
            self.assertTrue(first_line.startswith('# generated at'))
        finally:
            os.unlink(tmpname)

    def test_timestamp_format(self):
        """prepend_timestamp_line writes a line starting
        with '# generated at'.
        """
        with tempfile.NamedTemporaryFile(mode='w', suffix='.yaml',
                                         delete=False) as file_handle:
            file_handle.write('original line\n')
            tmpname = file_handle.name
        try:
            calico.prepend_timestamp_line(tmpname)
            with open(tmpname, 'r', encoding='utf-8') as file_handle:
                lines = file_handle.readlines()
            self.assertTrue(lines[0].startswith('# generated at'))
            self.assertEqual(lines[1], 'original line\n')
        finally:
            os.unlink(tmpname)

    def test_preserves_original_content(self):
        """prepend_timestamp_line preserves all original
        file content.
        """
        with tempfile.NamedTemporaryFile(mode='w', suffix='.yaml',
                                         delete=False) as file_handle:
            file_handle.write('first\nsecond\nthird\n')
            tmpname = file_handle.name
        try:
            calico.prepend_timestamp_line(tmpname)
            with open(tmpname, 'r', encoding='utf-8') as file_handle:
                lines = file_handle.readlines()
            self.assertEqual(len(lines), 4)  # timestamp + 3 original
            self.assertEqual(lines[1], 'first\n')
            self.assertEqual(lines[2], 'second\n')
            self.assertEqual(lines[3], 'third\n')
        finally:
            os.unlink(tmpname)


@unittest.skipIf(kubeadm is None, "dual-stack-kubeadm could not be imported")
class TestPrependTimestampLineKubeadm(unittest.TestCase):
    """Tests for prepend_timestamp_line from dual-stack-kubeadm."""

    def test_inserts_timestamp(self):
        """prepend_timestamp_line in kubeadm inserts
        timestamp at top.
        """
        with tempfile.NamedTemporaryFile(mode='w', suffix='.yaml',
                                         delete=False) as file_handle:
            file_handle.write('content\n')
            tmpname = file_handle.name
        try:
            kubeadm.prepend_timestamp_line(tmpname)
            with open(tmpname, 'r', encoding='utf-8') as file_handle:
                first_line = file_handle.readline()
            self.assertTrue(first_line.startswith('# generated at'))
        finally:
            os.unlink(tmpname)


@unittest.skipIf(kubeproxy is None, "dual-stack-kubeproxy could not be imported")
class TestPrependTimestampLineKubeproxy(unittest.TestCase):
    """Tests for prepend_timestamp_line from dual-stack-kubeproxy."""

    def test_inserts_timestamp(self):
        """prepend_timestamp_line in kubeproxy inserts
        timestamp at top.
        """
        with tempfile.NamedTemporaryFile(mode='w', suffix='.yaml',
                                         delete=False) as file_handle:
            file_handle.write('data\n')
            tmpname = file_handle.name
        try:
            kubeproxy.prepend_timestamp_line(tmpname)
            with open(tmpname, 'r', encoding='utf-8') as file_handle:
                first_line = file_handle.readline()
            self.assertTrue(first_line.startswith('# generated at'))
        finally:
            os.unlink(tmpname)


@unittest.skipIf(multus is None, "dual-stack-multus could not be imported")
class TestPrependTimestampLineMultus(unittest.TestCase):
    """Tests for prepend_timestamp_line from dual-stack-multus."""

    def test_inserts_timestamp(self):
        """prepend_timestamp_line in multus inserts timestamp at top."""
        with tempfile.NamedTemporaryFile(mode='w', suffix='.yaml',
                                         delete=False) as file_handle:
            file_handle.write('multus data\n')
            tmpname = file_handle.name
        try:
            multus.prepend_timestamp_line(tmpname)
            with open(tmpname, 'r', encoding='utf-8') as file_handle:
                first_line = file_handle.readline()
            self.assertTrue(first_line.startswith('# generated at'))
        finally:
            os.unlink(tmpname)

    def test_timestamp_has_newline(self):
        """prepend_timestamp_line adds a newline after the timestamp."""
        with tempfile.NamedTemporaryFile(mode='w', suffix='.yaml',
                                         delete=False) as file_handle:
            file_handle.write('line\n')
            tmpname = file_handle.name
        try:
            multus.prepend_timestamp_line(tmpname)
            with open(tmpname, 'r', encoding='utf-8') as file_handle:
                lines = file_handle.readlines()
            self.assertTrue(lines[0].endswith('\n'))
        finally:
            os.unlink(tmpname)


@unittest.skipIf(calico is None, "dual-stack-calico could not be imported")
class TestSaveConfigmapCalico(unittest.TestCase):
    """Tests for save_configmap from dual-stack-calico."""

    @patch('builtins.open', mock_open())
    @patch('subprocess.run')
    def test_retry_then_succeed(self, mock_run):
        """save_configmap retries on failure then saves on success."""
        fail = MagicMock(returncode=1)
        success = MagicMock(returncode=0, stdout=b'data')
        mock_run.side_effect = [fail, success]
        with patch('time.sleep'):
            calico.save_configmap(['cmd'], '/tmp/test.yaml')
        self.assertEqual(mock_run.call_count, 2)

    @patch('builtins.open', mock_open())
    @patch('subprocess.run')
    def test_sleep_between_retries(self, mock_run):
        """save_configmap sleeps 5 seconds between retries."""
        fail = MagicMock(returncode=1)
        success = MagicMock(returncode=0, stdout=b'ok')
        mock_run.side_effect = [fail, success]
        with patch('time.sleep') as mock_sleep:
            calico.save_configmap(['cmd'], '/tmp/out.yaml')
        self.assertEqual(mock_sleep.call_args[0][0], 5)

    @patch('subprocess.run')
    def test_writes_encoded_output(self, mock_run):
        """save_configmap writes command stdout encoded to the file."""
        mock_run.return_value = MagicMock(
            returncode=0, stdout=b'yaml: content\n')
        tmpname = tempfile.mktemp(suffix='.yaml')
        try:
            calico.save_configmap(['cmd'], tmpname)
            with open(tmpname, 'rb') as file_handle:
                content = file_handle.read()
            self.assertEqual(content, b'yaml: content\n')
        finally:
            if os.path.exists(tmpname):
                os.unlink(tmpname)


@unittest.skipIf(multus is None, "dual-stack-multus could not be imported")
class TestSaveConfigmapMultus(unittest.TestCase):
    """Tests for save_configmap from dual-stack-multus."""

    @patch('builtins.open', mock_open())
    @patch('subprocess.run')
    def test_retry_on_failure(self, mock_run):
        """save_configmap in multus retries on command failure."""
        fail = MagicMock(returncode=1)
        success = MagicMock(returncode=0, stdout=b'ok')
        mock_run.side_effect = [fail, fail, success]
        with patch('time.sleep'):
            multus.save_configmap(['cmd'], '/tmp/multus.yaml')
        self.assertEqual(mock_run.call_count, 3)


class TestFunctionExistence(unittest.TestCase):
    """Verify expected functions exist in each dual-stack module."""

    @unittest.skipIf(calico is None, "dual-stack-calico could not be imported")
    def test_calico_has_get_yaml_data(self):
        """dual-stack-calico exposes get_yaml_data."""
        self.assertTrue(callable(getattr(calico, 'get_yaml_data', None)))

    @unittest.skipIf(calico is None, "dual-stack-calico could not be imported")
    def test_calico_has_is_valid_ip(self):
        """dual-stack-calico exposes is_valid_ip."""
        self.assertTrue(callable(getattr(calico, 'is_valid_ip', None)))

    @unittest.skipIf(calico is None, "dual-stack-calico could not be imported")
    def test_calico_has_prepend_timestamp_line(self):
        """dual-stack-calico exposes prepend_timestamp_line."""
        self.assertTrue(callable(getattr(calico, 'prepend_timestamp_line', None)))

    @unittest.skipIf(calico is None, "dual-stack-calico could not be imported")
    def test_calico_has_save_configmap(self):
        """dual-stack-calico exposes save_configmap."""
        self.assertTrue(callable(getattr(calico, 'save_configmap', None)))

    @unittest.skipIf(kubeadm is None, "dual-stack-kubeadm could not be imported")
    def test_kubeadm_has_get_yaml_data(self):
        """dual-stack-kubeadm exposes get_yaml_data."""
        self.assertTrue(callable(getattr(kubeadm, 'get_yaml_data', None)))

    @unittest.skipIf(kubeadm is None, "dual-stack-kubeadm could not be imported")
    def test_kubeadm_has_is_valid_ip(self):
        """dual-stack-kubeadm exposes is_valid_ip."""
        self.assertTrue(callable(getattr(kubeadm, 'is_valid_ip', None)))

    @unittest.skipIf(kubeadm is None, "dual-stack-kubeadm could not be imported")
    def test_kubeadm_has_is_valid_network(self):
        """dual-stack-kubeadm exposes is_valid_network."""
        self.assertTrue(callable(getattr(kubeadm, 'is_valid_network', None)))

    @unittest.skipIf(kubelet is None, "dual-stack-kubelet could not be imported")
    def test_kubelet_has_get_yaml_data(self):
        """dual-stack-kubelet exposes get_yaml_data."""
        self.assertTrue(callable(getattr(kubelet, 'get_yaml_data', None)))

    @unittest.skipIf(kubelet is None, "dual-stack-kubelet could not be imported")
    def test_kubelet_has_is_valid_ip(self):
        """dual-stack-kubelet exposes is_valid_ip."""
        self.assertTrue(callable(getattr(kubelet, 'is_valid_ip', None)))

    @unittest.skipIf(kubeproxy is None, "dual-stack-kubeproxy could not be imported")
    def test_kubeproxy_has_get_yaml_data(self):
        """dual-stack-kubeproxy exposes get_yaml_data."""
        self.assertTrue(callable(getattr(kubeproxy, 'get_yaml_data', None)))

    @unittest.skipIf(kubeproxy is None, "dual-stack-kubeproxy could not be imported")
    def test_kubeproxy_has_is_valid_network(self):
        """dual-stack-kubeproxy exposes is_valid_network."""
        self.assertTrue(callable(getattr(kubeproxy, 'is_valid_network', None)))

    @unittest.skipIf(multus is None, "dual-stack-multus could not be imported")
    def test_multus_has_prepend_timestamp_line(self):
        """dual-stack-multus exposes prepend_timestamp_line."""
        self.assertTrue(callable(getattr(multus, 'prepend_timestamp_line', None)))

    @unittest.skipIf(multus is None, "dual-stack-multus could not be imported")
    def test_multus_has_save_configmap(self):
        """dual-stack-multus exposes save_configmap."""
        self.assertTrue(callable(getattr(multus, 'save_configmap', None)))

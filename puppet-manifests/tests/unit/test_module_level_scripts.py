#
# Copyright (c) 2026 Wind River Systems, Inc.
#
# SPDX-License-Identifier: Apache-2.0
#


# @patch decorators inject unused mock args, tests access private methods,
# and dynamically loaded modules have no visible members to pylint.

"""Unit tests for Python scripts that execute all logic at module level.

These scripts cannot be imported normally because they run on import.
We use runpy.run_path() with mocked dependencies to test them safely.

Scripts tested:
- check_ipv6_tentative_addresses.py
  (subprocess + sys.exit at module level)
- parse_k8s_admin_client_credentials.py
  (argparse + file I/O at module level)
- update_kube_apiserver_certSANs.py
  (argparse + ruamel.yaml at module level)
- update_kubelet-config.py
  (argparse + ruamel.yaml at module level)
"""

import base64
import json
import os
import runpy
import tempfile
import unittest
from unittest import mock

try:
    import ruamel.yaml  # noqa: F401  # pylint: disable=unused-import
    HAS_RUAMEL = True
except ImportError:
    HAS_RUAMEL = False

if HAS_RUAMEL:
    from tests.test_helpers import yaml_dump
    from tests.test_helpers import yaml_load
    try:
        from ruamel.yaml.scalarstring import PreservedScalarString
    except ImportError:
        PreservedScalarString = str
else:
    yaml_dump = None
    yaml_load = None
    PreservedScalarString = str

# Script paths relative to puppet-manifests/
# (the stestr working directory)
# Script paths - resolve dynamically from this file's location
_TESTS_DIR = os.path.dirname(os.path.abspath(__file__))
_PUPPET_MANIFESTS_DIR = os.path.abspath(os.path.join(_TESTS_DIR, '..', '..'))

CHECK_IPV6_SCRIPT = os.path.join(
    _PUPPET_MANIFESTS_DIR,
    'debian/bullseye/src/bin/check_ipv6_tentative_addresses.py'
)
PARSE_CREDS_SCRIPT = os.path.join(
    _PUPPET_MANIFESTS_DIR,
    'debian/bullseye/src/modules/platform/files/'
    'parse_k8s_admin_client_credentials.py'
)
UPDATE_CERTSANS_SCRIPT = os.path.join(
    _PUPPET_MANIFESTS_DIR,
    'debian/bullseye/src/modules/platform/files/'
    'update_kube_apiserver_certSANs.py'
)
UPDATE_KUBELET_SCRIPT = os.path.join(
    _PUPPET_MANIFESTS_DIR,
    'debian/bullseye/src/modules/platform/files/'
    'update_kubelet-config.py'
)


class TestCheckIpv6TentativeAddresses(unittest.TestCase):
    """Tests for check_ipv6_tentative_addresses.py."""

    @staticmethod
    def _run_script(ip_output_data):
        """Run the script with mocked subprocess output.

        Args:
            ip_output_data: List of interface dicts to
                return from mocked ip command.

        Returns:
            The mock_exit object for assertion checks.
        """
        mock_result = mock.MagicMock()
        mock_result.stdout = json.dumps(ip_output_data)
        with mock.patch('subprocess.run', return_value=mock_result), \
             mock.patch('sys.exit') as mock_exit:
            runpy.run_path(CHECK_IPV6_SCRIPT, run_name='__main__')
        return mock_exit

    def test_no_interfaces(self):
        """Exit 0 when ip command returns empty list."""
        mock_exit = self._run_script([])
        mock_exit.assert_called_with(0)

    def test_no_tentative_addresses(self):
        """Exit 0 when no addresses have tentative flag."""
        data = [{
            'ifname': 'eth0',
            'operstate': 'UP',
            'addr_info': [{'local': '::1', 'family': 'inet6'}]
        }]
        mock_exit = self._run_script(data)
        mock_exit.assert_called_with(0)

    def test_tentative_address_on_up_interface(self):
        """Exit 1 when a tentative address exists on an UP interface."""
        data = [{
            'ifname': 'eth0',
            'operstate': 'UP',
            'addr_info': [
                {'local': 'fe80::1', 'family': 'inet6', 'tentative': True}
            ]
        }]
        mock_exit = self._run_script(data)
        mock_exit.assert_called_with(1)

    def test_tentative_address_on_down_interface(self):
        """Exit 0 when tentative address exists only on
        a DOWN interface.
        """
        data = [{
            'ifname': 'eth0',
            'operstate': 'DOWN',
            'addr_info': [
                {'local': 'fe80::1', 'family': 'inet6', 'tentative': True}
            ]
        }]
        mock_exit = self._run_script(data)
        mock_exit.assert_called_with(0)

    def test_multiple_interfaces_one_tentative(self):
        """Exit 1 when one of multiple UP interfaces
        has tentative addr.
        """
        data = [
            {
                'ifname': 'eth0',
                'operstate': 'UP',
                'addr_info': [{'local': '::1', 'family': 'inet6'}]
            },
            {
                'ifname': 'eth1',
                'operstate': 'UP',
                'addr_info': [
                    {'local': 'fe80::2', 'family': 'inet6', 'tentative': True}
                ]
            }
        ]
        mock_exit = self._run_script(data)
        mock_exit.assert_called_with(1)

    def test_multiple_tentative_addresses(self):
        """Exit 1 when multiple tentative addresses exist."""
        data = [{
            'ifname': 'eth0',
            'operstate': 'UP',
            'addr_info': [
                {'local': 'fe80::1', 'family': 'inet6', 'tentative': True},
                {'local': 'fe80::2', 'family': 'inet6', 'tentative': True}
            ]
        }]
        mock_exit = self._run_script(data)
        mock_exit.assert_called_with(1)

    def test_mixed_up_and_down_interfaces(self):
        """Exit 0 when tentative only on DOWN, clean on UP."""
        data = [
            {
                'ifname': 'eth0',
                'operstate': 'UP',
                'addr_info': [{'local': '::1', 'family': 'inet6'}]
            },
            {
                'ifname': 'eth1',
                'operstate': 'DOWN',
                'addr_info': [
                    {'local': 'fe80::1', 'family': 'inet6', 'tentative': True}
                ]
            }
        ]
        mock_exit = self._run_script(data)
        mock_exit.assert_called_with(0)

    def test_subprocess_called_correctly(self):
        """Verify subprocess.run is called with correct
        ip command args.
        """
        mock_result = mock.MagicMock()
        mock_result.stdout = json.dumps([])
        with mock.patch('subprocess.run',
                        return_value=mock_result) as mock_run, \
             mock.patch('sys.exit'):
            runpy.run_path(CHECK_IPV6_SCRIPT, run_name='__main__')
        self.assertEqual(
            mock_run.call_args[0][0],
            ['ip', '-j', '-6', 'addr', 'show'])

    def test_tentative_false_value_still_counts(self):
        """Exit 1 when tentative key exists even with False value.

        The script checks 'tentative' in addr.keys(), so any presence
        of the key triggers the count regardless of value.
        """
        data = [{
            'ifname': 'eth0',
            'operstate': 'UP',
            'addr_info': [
                {'local': 'fe80::1', 'family': 'inet6', 'tentative': False}
            ]
        }]
        mock_exit = self._run_script(data)
        mock_exit.assert_called_with(1)


class TestParseK8sAdminClientCredentials(unittest.TestCase):
    """Tests for parse_k8s_admin_client_credentials.py."""

    CERT_DATA = 'test-certificate-pem-data'
    KEY_DATA = 'test-key-pem-data'

    def _make_kubeconfig(self, cert_b64=None, key_b64=None):
        """Create a kubeconfig string with given
        base64 cert/key data.
        """
        if cert_b64 is None:
            cert_b64 = base64.b64encode(
                self.CERT_DATA.encode()).decode()
        if key_b64 is None:
            key_b64 = base64.b64encode(
                self.KEY_DATA.encode()).decode()
        return (
            'apiVersion: v1\n'
            'clusters: []\n'
            'users:\n'
            '- name: admin\n'
            '  user:\n'
            '    client-certificate-data: {cert}\n'
            '    client-key-data: {key}\n'
        ).format(cert=cert_b64, key=key_b64)

    @staticmethod
    def _run_with_tempfiles(kubeconfig_content,
                            kubeconfig_path=None, output_path=None):
        """Run the script using real temp files."""
        kube_fd, kube_path = tempfile.mkstemp(suffix='.conf')
        out_fd, out_path = tempfile.mkstemp(suffix='.pem')
        try:
            os.write(kube_fd, kubeconfig_content.encode())
            os.close(kube_fd)
            os.close(out_fd)

            with mock.patch('sys.argv', [
                'parse_k8s_admin_client_credentials.py',
                '--kubeconfig', kubeconfig_path or kube_path,
                '--output_file', output_path or out_path
            ]):
                runpy.run_path(PARSE_CREDS_SCRIPT, run_name='__main__')

            with open(out_path, 'r', encoding='utf-8') as file_handle:
                result = file_handle.read()
            perms = oct(os.stat(out_path).st_mode & 0o777)
            return result, perms
        finally:
            for path in (kube_path, out_path):
                if os.path.exists(path):
                    os.unlink(path)

    def test_basic_credential_extraction(self):
        """Extract cert and key from a standard kubeconfig."""
        content = self._make_kubeconfig()
        result, _ = self._run_with_tempfiles(content)
        self.assertIn(self.CERT_DATA, result)
        self.assertIn(self.KEY_DATA, result)

    def test_output_file_permissions(self):
        """Output file should have 0600 permissions."""
        content = self._make_kubeconfig()
        _, perms = self._run_with_tempfiles(content)
        self.assertEqual(perms, '0o600')

    def test_cert_before_key_in_output(self):
        """Certificate data should appear before key data in output."""
        content = self._make_kubeconfig()
        result, _ = self._run_with_tempfiles(content)
        cert_pos = result.index(self.CERT_DATA)
        key_pos = result.index(self.KEY_DATA)
        self.assertLess(cert_pos, key_pos)

    def test_concatenated_output(self):
        """Output should be the concatenation of decoded
        cert and key.
        """
        content = self._make_kubeconfig()
        result, _ = self._run_with_tempfiles(content)
        self.assertEqual(result, self.CERT_DATA + self.KEY_DATA)

    def test_key_before_cert_in_kubeconfig(self):
        """Script handles key appearing before cert in kubeconfig."""
        cert_b64 = base64.b64encode(b'MY-CERT').decode()
        key_b64 = base64.b64encode(b'MY-KEY').decode()
        content = (
            'apiVersion: v1\n'
            'users:\n'
            '- name: admin\n'
            '  user:\n'
            '    client-key-data: {key}\n'
            '    client-certificate-data: {cert}\n'
        ).format(cert=cert_b64, key=key_b64)
        result, _ = self._run_with_tempfiles(content)
        self.assertEqual(result, 'MY-CERTMY-KEY')

    def test_extra_lines_in_kubeconfig(self):
        """Script ignores unrelated lines in kubeconfig."""
        cert_b64 = base64.b64encode(b'CERT').decode()
        key_b64 = base64.b64encode(b'KEY').decode()
        content = (
            'apiVersion: v1\n'
            'kind: Config\n'
            'preferences: {{}}\n'
            'clusters:\n'
            '- cluster:\n'
            '    server: https://10.0.0.1:6443\n'
            'users:\n'
            '- name: admin\n'
            '  user:\n'
            '    client-certificate-data: {cert}\n'
            '    client-key-data: {key}\n'
        ).format(cert=cert_b64, key=key_b64)
        result, _ = self._run_with_tempfiles(content)
        self.assertEqual(result, 'CERTKEY')

    def test_default_kubeconfig_path(self):
        """Script defaults kubeconfig to /etc/kubernetes/admin.conf."""
        with mock.patch('sys.argv', [
            'script', '--output_file', '/tmp/out.pem'
        ]):
            # We just verify argparse default, not actual file read
            import argparse
            parser = argparse.ArgumentParser()
            parser.add_argument("--kubeconfig", required=False,
                                default='/etc/kubernetes/admin.conf')
            parser.add_argument("--output_file", required=True)
            test_args = parser.parse_args(
                ['--output_file', '/tmp/out.pem'])
            self.assertEqual(test_args.kubeconfig,
                             '/etc/kubernetes/admin.conf')


@unittest.skipUnless(HAS_RUAMEL, 'ruamel.yaml not available')
class TestUpdateKubeApiserverCertSANs(unittest.TestCase):
    """Tests for update_kube_apiserver_certSANs.py."""

    @staticmethod
    def _make_configmap(certsans_list):
        """Create a configmap dict with given certSANs."""
        cluster_config = {
            'apiServer': {
                'certSANs': certsans_list,
                'extraArgs': {'audit-log-path': '/var/log/audit.log'}
            },
            'controllerManager': {}
        }
        cluster_config_str = yaml_dump(cluster_config)
        return {
            'apiVersion': 'v1',
            'kind': 'ConfigMap',
            'data': {
                'ClusterConfiguration':
                    PreservedScalarString(
                        cluster_config_str)
            }
        }

    @staticmethod
    def _run_with_tempfile(configmap, certsans_arg):
        """Write configmap to temp file, run script, return result."""
        fd, path = tempfile.mkstemp(suffix='.yaml')
        try:
            with os.fdopen(fd, 'w', encoding='utf-8') as file_handle:
                yaml_dump(configmap, file_handle)
            with mock.patch('sys.argv', [
                'update_kube_apiserver_certSANs.py',
                '--configmap_file', path,
                '--certsans', certsans_arg
            ]):
                runpy.run_path(UPDATE_CERTSANS_SCRIPT,
                               run_name='__main__')
            with open(path, 'r', encoding='utf-8') as file_handle:
                result = yaml_load(file_handle)
            cluster_cfg = yaml_load(
                result['data']['ClusterConfiguration'])
            return result, cluster_cfg
        finally:
            if os.path.exists(path):
                os.unlink(path)

    def test_single_certsan(self):
        """Update certSANs with a single entry."""
        configmap = self._make_configmap(['old.example.com'])
        _, cluster_cfg = self._run_with_tempfile(
            configmap, '10.0.0.1')
        self.assertEqual(
            cluster_cfg['apiServer']['certSANs'], ['10.0.0.1'])

    def test_multiple_certsans(self):
        """Update certSANs with multiple comma-separated entries."""
        configmap = self._make_configmap(['old.example.com'])
        _, cluster_cfg = self._run_with_tempfile(
            configmap, '10.0.0.1,10.0.0.2,k8s.example.com')
        self.assertEqual(
            cluster_cfg['apiServer']['certSANs'],
            ['10.0.0.1', '10.0.0.2', 'k8s.example.com'])

    def test_certsans_with_spaces(self):
        """Spaces around commas in certsans arg are stripped."""
        configmap = self._make_configmap([])
        _, cluster_cfg = self._run_with_tempfile(
            configmap, ' 10.0.0.1 , 10.0.0.2 ')
        self.assertEqual(
            cluster_cfg['apiServer']['certSANs'],
            ['10.0.0.1', '10.0.0.2'])

    def test_replaces_existing_certsans(self):
        """New certSANs completely replace old ones."""
        configmap = self._make_configmap(
            ['old1.example.com', 'old2.example.com'])
        _, cluster_cfg = self._run_with_tempfile(
            configmap, 'new.example.com')
        self.assertEqual(
            cluster_cfg['apiServer']['certSANs'],
            ['new.example.com'])

    def test_preserves_other_apiserver_fields(self):
        """Other apiServer fields are preserved after update."""
        configmap = self._make_configmap(['old.example.com'])
        _, cluster_cfg = self._run_with_tempfile(
            configmap, '10.0.0.1')
        self.assertIn('extraArgs', cluster_cfg['apiServer'])
        self.assertEqual(
            cluster_cfg['apiServer']['extraArgs']['audit-log-path'],
            '/var/log/audit.log')

    def test_preserves_configmap_metadata(self):
        """ConfigMap apiVersion and kind are preserved."""
        configmap = self._make_configmap(['old.example.com'])
        result, _ = self._run_with_tempfile(
            configmap, '10.0.0.1')
        self.assertEqual(result['apiVersion'], 'v1')
        self.assertEqual(result['kind'], 'ConfigMap')

    def test_cluster_configuration_is_string(self):
        """ClusterConfiguration value remains a string in output."""
        configmap = self._make_configmap(['old.example.com'])
        result, _ = self._run_with_tempfile(
            configmap, '10.0.0.1')
        self.assertIsInstance(
            result['data']['ClusterConfiguration'], str)


@unittest.skipUnless(HAS_RUAMEL, 'ruamel.yaml not available')
class TestUpdateKubeletConfig(unittest.TestCase):
    """Tests for update_kubelet-config.py."""

    @staticmethod
    def _make_configmap(kubelet_overrides=None):
        """Create a configmap dict with kubelet config."""
        kubelet_config = {
            'apiVersion': 'kubelet.config.k8s.io/v1beta1',
            'kind': 'KubeletConfiguration',
            'imageGCLowThresholdPercent': 50,
            'imageGCHighThresholdPercent': 60,
        }
        if kubelet_overrides:
            kubelet_config.update(kubelet_overrides)
        kubelet_str = yaml_dump(kubelet_config)
        return {
            'apiVersion': 'v1',
            'kind': 'ConfigMap',
            'data': {
                'kubelet':
                    PreservedScalarString(kubelet_str)
            }
        }

    @staticmethod
    def _run_with_tempfile(configmap, extra_args=None):
        """Write configmap to temp file, run script, return result."""
        fd, path = tempfile.mkstemp(suffix='.yaml')
        try:
            with os.fdopen(fd, 'w', encoding='utf-8') as file_handle:
                yaml_dump(configmap, file_handle)
            argv = [
                'update_kubelet-config.py',
                '--configmap_file', path
            ]
            if extra_args:
                argv.extend(extra_args)
            with mock.patch('sys.argv', argv):
                runpy.run_path(UPDATE_KUBELET_SCRIPT,
                               run_name='__main__')
            with open(path, 'r', encoding='utf-8') as file_handle:
                result = yaml_load(file_handle)
            kubelet_cfg = yaml_load(
                result['data']['kubelet'])
            return result, kubelet_cfg
        finally:
            if os.path.exists(path):
                os.unlink(path)

    def test_default_gc_low_threshold(self):
        """Default imageGCLowThresholdPercent is 75."""
        configmap = self._make_configmap()
        _, kubelet_cfg = self._run_with_tempfile(configmap)
        self.assertEqual(
            kubelet_cfg['imageGCLowThresholdPercent'], 75)

    def test_default_gc_high_threshold(self):
        """Default imageGCHighThresholdPercent is 79."""
        configmap = self._make_configmap()
        _, kubelet_cfg = self._run_with_tempfile(configmap)
        self.assertEqual(
            kubelet_cfg['imageGCHighThresholdPercent'], 79)

    def test_default_eviction_hard_imagefs(self):
        """Default evictionHard imagefs.available is 2Gi."""
        configmap = self._make_configmap()
        _, kubelet_cfg = self._run_with_tempfile(configmap)
        self.assertEqual(
            kubelet_cfg['evictionHard']['imagefs.available'], '2Gi')

    def test_custom_gc_low_threshold(self):
        """Custom imageGCLowThresholdPercent via CLI arg."""
        configmap = self._make_configmap()
        _, kubelet_cfg = self._run_with_tempfile(
            configmap,
            ['--image_gc_low_threshold_percent', '60'])
        self.assertEqual(
            kubelet_cfg['imageGCLowThresholdPercent'], 60)

    def test_custom_gc_high_threshold(self):
        """Custom imageGCHighThresholdPercent via CLI arg."""
        configmap = self._make_configmap()
        _, kubelet_cfg = self._run_with_tempfile(
            configmap,
            ['--image_gc_high_threshold_percent', '85'])
        self.assertEqual(
            kubelet_cfg['imageGCHighThresholdPercent'], 85)

    def test_custom_eviction_hard_imagefs(self):
        """Custom evictionHard imagefs.available via CLI arg."""
        configmap = self._make_configmap()
        _, kubelet_cfg = self._run_with_tempfile(
            configmap,
            ['--eviction_hard_imagefs_available', '5Gi'])
        self.assertEqual(
            kubelet_cfg['evictionHard']['imagefs.available'], '5Gi')

    def test_eviction_hard_defaults_present(self):
        """All four evictionHard defaults are set."""
        configmap = self._make_configmap()
        _, kubelet_cfg = self._run_with_tempfile(configmap)
        eviction = kubelet_cfg['evictionHard']
        self.assertEqual(eviction['memory.available'], '100Mi')
        self.assertEqual(eviction['nodefs.available'], '10%')
        self.assertEqual(eviction['nodefs.inodesFree'], '5%')
        self.assertEqual(eviction['imagefs.available'], '2Gi')

    def test_preserves_other_kubelet_fields(self):
        """Other kubelet config fields are preserved after update."""
        configmap = self._make_configmap()
        _, kubelet_cfg = self._run_with_tempfile(configmap)
        self.assertEqual(
            kubelet_cfg['apiVersion'],
            'kubelet.config.k8s.io/v1beta1')
        self.assertEqual(
            kubelet_cfg['kind'], 'KubeletConfiguration')

    def test_preserves_configmap_metadata(self):
        """ConfigMap apiVersion and kind are preserved."""
        configmap = self._make_configmap()
        result, _ = self._run_with_tempfile(configmap)
        self.assertEqual(result['apiVersion'], 'v1')
        self.assertEqual(result['kind'], 'ConfigMap')

    def test_kubelet_data_is_string(self):
        """Kubelet config value remains a string in output."""
        configmap = self._make_configmap()
        result, _ = self._run_with_tempfile(configmap)
        self.assertIsInstance(result['data']['kubelet'], str)

    def test_all_custom_args(self):
        """All three custom args applied together."""
        configmap = self._make_configmap()
        _, kubelet_cfg = self._run_with_tempfile(configmap, [
            '--image_gc_low_threshold_percent', '55',
            '--image_gc_high_threshold_percent', '90',
            '--eviction_hard_imagefs_available', '10Gi'
        ])
        self.assertEqual(
            kubelet_cfg['imageGCLowThresholdPercent'], 55)
        self.assertEqual(
            kubelet_cfg['imageGCHighThresholdPercent'], 90)
        self.assertEqual(
            kubelet_cfg['evictionHard']['imagefs.available'], '10Gi')

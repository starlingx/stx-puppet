#
# Copyright (c) 2026 Wind River Systems, Inc.
#
# SPDX-License-Identifier: Apache-2.0
#


# @patch decorators inject unused mock args, tests access private methods.

"""Unit tests for change_k8s_control_plane_params module.

Focused on testing real logic: config parsing, validation,
error handling, and data transformation.
"""

import importlib
import logging as _logging
import os
import sys
import tempfile
import unittest
from unittest import mock
from unittest.mock import MagicMock
from unittest.mock import patch

# Mock heavy external dependencies before importing
sys.modules.setdefault('sysinv', MagicMock())
sys.modules.setdefault('sysinv.common', MagicMock())
sys.modules.setdefault('sysinv.common.kubernetes', MagicMock())
sys.modules.setdefault('sysinv.common.service_parameter', MagicMock())
sys.modules.setdefault('requests', MagicMock())

_mock_handler = MagicMock(spec=_logging.FileHandler)
_mock_handler.level = _logging.NOTSET
_mock_handler.filters = []
_mock_handler.lock = MagicMock()

with mock.patch('os.path.exists', return_value=True), \
     mock.patch('os.makedirs'), \
     mock.patch('os.chmod'), \
     mock.patch('logging.FileHandler', return_value=_mock_handler):
    ck8s = importlib.import_module(
        'debian.bullseye.src.modules.platform.files'
        '.change_k8s_control_plane_params'
    )


class TestValidateAdmissionPlugins(unittest.TestCase):
    """Tests for _validate_admission_plugins logic."""

    def test_adds_missing_node_restriction(self):
        """NodeRestriction is appended when missing."""
        result = ck8s._validate_admission_plugins(
            "MutatingAdmissionWebhook,ValidatingAdmissionWebhook")
        self.assertIn('NodeRestriction', result)

    def test_does_not_duplicate_node_restriction(self):
        """NodeRestriction is not duplicated when already present."""
        plugins = "NodeRestriction,MutatingAdmissionWebhook"
        result = ck8s._validate_admission_plugins(plugins)
        self.assertEqual(result.count('NodeRestriction'), 1)


class TestUpdateExtraArgs(unittest.TestCase):
    """Tests for update_extra_args v1beta4 list format."""

    def test_updates_existing_arg(self):
        """Existing arg value is updated in-place."""
        config = {'extraArgs': [
            {'name': 'audit-log-maxage', 'value': '7'},
            {'name': 'profiling', 'value': 'false'},
        ]}
        ck8s.update_extra_args(config, 'audit-log-maxage', '30')
        self.assertEqual(config['extraArgs'][0]['value'], '30')
        self.assertEqual(len(config['extraArgs']), 2)

    def test_appends_new_arg(self):
        """New arg is appended when not found."""
        config = {'extraArgs': [
            {'name': 'profiling', 'value': 'false'},
        ]}
        ck8s.update_extra_args(config, 'audit-log-maxage', '30')
        self.assertEqual(len(config['extraArgs']), 2)
        self.assertEqual(config['extraArgs'][1],
                         {'name': 'audit-log-maxage', 'value': '30'})


class TestFilterExtraArgs(unittest.TestCase):
    """Tests for filter_extra_args - removes args not in service params."""

    def test_filters_to_service_params_only(self):
        """Only args present in service_param are kept."""
        config = {'extraArgs': [
            {'name': 'audit-log-maxage', 'value': '30'},
            {'name': 'profiling', 'value': 'false'},
            {'name': 'old-removed-param', 'value': 'x'},
        ]}
        service_param = {'audit-log-maxage': '30', 'profiling': 'false'}
        ck8s.filter_extra_args(config, service_param)
        names = [item['name'] for item in config['extraArgs']]
        self.assertEqual(sorted(names),
                         ['audit-log-maxage', 'profiling'])

    def test_handles_empty_extra_args(self):
        """No error when extraArgs is empty or missing."""
        config = {'extraArgs': []}
        ck8s.filter_extra_args(config, {'foo': 'bar'})
        self.assertEqual(config['extraArgs'], [])

    def test_handles_missing_extra_args_key(self):
        """No error when extraArgs key does not exist."""
        config = {}
        ck8s.filter_extra_args(config, {'foo': 'bar'})
        self.assertNotIn('extraArgs', config)


class TestGetKubeletCfgFromServiceParameters(unittest.TestCase):
    """Tests for kubelet config parsing with type casting."""

    def test_parses_integer_values(self):
        """Integer strings are cast to int."""
        params = {'kubelet': {'maxPods': '250'}, 'base': {}}
        result = ck8s.get_kubelet_cfg_from_service_parameters(params)
        self.assertEqual(result['maxPods'], 250)
        self.assertIsInstance(result['maxPods'], int)

    def test_parses_boolean_true(self):
        """Boolean true strings are cast to bool."""
        params = {'kubelet': {'enableServer': 'True'}, 'base': {}}
        result = ck8s.get_kubelet_cfg_from_service_parameters(params)
        self.assertIs(result['enableServer'], True)

    def test_parses_boolean_false(self):
        """Boolean false strings are cast to bool."""
        params = {'kubelet': {'readOnlyPort': 'false'}, 'base': {}}
        result = ck8s.get_kubelet_cfg_from_service_parameters(params)
        self.assertIs(result['readOnlyPort'], False)

    def test_parses_json_list(self):
        """JSON list strings are parsed to list."""
        params = {'kubelet': {'clusterDNS': '["10.96.0.10"]'}, 'base': {}}
        result = ck8s.get_kubelet_cfg_from_service_parameters(params)
        self.assertEqual(result['clusterDNS'], ['10.96.0.10'])

    def test_parses_json_dict(self):
        """JSON dict strings are parsed to dict."""
        params = {'kubelet': {'evictionHard': '{"memory.available": "100Mi"}'},
                  'base': {}}
        result = ck8s.get_kubelet_cfg_from_service_parameters(params)
        self.assertEqual(result['evictionHard'],
                         {'memory.available': '100Mi'})

    def test_invalid_json_returns_error_code(self):
        """Malformed JSON that triggers parsing returns error code 3."""
        params = {'kubelet': {'bad': '{not valid}'}, 'base': {}}
        result = ck8s.get_kubelet_cfg_from_service_parameters(params)
        self.assertEqual(result, 3)

    def test_default_cluster_dns_from_base(self):
        """clusterDNS defaults to dns_service_ip from base params."""
        params = {'kubelet': {'maxPods': '110'},
                  'base': {'dns_service_ip': '10.96.0.10'}}
        result = ck8s.get_kubelet_cfg_from_service_parameters(params)
        self.assertEqual(result['clusterDNS'], ['10.96.0.10'])

    def test_parses_float_values(self):
        """Float strings are cast to float."""
        params = {'kubelet': {'imageGCHighThreshold': '85.5'}, 'base': {}}
        result = ck8s.get_kubelet_cfg_from_service_parameters(params)
        self.assertAlmostEqual(result['imageGCHighThreshold'], 85.5)


class TestK8sHealthCheck(unittest.TestCase):
    """Tests for k8s_health_check retry and error logic."""

    @patch.object(ck8s, 'get_api_server_readyz_endpoint',
                  return_value='https://127.0.0.1:16443/readyz')
    @patch.object(ck8s, 'requests')
    @patch('time.sleep')
    def test_healthy_endpoint_returns_true(
            self, _mock_sleep, mock_requests, _mock_endpoint):
        """Returns True when health endpoint responds ok."""
        mock_response = MagicMock()
        mock_response.status_code = 200
        mock_requests.get.return_value = mock_response
        result = ck8s.k8s_health_check(
            timeout=5, tries=3, try_sleep=1,
            healthz_endpoint='https://127.0.0.1:16443/readyz')
        self.assertTrue(result)

    @patch.object(ck8s, 'get_api_server_readyz_endpoint',
                  return_value='https://127.0.0.1:16443/readyz')
    def test_invalid_endpoint_returns_false(self, _mock_endpoint):
        """Returns False for unrecognized endpoint."""
        result = ck8s.k8s_health_check(
            timeout=5, tries=1, try_sleep=0,
            healthz_endpoint='https://invalid:9999/healthz')
        self.assertFalse(result)

    @patch.object(ck8s, 'get_api_server_readyz_endpoint',
                  return_value='https://127.0.0.1:16443/readyz')
    @patch.object(ck8s, 'requests')
    @patch('time.sleep')
    def test_retries_on_non_200(self, _mock_sleep, mock_requests, _mock_endpoint):
        """Retries when endpoint returns non-200."""
        mock_response = MagicMock()
        mock_response.status_code = 503
        mock_requests.get.return_value = mock_response
        result = ck8s.k8s_health_check(
            timeout=5, tries=3, try_sleep=0,
            healthz_endpoint='https://127.0.0.1:16443/readyz')
        self.assertFalse(result)
        self.assertEqual(mock_requests.get.call_count, 3)


class TestGeneratesKubeadmConfigFile(unittest.TestCase):
    """Tests for generates_kubeadm_config_file - real YAML writing."""

    def setUp(self):
        """Create temp files for testing."""
        with tempfile.NamedTemporaryFile(
                mode='w', suffix='.yaml', delete=False) as f:
            self.config_file = f
        with tempfile.NamedTemporaryFile(
                mode='w', suffix='.yaml', delete=False) as f:
            f.write(
                "apiVersion: kubelet.config.k8s.io/v1beta1\n"
                "kind: KubeletConfiguration\n")
            self.bak_file = f
        self.bak_file.close()

    def tearDown(self):
        """Remove temp files."""
        for filepath in [self.config_file.name, self.bak_file.name]:
            if os.path.exists(filepath):
                os.unlink(filepath)

    def test_success_with_cluster_cfg(self):
        """Returns 0 with valid cluster config."""
        cluster_cfg = {
            'apiVersion': 'kubeadm.k8s.io/v1beta3',
            'kubernetesVersion': 'v1.28.0'
        }
        rc = ck8s.generates_kubeadm_config_file(
            self.config_file.name, self.bak_file.name,
            cluster_cfg=cluster_cfg)
        self.assertEqual(rc, 0)

    def test_bak_file_not_found(self):
        """Returns 1 when backup file does not exist."""
        rc = ck8s.generates_kubeadm_config_file(
            self.config_file.name, '/nonexistent/bak.yaml',
            cluster_cfg={'apiVersion': 'v1beta3',
                         'kubernetesVersion': 'v1.28.0'})
        self.assertEqual(rc, 1)

    def test_only_kubelet_section(self):
        """only_kubelet_section skips ClusterConfiguration."""
        rc = ck8s.generates_kubeadm_config_file(
            self.config_file.name, self.bak_file.name,
            only_kubelet_section=True)
        self.assertEqual(rc, 0)
        with open(self.config_file.name, 'r', encoding='utf-8') as f:
            content = f.read()
        self.assertNotIn('ClusterConfiguration', content)

    def test_new_kubelet_cfg_applied(self):
        """New kubelet config values appear in output."""
        cluster_cfg = {
            'apiVersion': 'kubeadm.k8s.io/v1beta3',
            'kubernetesVersion': 'v1.28.0'
        }
        rc = ck8s.generates_kubeadm_config_file(
            self.config_file.name, self.bak_file.name,
            new_kubelet_cfg={'maxPods': 200},
            cluster_cfg=cluster_cfg)
        self.assertEqual(rc, 0)
        with open(self.config_file.name, 'r', encoding='utf-8') as f:
            content = f.read()
        self.assertIn('maxPods', content)


class TestGetK8sClusterConfiguration(unittest.TestCase):
    """Tests for get_k8s_cluster_configuration."""

    @patch.object(ck8s, 'get_k8s_configmap')
    def test_valid_configmap(self, mock_get_cm):
        """Returns parsed dict from valid configmap."""
        mock_cm = MagicMock()
        mock_cm.data = {
            'ClusterConfiguration':
                'apiVersion: kubeadm.k8s.io/v1beta3\n'
                'kubernetesVersion: v1.28.0\n'
        }
        mock_get_cm.return_value = mock_cm
        result = ck8s.get_k8s_cluster_configuration()
        self.assertIsInstance(result, dict)
        self.assertEqual(result['kubernetesVersion'], 'v1.28.0')

    @patch.object(ck8s, 'get_k8s_configmap', return_value=False)
    def test_configmap_false(self, _mock_get_cm):
        """Returns False when configmap not found."""
        result = ck8s.get_k8s_cluster_configuration()
        self.assertFalse(result)

    @patch.object(ck8s, 'get_k8s_configmap', side_effect=Exception("fail"))
    def test_exception_returns_false(self, _mock_get_cm):
        """Returns False on exception."""
        result = ck8s.get_k8s_cluster_configuration()
        self.assertFalse(result)


class TestRestartKubeletService(unittest.TestCase):
    """Tests for restart_kubelet_service."""

    @patch.object(ck8s, '_exec_cmd', return_value=0)
    def test_success(self, _mock_exec):
        """Returns 0 on successful restart."""
        rc = ck8s.restart_kubelet_service()
        self.assertEqual(rc, 0)

    @patch.object(ck8s, '_exec_cmd', return_value=1)
    def test_failure(self, _mock_exec):
        """Returns 1 on failed restart."""
        rc = ck8s.restart_kubelet_service()
        self.assertEqual(rc, 1)


if __name__ == '__main__':
    unittest.main()

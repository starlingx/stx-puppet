#
# Copyright (c) 2026 Wind River Systems, Inc.
#
# SPDX-License-Identifier: Apache-2.0
#


"""Unit tests for change_k8s_control_plane_params module.

Covers utility functions, export/restore logic, and hieradata parsing.
"""

import importlib
import os
import sys
import tempfile
import unittest
from unittest.mock import MagicMock
from unittest.mock import patch

import yaml

# Mock heavy external dependencies before importing
sys.modules.setdefault('sysinv', MagicMock())
sys.modules.setdefault('sysinv.common', MagicMock())
sys.modules.setdefault('sysinv.common.kubernetes', MagicMock())
sys.modules.setdefault('sysinv.common.service_parameter', MagicMock())
sys.modules.setdefault('requests', MagicMock())

import logging as _logging  # noqa: E402
_mock_handler = MagicMock(spec=_logging.FileHandler)
_mock_handler.level = _logging.NOTSET
_mock_handler.filters = []
_mock_handler.lock = MagicMock()

with patch('os.path.exists', return_value=True), \
     patch('os.makedirs'), \
     patch('os.chmod'), \
     patch('logging.FileHandler', return_value=_mock_handler):
    ck8s = importlib.import_module(
        'debian.bullseye.src.modules.platform.files'
        '.change_k8s_control_plane_params'
    )


class TestExecCmd(unittest.TestCase):
    """Tests for _exec_cmd subprocess wrapper."""

    @patch('subprocess.check_call')
    def test_success_returns_zero(self, mock_call):
        """Returns 0 on successful command."""
        rc = ck8s._exec_cmd(['echo', 'hello'])
        self.assertEqual(rc, 0)
        mock_call.assert_called_once_with(['echo', 'hello'])

    @patch('subprocess.check_call',
           side_effect=ck8s.CalledProcessError(2, 'cmd'))
    def test_failure_returns_returncode(self, _mock_call):
        """Returns process returncode on CalledProcessError."""
        rc = ck8s._exec_cmd(['false'])
        self.assertEqual(rc, 2)


class TestLogFileContent(unittest.TestCase):
    """Tests for _log_file_content."""

    def test_logs_file_content(self):
        """Reads file and passes content to logger."""
        fd, path = tempfile.mkstemp()
        try:
            os.write(fd, b'error message here')
            os.close(fd)
            logged = []
            ck8s._log_file_content(path, logger=logged.append)
            self.assertEqual(logged, ['error message here'])
        finally:
            os.unlink(path)

    def test_missing_file_no_exception(self):
        """Does not raise and does not log when file missing."""
        logged = []
        ck8s._log_file_content('/nonexistent/file.log', logger=logged.append)
        self.assertEqual(logged, [])


class TestSearchStringOnFile(unittest.TestCase):
    """Tests for _search_string_on_file."""

    def test_found_returns_true(self):
        """Returns True when word is in file."""
        fd, path = tempfile.mkstemp()
        try:
            os.write(fd, b'line1\nerror unmarshaling configuration\nline3\n')
            os.close(fd)
            self.assertTrue(ck8s._search_string_on_file(
                path, 'error unmarshaling configuration'))
        finally:
            os.unlink(path)

    def test_not_found_returns_false(self):
        """Returns False when word is not in file."""
        fd, path = tempfile.mkstemp()
        try:
            os.write(fd, b'all good\nno issues\n')
            os.close(fd)
            self.assertFalse(ck8s._search_string_on_file(
                path, 'error unmarshaling'))
        finally:
            os.unlink(path)


class TestUpdateK8sControlPlaneComponents(unittest.TestCase):
    """Tests for update_k8s_control_plane_components."""

    @patch.object(ck8s, '_exec_cmd', return_value=0)
    def test_success_returns_zero(self, mock_exec):
        """Returns 0 when kubeadm command succeeds."""
        fd, path = tempfile.mkstemp(suffix='.yaml')
        try:
            os.write(fd, b'apiVersion: v1\n')
            os.close(fd)
            rc = ck8s.update_k8s_control_plane_components(
                path, '10.10.10.2', target_component='apiserver')
            self.assertEqual(rc, 0)
            # Verify kubeadm was called with correct args
            call_args = mock_exec.call_args[0][0]
            self.assertIn('kubeadm', call_args)
            self.assertIn('apiserver', call_args)
        finally:
            os.unlink(path)
            tmp = path + '.tmp'
            if os.path.exists(tmp):
                os.unlink(tmp)

    @patch.object(ck8s, '_exec_cmd', return_value=1)
    def test_exec_failure_returns_nonzero(self, _mock_exec):
        """Returns non-zero when kubeadm fails."""
        fd, path = tempfile.mkstemp(suffix='.yaml')
        try:
            os.write(fd, b'apiVersion: v1\n')
            os.close(fd)
            rc = ck8s.update_k8s_control_plane_components(
                path, '10.10.10.2')
            self.assertEqual(rc, 1)
        finally:
            os.unlink(path)
            tmp = path + '.tmp'
            if os.path.exists(tmp):
                os.unlink(tmp)

    def test_missing_file_returns_minus_one(self):
        """Returns -1 when source file doesn't exist."""
        rc = ck8s.update_k8s_control_plane_components(
            '/nonexistent/config.yaml', '10.10.10.2')
        self.assertEqual(rc, -1)


class TestUpdateK8sKubelet(unittest.TestCase):
    """Tests for update_k8s_kubelet."""

    @patch.object(ck8s, '_exec_cmd', return_value=0)
    def test_success_empty_error_log(self, _mock_exec):
        """Returns 0 when command succeeds and error log is empty."""
        fd, err_path = tempfile.mkstemp()
        os.close(fd)
        fd2, config_path = tempfile.mkstemp()
        os.write(fd2, b'config data')
        os.close(fd2)
        try:
            rc = ck8s.update_k8s_kubelet(config_path, err_path)
            self.assertEqual(rc, 0)
        finally:
            for p in (err_path, config_path):
                if os.path.exists(p):
                    os.unlink(p)

    @patch.object(ck8s, '_exec_cmd', return_value=0)
    def test_warning_only_returns_zero(self, _mock_exec):
        """Returns 0 when error log has warnings but no errors."""
        fd, err_path = tempfile.mkstemp()
        os.write(fd, b'WARNING: some deprecation notice\n')
        os.close(fd)
        fd2, config_path = tempfile.mkstemp()
        os.write(fd2, b'config')
        os.close(fd2)
        try:
            rc = ck8s.update_k8s_kubelet(config_path, err_path)
            self.assertEqual(rc, 0)
        finally:
            for p in (err_path, config_path):
                if os.path.exists(p):
                    os.unlink(p)

    @patch.object(ck8s, '_exec_cmd', return_value=0)
    def test_unmarshaling_error_returns_one(self, mock_exec):
        """Returns 1 when error log contains unmarshaling error."""
        fd, err_path = tempfile.mkstemp()
        os.close(fd)
        fd2, config_path = tempfile.mkstemp()
        os.write(fd2, b'config')
        os.close(fd2)

        def write_error(_cmd, stderr=None):
            """Simulate kubeadm writing error to stderr file."""
            if stderr is not None:
                stderr.write('error unmarshaling configuration: bad field\n')
            return 0

        mock_exec.side_effect = write_error
        try:
            rc = ck8s.update_k8s_kubelet(config_path, err_path)
            self.assertEqual(rc, 1)
        finally:
            for p in (err_path, config_path):
                if os.path.exists(p):
                    os.unlink(p)

    @patch.object(ck8s, '_exec_cmd', return_value=1)
    def test_command_failure_returns_one(self, _mock_exec):
        """Returns 1 when kubeadm command fails."""
        fd, err_path = tempfile.mkstemp()
        os.close(fd)
        fd2, config_path = tempfile.mkstemp()
        os.write(fd2, b'config')
        os.close(fd2)
        try:
            rc = ck8s.update_k8s_kubelet(config_path, err_path)
            self.assertEqual(rc, 1)
        finally:
            for p in (err_path, config_path):
                if os.path.exists(p):
                    os.unlink(p)


class TestGetServiceParametersFromHieradata(unittest.TestCase):
    """Tests for get_service_parameters_from_hieradata."""

    @staticmethod
    def _write_hieradata(data):
        """Write hieradata YAML to a temp file."""
        fd, path = tempfile.mkstemp(suffix='.yaml')
        with os.fdopen(fd, 'w') as f:
            yaml.dump(data, f)
        return path

    def test_parses_apiserver_params(self):
        """Extracts apiServer params from hieradata."""
        data = {
            'platform::kubernetes::kube_apiserver::params::audit-log-maxage': '30',
            'platform::kubernetes::kube_apiserver::params::profiling': 'false',
        }
        path = self._write_hieradata(data)
        try:
            result = ck8s.get_service_parameters_from_hieradata(
                path, {}, {}, {}, {}, {})
            self.assertEqual(result['apiServer']['audit-log-maxage'], '30')
            self.assertEqual(result['apiServer']['profiling'], 'false')
        finally:
            os.unlink(path)

    def test_parses_controller_manager_params(self):
        """Extracts controllerManager params."""
        data = {
            'platform::kubernetes::kube_controller_manager::params::node-cidr-mask-size': '24',
        }
        path = self._write_hieradata(data)
        try:
            result = ck8s.get_service_parameters_from_hieradata(
                path, {}, {}, {}, {}, {})
            self.assertEqual(
                result['controllerManager']['node-cidr-mask-size'], '24')
        finally:
            os.unlink(path)

    def test_parses_scheduler_params(self):
        """Extracts scheduler params."""
        data = {
            'platform::kubernetes::kube_scheduler::params::profiling': 'true',
        }
        path = self._write_hieradata(data)
        try:
            result = ck8s.get_service_parameters_from_hieradata(
                path, {}, {}, {}, {}, {})
            self.assertEqual(result['scheduler']['profiling'], 'true')
        finally:
            os.unlink(path)

    def test_parses_kubelet_params(self):
        """Extracts kubelet params."""
        data = {
            'platform::kubernetes::kubelet::params::maxPods': '200',
        }
        path = self._write_hieradata(data)
        try:
            result = ck8s.get_service_parameters_from_hieradata(
                path, {}, {}, {}, {}, {})
            self.assertEqual(result['kubelet']['maxPods'], '200')
        finally:
            os.unlink(path)

    def test_parses_etcd_params(self):
        """Extracts etcd params using DEFAULT_TAG split."""
        data = {
            'platform::kubernetes::params::etcd_heartbeat-interval': '100',
        }
        path = self._write_hieradata(data)
        try:
            result = ck8s.get_service_parameters_from_hieradata(
                path, {}, {}, {}, {}, {})
            self.assertEqual(
                result['etcd']['etcd_heartbeat-interval'], '100')
        finally:
            os.unlink(path)

    def test_parses_base_params(self):
        """Extracts base (default) params."""
        data = {
            'platform::kubernetes::params::dns_service_ip': '10.96.0.10',
        }
        path = self._write_hieradata(data)
        try:
            result = ck8s.get_service_parameters_from_hieradata(
                path, {}, {}, {}, {}, {})
            self.assertEqual(
                result['base']['dns_service_ip'], '10.96.0.10')
        finally:
            os.unlink(path)

    def test_parses_volume_params(self):
        """Extracts apiServerVolumes params."""
        data = {
            'platform::kubernetes::kube_apiserver_volumes::params::my-vol':
                'hostPath=/etc/foo,mounthPath=/etc/foo,pathType=File',
        }
        path = self._write_hieradata(data)
        try:
            result = ck8s.get_service_parameters_from_hieradata(
                path, {}, {}, {}, {}, {})
            self.assertIn('my-vol', result['apiServerVolumes'])
        finally:
            os.unlink(path)

    def test_schema_translation(self):
        """Translates legacy param names via schema."""
        data = {
            'platform::kubernetes::kube_apiserver::params::old-name': 'val',
        }
        schema = {'section1': {'old-name': 'new-name'}}
        path = self._write_hieradata(data)
        try:
            result = ck8s.get_service_parameters_from_hieradata(
                path, schema, {}, {}, {}, {})
            self.assertIn('new-name', result['apiServer'])
            self.assertNotIn('old-name', result['apiServer'])
        finally:
            os.unlink(path)

    def test_invalid_file_raises(self):
        """Raises exception on missing hieradata file."""
        with self.assertRaises(FileNotFoundError):
            ck8s.get_service_parameters_from_hieradata(
                '/nonexistent.yaml', {}, {}, {}, {}, {})


class TestExportK8sClusterConfiguration(unittest.TestCase):
    """Tests for export_k8s_cluster_configuration."""

    def test_writes_cluster_cfg_to_file(self):
        """Writes provided cluster config to target file."""
        fd, path = tempfile.mkstemp(suffix='.yaml')
        os.close(fd)
        try:
            cluster_cfg = {'apiVersion': 'v1beta3', 'kind': 'ClusterConfig'}
            rc = ck8s.export_k8s_cluster_configuration(path,
                                                       cluster_cfg=cluster_cfg)
            self.assertEqual(rc, 0)
            with open(path, encoding='utf-8') as f:
                content = f.read()
            self.assertIn('apiVersion', content)
        finally:
            os.unlink(path)

    @patch.object(ck8s, 'get_k8s_cluster_configuration', return_value=False)
    def test_returns_one_when_no_cluster_cfg(self, _mock_get):
        """Returns 1 when cluster config cannot be fetched."""
        rc = ck8s.export_k8s_cluster_configuration('/tmp/out.yaml')
        self.assertEqual(rc, 1)

    def test_returns_one_on_write_error(self):
        """Returns 1 when file write fails."""
        rc = ck8s.export_k8s_cluster_configuration(
            '/nonexistent/dir/file.yaml',
            cluster_cfg={'key': 'val'})
        self.assertEqual(rc, 1)


class TestExportK8sConfigmap(unittest.TestCase):
    """Tests for export_k8s_configmap."""

    @patch.object(ck8s, 'get_k8s_configmap')
    def test_writes_configmap_data(self, mock_get_cm):
        """Writes configmap value to target file."""
        mock_cm = MagicMock()
        mock_cm.data = {'ClusterConfiguration': 'apiVersion: v1\n'}
        mock_get_cm.return_value = mock_cm
        fd, path = tempfile.mkstemp()
        os.close(fd)
        try:
            rc = ck8s.export_k8s_configmap(path, 'kubeadm-config')
            self.assertEqual(rc, 0)
            with open(path, encoding='utf-8') as f:
                self.assertEqual(f.read(), 'apiVersion: v1\n')
        finally:
            os.unlink(path)

    @patch.object(ck8s, 'get_k8s_configmap', return_value=False)
    def test_returns_one_when_configmap_not_found(self, _mock_get):
        """Returns 1 when configmap fetch fails."""
        rc = ck8s.export_k8s_configmap('/tmp/out.yaml', 'missing-cm')
        self.assertEqual(rc, 1)

    @patch.object(ck8s, 'get_k8s_configmap')
    def test_returns_one_for_unexpected_format(self, mock_get_cm):
        """Returns 1 when configmap has unexpected data format."""
        mock_cm = MagicMock()
        mock_cm.data = {'key1': 'val1', 'key2': 'val2'}  # >1 key
        mock_get_cm.return_value = mock_cm
        rc = ck8s.export_k8s_configmap('/tmp/out.yaml', 'bad-cm')
        self.assertEqual(rc, 1)


class TestPatchKubeadminConfigmap(unittest.TestCase):
    """Tests for patch_kubeadmin_configmap."""

    def test_skips_on_inactive_controller(self):
        """Returns 0 without patching on inactive controller."""
        rc = ck8s.patch_kubeadmin_configmap({}, is_controller_active=False)
        self.assertEqual(rc, 0)

    @patch.object(ck8s, 'get_kube_operator')
    def test_returns_one_on_exception(self, mock_op):
        """Returns 1 when patching raises exception."""
        mock_op.return_value.kube_patch_config_map.side_effect = \
            Exception("connection refused")
        rc = ck8s.patch_kubeadmin_configmap({'k': 'v'}, is_controller_active=True)
        self.assertEqual(rc, 1)


class TestGetK8sVersion(unittest.TestCase):
    """Tests for get_k8s_version."""

    @patch('time.sleep')
    @patch.object(ck8s, 'get_kube_operator')
    def test_retries_and_returns_false(self, mock_op, _mock_sleep):
        """Returns False after all retries exhausted."""
        mock_op.return_value.kube_get_kubernetes_version.side_effect = \
            Exception("unavailable")
        result = ck8s.get_k8s_version(timeout=1, tries=2, try_sleep=0)
        self.assertFalse(result)


class TestGetK8sConfigmap(unittest.TestCase):
    """Tests for get_k8s_configmap."""

    @patch('time.sleep')
    @patch.object(ck8s, 'get_kube_operator')
    def test_retries_and_returns_false(self, mock_op, _mock_sleep):
        """Returns False after retries exhausted."""
        mock_op.return_value.kube_read_config_map.side_effect = \
            Exception("not found")
        result = ck8s.get_k8s_configmap('missing', timeout=1,
                                        tries=2, try_sleep=0)
        self.assertFalse(result)


class TestUpdateKubeletConfigmap(unittest.TestCase):
    """Tests for update_kubelet_configmap."""

    def test_skips_on_inactive_controller(self):
        """Returns 0 without action on inactive controller."""
        rc = ck8s.update_kubelet_configmap('/tmp/config.yaml',
                                           is_controller_active=False)
        self.assertEqual(rc, 0)

    @patch.object(ck8s, 'get_k8s_version', return_value=False)
    def test_returns_one_when_version_fails(self, _mock_ver):
        """Returns 1 when k8s version cannot be fetched."""
        rc = ck8s.update_kubelet_configmap('/tmp/config.yaml',
                                           is_controller_active=True)
        self.assertEqual(rc, 1)

    @patch.object(ck8s, 'get_kube_operator')
    @patch.object(ck8s, 'get_k8s_configmap', return_value=MagicMock())
    @patch.object(ck8s, 'get_k8s_version', return_value='v1.28.4')
    def test_returns_one_on_delete_exception(self, _mock_ver, _mock_cm, mock_op):
        """Returns 1 when deleting configmap raises."""
        mock_op.return_value.kube_delete_config_map.side_effect = \
            Exception("forbidden")
        rc = ck8s.update_kubelet_configmap('/tmp/config.yaml',
                                           is_controller_active=True)
        self.assertEqual(rc, 1)


class TestUpdateKubeletBakConfigFiles(unittest.TestCase):
    """Tests for update_kubelet_bak_config_files."""

    def test_success_copies_files(self):
        """Returns 0 and copies both files."""
        fd1, src1 = tempfile.mkstemp()
        fd2, src2 = tempfile.mkstemp()
        os.write(fd1, b'kubeadm config')
        os.write(fd2, b'kubelet config')
        os.close(fd1)
        os.close(fd2)
        fd3, dst1 = tempfile.mkstemp()
        fd4, dst2 = tempfile.mkstemp()
        os.close(fd3)
        os.close(fd4)
        try:
            rc = ck8s.update_kubelet_bak_config_files(src1, dst1, src2, dst2)
            self.assertEqual(rc, 0)
            with open(dst1, encoding='utf-8') as f:
                self.assertEqual(f.read(), 'kubeadm config')
            with open(dst2, encoding='utf-8') as f:
                self.assertEqual(f.read(), 'kubelet config')
        finally:
            for p in (src1, src2, dst1, dst2):
                if os.path.exists(p):
                    os.unlink(p)

    def test_returns_one_on_first_copy_failure(self):
        """Returns 1 when first copy fails."""
        rc = ck8s.update_kubelet_bak_config_files(
            '/nonexistent/src1', '/tmp/dst1', '/tmp/src2', '/tmp/dst2')
        self.assertEqual(rc, 1)


class TestPreK8sUpdatingTasks(unittest.TestCase):
    """Tests for pre_k8s_updating_tasks."""

    def test_appends_post_task(self):
        """Appends a callable to post_tasks list."""
        post_tasks = []
        rc = ck8s.pre_k8s_updating_tasks(post_tasks)
        self.assertEqual(rc, 0)
        self.assertEqual(len(post_tasks), 1)
        self.assertTrue(callable(post_tasks[0]))


class TestPostK8sUpdatingTasks(unittest.TestCase):
    """Tests for post_k8s_updating_tasks."""

    def test_executes_all_tasks(self):
        """Calls each callable in post_tasks."""
        task1 = MagicMock()
        task2 = MagicMock()
        ck8s.post_k8s_updating_tasks([task1, task2])
        self.assertEqual(task1.call_count, 1)
        self.assertEqual(task2.call_count, 1)

    def test_no_error_with_none(self):
        """Handles None post_tasks without error."""
        result = ck8s.post_k8s_updating_tasks(None)
        self.assertIsNone(result)


class TestRestoreK8sKubeletConfig(unittest.TestCase):
    """Tests for restore_k8s_kubelet_config."""

    @patch.object(ck8s, 'k8s_health_check', return_value=True)
    @patch.object(ck8s, 'update_k8s_kubelet', return_value=0)
    def test_success_returns_one(self, _mock_update, _mock_health):
        """Returns 1 (success code) on successful restore."""
        rc = ck8s.restore_k8s_kubelet_config(
            '/tmp/bak.yaml', tries=1, try_sleep=0,
            timeout=1, error_log_file='/tmp/err.log')
        self.assertEqual(rc, 1)

    @patch.object(ck8s, 'update_k8s_kubelet', return_value=1)
    def test_update_failure_returns_two(self, _mock_update):
        """Returns 2 when kubelet update fails."""
        rc = ck8s.restore_k8s_kubelet_config(
            '/tmp/bak.yaml', tries=1, try_sleep=0,
            timeout=1, error_log_file='/tmp/err.log')
        self.assertEqual(rc, 2)

    @patch.object(ck8s, 'k8s_health_check', return_value=False)
    @patch.object(ck8s, 'update_k8s_kubelet', return_value=0)
    def test_health_check_fail_returns_two(self, _mock_update, _mock_health):
        """Returns 2 when health check fails after restore."""
        rc = ck8s.restore_k8s_kubelet_config(
            '/tmp/bak.yaml', tries=1, try_sleep=0,
            timeout=1, error_log_file='/tmp/err.log')
        self.assertEqual(rc, 2)


class TestExportVolumeConfigmap(unittest.TestCase):
    """Tests for export_volume_configmap."""

    def test_skips_non_file_type(self):
        """Returns 0 immediately for non-File pathType."""
        volume = {'pathType': 'DirectoryOrCreate', 'hostPath': '/tmp'}
        rc = ck8s.export_volume_configmap(volume, 'kube-apiserver-volumes')
        self.assertEqual(rc, 0)

    @patch.object(ck8s, 'export_k8s_configmap', return_value=0)
    def test_file_type_exports(self, mock_export):
        """Calls export_k8s_configmap for File pathType."""
        volume = {'pathType': 'File', 'hostPath': '/etc/foo.yaml',
                  'mounthPath': '/etc/foo.yaml', 'name': 'foo'}
        rc = ck8s.export_volume_configmap(volume, 'kube-apiserver-volumes')
        self.assertEqual(rc, 0)
        mock_export.assert_called_once()

    @patch.object(ck8s, 'export_k8s_configmap', return_value=1)
    def test_returns_one_on_export_failure(self, _mock_export):
        """Returns 1 when export fails."""
        volume = {'pathType': 'File', 'hostPath': '/etc/foo.yaml',
                  'mounthPath': '/etc/foo.yaml', 'name': 'foo'}
        rc = ck8s.export_volume_configmap(volume, 'kube-apiserver-volumes')
        self.assertEqual(rc, 1)


class TestExportK8sKubeadmConfigmap(unittest.TestCase):
    """Tests for export_k8s_kubeadm_configmap."""

    @patch.object(ck8s, '_exec_cmd', return_value=0)
    def test_success(self, mock_exec):
        """Returns 0 and calls kubectl command."""
        fd, path = tempfile.mkstemp()
        os.close(fd)
        try:
            rc = ck8s.export_k8s_kubeadm_configmap(path)
            self.assertEqual(rc, 0)
            cmd = mock_exec.call_args[0][0]
            self.assertIn('kubectl', cmd)
            self.assertIn('kubeadm-config', cmd)
        finally:
            os.unlink(path)

    @patch.object(ck8s, '_exec_cmd', return_value=1)
    def test_exec_failure(self, _mock_exec):
        """Returns 1 when kubectl fails."""
        fd, path = tempfile.mkstemp()
        os.close(fd)
        try:
            rc = ck8s.export_k8s_kubeadm_configmap(path)
            self.assertEqual(rc, 1)
        finally:
            os.unlink(path)


class TestCheckIfConfigmapExist(unittest.TestCase):
    """Tests for _check_if_configmap_exist."""

    @patch.object(ck8s, 'get_k8s_configmap')
    def test_exists_returns_true(self, mock_get):
        """Returns True when configmap exists."""
        mock_get.return_value = MagicMock()  # truthy
        result = ck8s._check_if_configmap_exist('kubeadm-config', tries=1)
        self.assertTrue(result)

    @patch.object(ck8s, 'get_k8s_configmap', return_value=None)
    def test_none_returns_false(self, _mock_get):
        """Returns False when configmap is None."""
        result = ck8s._check_if_configmap_exist('missing-cm', tries=1)
        self.assertFalse(result)

    @patch('time.sleep')
    @patch.object(ck8s, 'get_k8s_configmap',
                  side_effect=Exception("connection error"))
    def test_raises_after_retries(self, _mock_get, _mock_sleep):
        """Raises exception after all retries exhausted."""
        with self.assertRaises(Exception) as ctx:  # noqa: H202
            ck8s._check_if_configmap_exist('bad-cm', tries=2, try_sleep=0)
        self.assertIn('Failed to check', str(ctx.exception))


class TestRestoreK8sControlPlaneConfig(unittest.TestCase):
    """Tests for restore_k8s_control_plane_config."""

    @patch.object(ck8s, 'k8s_health_check', return_value=True)
    @patch.object(ck8s, 'restart_kubelet_service', return_value=0)
    @patch.object(ck8s, 'post_k8s_updating_tasks')
    @patch.object(ck8s, 'update_k8s_control_plane_components', return_value=0)
    def test_full_success_returns_one(self, mock_update, _mock_post,
                                      _mock_restart, _mock_health):
        """Returns 1 on full successful restore."""
        rc = ck8s.restore_k8s_control_plane_config(
            '/tmp/bak.yaml', '10.10.10.2',
            tries=1, try_sleep=0, timeout=1)
        self.assertEqual(rc, 1)
        # Called 3 times: apiserver, controller-manager, scheduler
        self.assertEqual(mock_update.call_count, 3)

    @patch.object(ck8s, 'post_k8s_updating_tasks')
    @patch.object(ck8s, 'update_k8s_control_plane_components', return_value=0)
    @patch.object(ck8s, 'restart_kubelet_service', return_value=1)
    def test_restart_failure_returns_two(self, _mock_restart, _mock_update,
                                         _mock_post):
        """Returns 2 when kubelet restart fails."""
        rc = ck8s.restore_k8s_control_plane_config(
            '/tmp/bak.yaml', '10.10.10.2',
            tries=1, try_sleep=0, timeout=1)
        self.assertEqual(rc, 2)

    @patch.object(ck8s, 'k8s_health_check', return_value=False)
    @patch.object(ck8s, 'restart_kubelet_service', return_value=0)
    @patch.object(ck8s, 'post_k8s_updating_tasks')
    @patch.object(ck8s, 'update_k8s_control_plane_components', return_value=0)
    def test_health_check_fail_returns_two(self, _mock_update, _mock_post,
                                            _mock_restart, _mock_health):
        """Returns 2 when apiserver health check fails."""
        rc = ck8s.restore_k8s_control_plane_config(
            '/tmp/bak.yaml', '10.10.10.2',
            tries=1, try_sleep=0, timeout=1)
        self.assertEqual(rc, 2)


class TestInitializeK8sConfigmaps(unittest.TestCase):
    """Tests for initialize_k8s_configmaps."""

    @staticmethod
    def _write_hieradata(data):
        """Write hieradata YAML to a temp file."""
        fd, path = tempfile.mkstemp(suffix='.yaml')
        with os.fdopen(fd, 'w') as f:
            yaml.dump(data, f)
        return path

    @patch.object(ck8s, '_exec_cmd', return_value=0)
    @patch.object(ck8s, '_check_if_configmap_exist', return_value=False)
    @patch.object(ck8s, 'sp')
    def test_creates_configmap_for_file_volume(self, mock_sp, _mock_check,
                                               mock_exec):
        """Creates configmap when volume is File type and doesn't exist."""
        mock_sp.parse_volume_string_to_dict.return_value = (
            {'pathType': 'File', 'hostPath': __file__,
             'mounthPath': '/etc/test.conf', 'name': 'test-vol'},
            None
        )
        mock_sp.get_k8s_configmap_name.return_value = 'test-configmap'

        data = {
            'platform::kubernetes::kube_apiserver_volumes::params::test-vol':
                'hostPath=/etc/test.conf,pathType=File',
        }
        hiera_path = self._write_hieradata(data)
        flag_fd, flag_path = tempfile.mkstemp()
        os.close(flag_fd)
        try:
            ck8s.initialize_k8s_configmaps(
                hiera_path, flag_path, {}, {}, {}, {}, {})
            # kubectl create configmap should be called
            create_calls = [
                c for c in mock_exec.call_args_list
                if 'create' in str(c)]
            self.assertGreater(len(create_calls), 0)
        finally:
            for p in (hiera_path, flag_path):
                if os.path.exists(p):
                    os.unlink(p)

    @patch.object(ck8s, '_exec_cmd', return_value=0)
    @patch.object(ck8s, '_check_if_configmap_exist', return_value=True)
    @patch.object(ck8s, 'sp')
    def test_skips_existing_configmap(self, mock_sp, _mock_check, mock_exec):
        """Skips creation when configmap already exists."""
        mock_sp.parse_volume_string_to_dict.return_value = (
            {'pathType': 'File', 'hostPath': '/etc/test.conf',
             'mounthPath': '/etc/test.conf', 'name': 'test-vol'},
            None
        )
        mock_sp.get_k8s_configmap_name.return_value = 'test-configmap'

        data = {
            'platform::kubernetes::kube_apiserver_volumes::params::test-vol':
                'hostPath=/etc/test.conf,pathType=File',
        }
        hiera_path = self._write_hieradata(data)
        flag_fd, flag_path = tempfile.mkstemp()
        os.close(flag_fd)
        try:
            ck8s.initialize_k8s_configmaps(
                hiera_path, flag_path, {}, {}, {}, {}, {})
            # Only touch flag should be called, no kubectl create
            calls = [str(c) for c in mock_exec.call_args_list]
            kubectl_creates = [
                c for c in calls
                if 'create' in c and 'configmap' in c]
            self.assertEqual(len(kubectl_creates), 0)
        finally:
            for p in (hiera_path, flag_path):
                if os.path.exists(p):
                    os.unlink(p)

    @patch.object(ck8s, '_exec_cmd', return_value=0)
    @patch.object(ck8s, 'sp')
    def test_skips_directory_type(self, mock_sp, mock_exec):
        """Skips volumes with DirectoryOrCreate pathType."""
        mock_sp.parse_volume_string_to_dict.return_value = (
            {'pathType': 'DirectoryOrCreate', 'hostPath': '/var/data',
             'mounthPath': '/var/data', 'name': 'dir-vol'},
            None
        )
        data = {
            'platform::kubernetes::kube_apiserver_volumes::params::dir-vol':
                'hostPath=/var/data,pathType=DirectoryOrCreate',
        }
        hiera_path = self._write_hieradata(data)
        flag_fd, flag_path = tempfile.mkstemp()
        os.close(flag_fd)
        try:
            ck8s.initialize_k8s_configmaps(
                hiera_path, flag_path, {}, {}, {}, {}, {})
            # Only touch flag called, no create
            self.assertEqual(mock_exec.call_count, 1)
        finally:
            for p in (hiera_path, flag_path):
                if os.path.exists(p):
                    os.unlink(p)


class TestGetApiServerEndpoints(unittest.TestCase):
    """Tests for endpoint helper functions."""

    def test_get_api_server_endpoint(self):
        """Returns localhost URL with port."""
        result = ck8s.get_api_server_endpoint()
        self.assertIn('https://localhost:', result)

    def test_get_api_server_readyz_endpoint(self):
        """Returns readyz endpoint URL."""
        result = ck8s.get_api_server_readyz_endpoint()
        self.assertTrue(result.endswith('/readyz'))

    def test_get_kubeadm_initconfig_template(self):
        """Returns template string with port."""
        result = ck8s.get_kubeadm_initconfig_template()
        self.assertIn('localAPIEndpoint', result)


class TestRestoreControlPlaneEdgeCases(unittest.TestCase):
    """Edge case tests for restore_k8s_control_plane_config."""

    @patch.object(ck8s, 'k8s_health_check', side_effect=[True, False])
    @patch.object(ck8s, 'restart_kubelet_service', return_value=0)
    @patch.object(ck8s, 'post_k8s_updating_tasks')
    @patch.object(ck8s, 'update_k8s_control_plane_components', return_value=0)
    def test_controller_manager_health_fail(self, _mock_update, _mock_post,
                                            _mock_restart, _mock_health):
        """Returns 2 when controller-manager health check fails."""
        rc = ck8s.restore_k8s_control_plane_config(
            '/tmp/bak.yaml', '10.10.10.2',
            tries=1, try_sleep=0, timeout=1)
        self.assertEqual(rc, 2)

    @patch.object(ck8s, 'k8s_health_check', side_effect=[True, True, False])
    @patch.object(ck8s, 'restart_kubelet_service', return_value=0)
    @patch.object(ck8s, 'post_k8s_updating_tasks')
    @patch.object(ck8s, 'update_k8s_control_plane_components', return_value=0)
    def test_scheduler_health_fail(self, _mock_update, _mock_post,
                                   _mock_restart, _mock_health):
        """Returns 2 when scheduler health check fails."""
        rc = ck8s.restore_k8s_control_plane_config(
            '/tmp/bak.yaml', '10.10.10.2',
            tries=1, try_sleep=0, timeout=1)
        self.assertEqual(rc, 2)

    @patch.object(ck8s, 'k8s_health_check', return_value=True)
    @patch.object(ck8s, 'restart_kubelet_service',
                  side_effect=[0, 1])
    @patch.object(ck8s, 'post_k8s_updating_tasks')
    @patch.object(ck8s, 'update_k8s_control_plane_components', return_value=0)
    def test_second_restart_failure(self, _mock_update, _mock_post,
                                    _mock_restart, _mock_health):
        """Returns 2 when second kubelet restart fails."""
        rc = ck8s.restore_k8s_control_plane_config(
            '/tmp/bak.yaml', '10.10.10.2',
            tries=1, try_sleep=0, timeout=1)
        self.assertEqual(rc, 2)


class TestInitializeConfigmapsEdgeCases(unittest.TestCase):
    """Edge case tests for initialize_k8s_configmaps."""

    @staticmethod
    def _write_hieradata(data):
        fd, path = tempfile.mkstemp(suffix='.yaml')
        with os.fdopen(fd, 'w') as f:
            yaml.dump(data, f)
        return path

    @patch.object(ck8s, '_exec_cmd', return_value=0)
    @patch.object(ck8s, '_check_if_configmap_exist', return_value=False)
    @patch.object(ck8s, 'sp')
    def test_missing_hostpath_raises(self, mock_sp, _mock_check, _mock_exec):
        """Raises ValueError when hostPath file doesn't exist."""
        mock_sp.parse_volume_string_to_dict.return_value = (
            {'pathType': 'File', 'hostPath': '/nonexistent/file.conf',
             'mounthPath': '/etc/test.conf', 'name': 'bad-vol'},
            None
        )
        mock_sp.get_k8s_configmap_name.return_value = 'bad-configmap'
        data = {
            'platform::kubernetes::kube_apiserver_volumes::params::bad-vol':
                'hostPath=/nonexistent/file.conf,pathType=File',
        }
        hiera_path = self._write_hieradata(data)
        flag_fd, flag_path = tempfile.mkstemp()
        os.close(flag_fd)
        try:
            with self.assertRaises(ValueError):
                ck8s.initialize_k8s_configmaps(
                    hiera_path, flag_path, {}, {}, {}, {}, {})
        finally:
            for p in (hiera_path, flag_path):
                if os.path.exists(p):
                    os.unlink(p)


class TestGetServiceParamsMoreBranches(unittest.TestCase):
    """Tests for get_service_parameters_from_hieradata error paths."""

    @staticmethod
    def _write_hieradata(data):
        fd, path = tempfile.mkstemp(suffix='.yaml')
        with os.fdopen(fd, 'w') as f:
            yaml.dump(data, f)
        return path

    def test_controller_manager_volumes(self):
        """Parses controller manager volume params."""
        data = {
            'platform::kubernetes::kube_controller_manager_volumes::params::vol1':
                'hostPath=/etc/cm.conf,pathType=File',
        }
        path = self._write_hieradata(data)
        try:
            result = ck8s.get_service_parameters_from_hieradata(
                path, {}, {}, {}, {}, {})
            self.assertIn('vol1', result['controllerManagerVolumes'])
        finally:
            os.unlink(path)

    def test_scheduler_volumes(self):
        """Parses scheduler volume params."""
        data = {
            'platform::kubernetes::kube_scheduler_volumes::params::sched-vol':
                'hostPath=/etc/sched.conf,pathType=File',
        }
        path = self._write_hieradata(data)
        try:
            result = ck8s.get_service_parameters_from_hieradata(
                path, {}, {}, {}, {}, {})
            self.assertIn('sched-vol', result['schedulerVolumes'])
        finally:
            os.unlink(path)

    def test_config_params(self):
        """Parses config section params."""
        data = {
            'platform::kubernetes::config::params::pod-max-pids': '4096',
        }
        path = self._write_hieradata(data)
        try:
            result = ck8s.get_service_parameters_from_hieradata(
                path, {}, {}, {}, {}, {})
            self.assertEqual(result['config']['pod-max-pids'], '4096')
        finally:
            os.unlink(path)

    def test_multiple_schema_sections(self):
        """Schema with multiple sections translates correctly."""
        data = {
            'platform::kubernetes::kubelet::params::old-param': 'val',
        }
        schema = {
            'section_a': {'not-this': 'x'},
            'section_b': {'old-param': 'new-param'}
        }
        path = self._write_hieradata(data)
        try:
            result = ck8s.get_service_parameters_from_hieradata(
                path, {}, {}, {}, schema, {})
            self.assertIn('new-param', result['kubelet'])
        finally:
            os.unlink(path)


class TestUpdateKubeletBakSecondFailure(unittest.TestCase):
    """Test second copy failure in update_kubelet_bak_config_files."""

    def test_second_copy_failure(self):
        """Returns 1 when second copyfile fails."""
        fd, src1 = tempfile.mkstemp()
        os.write(fd, b'data')
        os.close(fd)
        fd2, dst1 = tempfile.mkstemp()
        os.close(fd2)
        try:
            rc = ck8s.update_kubelet_bak_config_files(
                src1, dst1, '/nonexistent/src2', '/tmp/dst2')
            self.assertEqual(rc, 1)
        finally:
            for p in (src1, dst1):
                if os.path.exists(p):
                    os.unlink(p)


if __name__ == '__main__':
    unittest.main()

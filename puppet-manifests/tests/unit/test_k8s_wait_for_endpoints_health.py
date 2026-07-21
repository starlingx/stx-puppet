#
# Copyright (c) 2026 Wind River Systems, Inc.
#
# SPDX-License-Identifier: Apache-2.0
#


"""Coverage tests for k8s_wait_for_endpoints_health.py."""

import logging
import sys
import unittest
from unittest import mock
from unittest.mock import patch

# Mock sysinv before importing - platform package not available in CI
sys.modules['sysinv'] = mock.MagicMock()
sys.modules['sysinv.common'] = mock.MagicMock()
sys.modules['sysinv.common.kubernetes'] = mock.MagicMock()
# The module calls setup_logger() at import time which creates /var/log/kubernetes/
with mock.patch('os.makedirs'), mock.patch('logging.FileHandler'):
    import debian.bullseye.src.bin.k8s_wait_for_endpoints_health as k8s_health


class TestK8sWaitForEndpointsHealth(unittest.TestCase):
    """Tests for k8s_wait_for_endpoints_health()."""

    @patch.object(k8s_health, 'LOG')
    def test_all_healthy_returns_zero(self, _mock_log):
        """Should return 0 when all endpoints are healthy."""
        k8s_health.kubernetes.k8s_health_check.return_value = True
        result = k8s_health.k8s_wait_for_endpoints_health(tries=1, try_sleep=0, timeout=1)
        self.assertEqual(result, 0)

    @patch.object(k8s_health, 'LOG')
    def test_one_unhealthy_returns_one(self, _mock_log):
        """Should return 1 when any endpoint is unhealthy."""
        k8s_health.kubernetes.k8s_health_check.side_effect = [True, True, False, True]
        result = k8s_health.k8s_wait_for_endpoints_health(tries=1, try_sleep=0, timeout=1)
        self.assertEqual(result, 1)
        k8s_health.kubernetes.k8s_health_check.side_effect = None

    @patch.object(k8s_health, 'LOG')
    def test_first_unhealthy_returns_one(self, _mock_log):
        """Should return 1 immediately when first endpoint
        is unhealthy.
        """
        k8s_health.kubernetes.k8s_health_check.side_effect = [False]
        result = k8s_health.k8s_wait_for_endpoints_health(tries=1, try_sleep=0, timeout=1)
        self.assertEqual(result, 1)
        k8s_health.kubernetes.k8s_health_check.side_effect = None

    @patch.object(k8s_health, 'LOG')
    def test_passes_parameters(self, _mock_log):
        """Should pass tries, try_sleep, timeout to k8s_health_check."""
        k8s_health.kubernetes.k8s_health_check.return_value = True
        k8s_health.k8s_wait_for_endpoints_health(tries=5, try_sleep=2, timeout=10)
        call_kwargs = k8s_health.kubernetes.k8s_health_check.call_args_list[-1][1]
        self.assertEqual(call_kwargs['tries'], 5)
        self.assertEqual(call_kwargs['try_sleep'], 2)
        self.assertEqual(call_kwargs['timeout'], 10)


class TestK8sMain(unittest.TestCase):
    """Tests for k8s_wait_for_endpoints_health main()."""

    @patch.object(k8s_health, 'k8s_wait_for_endpoints_health', return_value=0)
    def test_main_returns_zero(self, mock_wait):
        """Should return 0 when endpoints are healthy."""
        with patch('sys.argv', ['prog', '--tries', '5', '--try_sleep', '1', '--timeout', '3']):
            return_code = k8s_health.main()
        self.assertEqual(return_code, 0)
        mock_wait.assert_called_once()

    @patch.object(k8s_health, 'k8s_wait_for_endpoints_health', return_value=1)
    def test_main_returns_one(self, _mock_wait):
        """Should return 1 when endpoints are unhealthy."""
        with patch('sys.argv', ['prog']):
            return_code = k8s_health.main()
        self.assertEqual(return_code, 1)


class TestK8sSetupLogger(unittest.TestCase):
    """Tests for setup_logger()."""

    @patch('logging.FileHandler')
    @patch('os.path.exists', return_value=True)
    def test_setup_logger_dir_exists(self, _mock_exists, _mock_fh):
        """Should not create dir if it already exists."""
        with patch('os.makedirs') as mock_mkdirs:
            logger = k8s_health.setup_logger()
        mock_mkdirs.assert_not_called()
        self.assertIsNotNone(logger)

    @patch('logging.FileHandler')
    @patch('os.makedirs')
    @patch('os.path.exists', return_value=False)
    def test_setup_logger_creates_dir(self, _mock_exists, mock_mkdirs, _mock_fh):
        """Should create log directory if it does not exist."""
        logger = k8s_health.setup_logger()
        mock_mkdirs.assert_called_once_with('/var/log/kubernetes/')
        self.assertIsNotNone(logger)

    @patch('logging.FileHandler')
    @patch('os.path.exists', return_value=True)
    def test_setup_logger_returns_logger(self, _mock_exists, _mock_fh):
        """Should return a logging.Logger instance."""
        logger = k8s_health.setup_logger()
        self.assertIsInstance(logger, logging.Logger)

#!/usr/bin/python3
#
# Copyright (c) 2021-2023 Wind River Systems, Inc.
#
# SPDX-License-Identifier: Apache-2.0
#
'''This program waits for Kubernetes control-plane endpoints
(apiserver, scheduler, controller-manager, kubelet) on the
localhost to be up and running.
'''

import argparse
import logging
import os
import sys
from sysinv.common import kubernetes  # pylint: disable=import-error

# pylint: disable-msg=broad-except

kube_operator = kubernetes.KubeOperator()


# Kubernetes component endpoints on the localhost
APISERVER_READYZ_ENDPOINT = 'https://localhost:6443/readyz'
SCHEDULER_HEALTHZ_ENDPOINT = "https://127.0.0.1:10259/healthz"
CONTROLLER_MANAGER_HEALTHZ_ENDPOINT = "https://127.0.0.1:10257/healthz"
KUBELET_HEALTHZ_ENDPOINT = "http://localhost:10248/healthz"

# Configure these parameters to wait up to 3 minutes
TRIES = 20
TRY_SLEEP = 5
TIMEOUT = 5


# Logging
def setup_logger():
    """Setup a logger."""

    LOGGER_FORMAT = "%(asctime)s.%(msecs)03d %(process)d [%(levelname)s] %(message)s"
    LOGGER_NAME = 'k8s-endpoints-health'
    logger = logging.getLogger(LOGGER_NAME)
    logger.setLevel(logging.DEBUG)
    root_logs = '/var/log/kubernetes/'
    if not os.path.exists(root_logs):
        os.makedirs(root_logs)
    log_format = logging.Formatter(LOGGER_FORMAT)
    fullname = os.path.join(root_logs, LOGGER_NAME + '.log')
    log_handler = logging.FileHandler(fullname)
    log_handler.setFormatter(log_format)
    logger.addHandler(log_handler)
    return logger


LOG = setup_logger()


def k8s_wait_for_endpoints_health(tries=TRIES, try_sleep=TRY_SLEEP, timeout=TIMEOUT):
    """This function checks the k8s control-plane endpoints health
    and retries for the given timeout.
    """

    healthz_endpoints = [APISERVER_READYZ_ENDPOINT, CONTROLLER_MANAGER_HEALTHZ_ENDPOINT,
                         SCHEDULER_HEALTHZ_ENDPOINT, KUBELET_HEALTHZ_ENDPOINT]
    for endpoint in healthz_endpoints:
        is_k8s_endpoint_healthy = kubernetes.k8s_health_check(tries=tries,
                                                              try_sleep=try_sleep,
                                                              timeout=timeout,
                                                              healthz_endpoint=endpoint)
        if not is_k8s_endpoint_healthy:
            LOG.error("Timeout: Kubernetes control-plane endpoints not healthy")
            return 1

    LOG.info("k8s control-plane endpoints are healthy")
    return 0


def main():
    # Args Parameters
    parser = argparse.ArgumentParser()
    parser.add_argument("--tries", default=TRIES)
    parser.add_argument("--try_sleep", default=TRY_SLEEP)
    parser.add_argument("--timeout", default=TIMEOUT)
    args = parser.parse_args()

    tries = args.tries
    try_sleep = args.try_sleep
    timeout = args.timeout

    rc = k8s_wait_for_endpoints_health(tries=tries, try_sleep=try_sleep,
                                       timeout=timeout)
    return rc


if __name__ == "__main__":
    sys.exit(main())

#
# Copyright (c) 2026 Wind River Systems, Inc.
#
# SPDX-License-Identifier: Apache-2.0
#

"""Shared test constants for stx-puppet test modules.

Centralizes commonly used test values to avoid
duplication across test files.
"""

TEST_IPV4_ADDRESS = "10.0.0.1"
TEST_IPV4_ADDRESS_2 = "10.0.0.2"
TEST_IPV4_NETWORK = "10.0.0.0"
TEST_IPV4_NETMASK = "255.255.255.0"
TEST_IPV4_CIDR = "10.0.0.0/24"
TEST_IPV4_LOOPBACK = "192.168.1.1"

TEST_IPV6_ADDRESS = "fd00::1"
TEST_IPV6_LOOPBACK = "::1"

TEST_IFACE_NAME = "eth0"
TEST_IFACE_NAME_2 = "eth1"
TEST_BOND_NAME = "bond0"

KUBE_APISERVER_PORT = 16443
KUBE_API_ENDPOINT = "https://localhost:16443"

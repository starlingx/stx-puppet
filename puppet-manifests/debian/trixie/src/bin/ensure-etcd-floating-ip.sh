#!/bin/bash
#
# Copyright (c) 2026 Wind River Systems, Inc.
#
# SPDX-License-Identifier: Apache-2.0
#
# Ensure the cluster-host floating IP is on the interface before etcd starts.
# On AIO it is on loopback from bootstrap. On Standard, SM assigns it during
# go-active but etcd may start before that completes.
IP=$(grep "platform::network::cluster_host::params::controller_address:" /tmp/puppet/hieradata/system.yaml 2>/dev/null | grep -v url | awk '{print $2}' | head -1)
IFACE=$(grep "platform::network::cluster_host::params::interface_name:" /tmp/puppet/hieradata/host.yaml 2>/dev/null | awk '{print $2}' | head -1)
PREFIX=$(grep "platform::network::cluster_host::params::subnet_prefixlen:" /tmp/puppet/hieradata/system.yaml 2>/dev/null | awk '{print $2}' | head -1)
PREFIX=${PREFIX:-24}

# Only the active controller owns the floating VIP; Service Manager assigns
# it during go-active. The active controller is the one holding the
# management floating address. Adding the cluster-host floating VIP on the
# standby creates a duplicate that makes the standby deliver cluster-host
# traffic (kube-apiserver join :6443, etcd peer :2380) to itself instead of
# the active controller, so the standby cannot join. Skip on the standby.
MGMT_FLOATING_IP=$(grep "platform::network::mgmt::params::controller_address:" /tmp/puppet/hieradata/system.yaml 2>/dev/null | grep -v url | awk '{print $2}' | head -1)
if [ -z "${MGMT_FLOATING_IP}" ] || ! ip -o addr show | grep -qF " ${MGMT_FLOATING_IP}/"; then
    logger -p daemon.info "ensure-etcd-floating-ip: not the active controller, skipping"
    exit 0
fi

if [ -n "$IP" ] && [ -n "$IFACE" ]; then
    if ! ip addr show | grep -qw "$IP"; then
        ip addr add ${IP}/${PREFIX} dev ${IFACE} scope host 2>/dev/null || true
        logger -p daemon.info "ensure-etcd-floating-ip: added ${IP}/${PREFIX} on ${IFACE}"
    fi
fi

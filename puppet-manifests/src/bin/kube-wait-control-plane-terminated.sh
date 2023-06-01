#!/bin/bash
################################################################################
# Copyright (c) 2023 Wind River Systems, Inc.
#
# SPDX-License-Identifier: Apache-2.0
#
################################################################################

#  The purpose of this script is to wait until the control plane pods
#  process exit and then forcibly kill those specific pids if the timeout expires.


PATH=/bin:/usr/bin:/sbin:/usr/sbin
NAME=$(basename $0)
TIMEOUT=30
SECONDS=0

# Log info message to /var/log/daemon.log
function LOG {
    logger -p daemon.info -t "${NAME}($$): " "$@"
}

LOG "wait for control plane pods on this host to terminate"
while [ ${SECONDS} -lt ${TIMEOUT} ]; do
    if pgrep -f '^kube-apiserver|^kube-scheduler|^kube-controller-manager' 2>/dev/null; then
        sleep 1
    else
        LOG "control plane pods gracefully terminated"
        exit 0
    fi
done

LOG "killing control plane processes"
pkill -e -KILL -f '^kube-scheduler|^kube-controller-manager|^kube-apiserver' 2>/dev/null | LOG
exit 0

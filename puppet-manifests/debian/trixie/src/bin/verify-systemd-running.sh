#!/bin/bash
################################################################################
# Copyright (c) 2024 Wind River Systems, Inc.
#
# SPDX-License-Identifier: Apache-2.0
#
################################################################################

# The purpose of this script is to wait for systemd to behave without
# systemctl timeout. This is to mitigate systemd hung behaviour immediately
# after daemon-reload/and when multiple services are restarted in parallel.

PATH=/bin:/usr/bin:/sbin:/usr/sbin
NAME=$(basename $0)
CMD='timeout 5 systemctl is-system-running'
RC_TIMEOUT=124
MAX_ATTEMPTS=6
SLEEP=15

# Log info message to /var/log/daemon.log
function LOG {
    logger -p daemon.info -t "${NAME}($$): " "$@"
}

LOG "Waiting for systemd is-system-running"
cnt=1
r=$( ${CMD} )
rc=$?
until [[ ${rc} -ne ${RC_TIMEOUT} && ( "${r}" == "starting" || "${r}" == "running" || "${r}" == "degraded" ) ]]; do
    LOG "DEBUG: cnt = ${cnt}, rc = ${rc}, state = ${r}"

    if [[ ${cnt} -eq ${MAX_ATTEMPTS} ]]; then
        LOG "ERROR: Exceeded attempts. cnt = ${cnt}, rc = ${rc}, state = ${r}"
        exit 1
    fi
    sleep ${SLEEP}
    cnt=$((cnt + 1))
    r=$( ${CMD} )
    rc=$?
done

LOG "PASS: cnt = ${cnt}, rc = ${rc}, state = ${r}"
exit 0

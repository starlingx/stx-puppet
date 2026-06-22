#!/bin/bash
#
# Copyright (c) 2026 Wind River Systems, Inc.
#
# SPDX-License-Identifier: Apache-2.0
#
# ptp-instance-notify.sh — Generic Type=notify wrapper for PTP services
# Usage: ptp-instance-notify.sh <service> <instance> <conf_dir>
# Starts the service, waits for UDS socket, then notifies systemd ready.
# Fallback: if no socket after 2s but process is alive, notify ready anyway
SERVICE=$1
INSTANCE=$2
CONF_DIR=$3

/usr/sbin/${SERVICE} -f ${CONF_DIR}/ptpinstance/${SERVICE}-${INSTANCE}.conf $OPTIONS &
PID=$!

for i in 1 2 3 4; do
    kill -0 $PID 2>/dev/null || exit 1
    [ -S /var/run/${SERVICE}-${INSTANCE} ] && {
        systemd-notify --ready --pid=$PID
        echo $PID > /var/run/${SERVICE}-${INSTANCE}.pid
        wait $PID
        exit $?
    }
    sleep 0.5
done

# Fallback: no socket after 2s, but process is alive — notify ready anyway
kill -0 $PID 2>/dev/null || exit 1
systemd-notify --ready --pid=$PID
echo $PID > /var/run/${SERVICE}-${INSTANCE}.pid
wait $PID
exit $?

#!/bin/bash
################################################################################
# Copyright (c) 2023 Wind River Systems, Inc.
#
# SPDX-License-Identifier: Apache-2.0
#
################################################################################

shutdown_drbd_resource=$1
is_controller_active=$2
system_mode=$3
action=$4
config=$5

if [ -n "${shutdown_drbd_resource}" ] && \
    { [ "${is_controller_active}" = "false" ] || \
    [ "${system_mode}" = "simplex" ]; }; then
    if [ -f /var/run/goenabled ]; then
        sm-unmanage service "${shutdown_drbd_resource}"
    fi

    if [ "${shutdown_drbd_resource}" = "drbd-cinder" ] && \
    [ "${system_mode}" = "simplex" ]; then
        if [ -f /var/run/goenabled ]; then
            sm-unmanage service cinder-lvm
        fi

        targetctl clear || exit 5
        lvchange -an cinder-volumes || exit 10
        vgchange -an cinder-volumes || exit 20
        drbdadm secondary drbd-cinder || exit 30
    fi

    DRBD_UNCONFIGURED_TIMEOUT=180
    DRBD_UNCONFIGURED_DELAY=0
    while [[ ${DRBD_UNCONFIGURED_DELAY} -lt ${DRBD_UNCONFIGURED_TIMEOUT} ]]; do
        drbdadm down "${shutdown_drbd_resource}"
        drbd_info=$(drbd-overview | grep "${shutdown_drbd_resource}" |\
        awk '{print $2}')

        if [[ "${drbd_info}" == "Unconfigured" ]]; then
            break
        else
            sleep 2
            DRBD_UNCONFIGURED_DELAY=$((DRBD_UNCONFIGURED_DELAY + 2))
        fi
    done

    if [[ ${DRBD_UNCONFIGURED_DELAY} -eq ${DRBD_UNCONFIGURED_TIMEOUT} ]]; then
        exit 40
    fi
fi

manage-partitions "${action}" "${config}"

if [ -n "${shutdown_drbd_resource}" ] && \
    { [ "${is_controller_active}" = "false" ] || \
    [ "${system_mode}" = "simplex" ]; }; then
    drbdadm up "${shutdown_drbd_resource}" || exit 30

    if [ "${shutdown_drbd_resource}" = "drbd-cinder" ] && \
    [ "${system_mode}" = "simplex" ]; then
        drbdadm primary drbd-cinder || exit 50
        vgchange -ay cinder-volumes || exit 60
        lvchange -ay cinder-volumes || exit 70
        targetctl restore || exit 75

        if [ -f /var/run/goenabled ]; then
            sm-manage service "${shutdown_drbd_resource}"
            sm-manage service cinder-lvm
        fi
    fi

    if [ -f /var/run/goenabled ]; then
        sm-manage service "${shutdown_drbd_resource}"
    fi
fi

#!/bin/bash

################################################################################
# Copyright (c) 2023 Wind River Systems, Inc.
#
# SPDX-License-Identifier: Apache-2.0
#
################################################################################

#
#  The purpose of this script is to remove unused HostEndpoints from calico.
#
#  During the puppet class platform::firewall::calico::hostendpoint execution
#  a file /tmp/hep_active.txt is generated with active host endpoints.
#
#  This file is then compared with the installed endpoints in calico and the
#  non-active ones are removed
#
#  We are not handling the OAM hostendpoint interface for now

function log_it {
    # check /var/log/user.log for the messages
    logger "${BASH_SOURCE[1]} ${1}"
}

if [ ! -f /tmp/hep_active.txt ]; then
    log_it "file /tmp/hep_active.txt does not exist, cannot proceed";
    exit 1
fi

hostname=$(cat /etc/hostname)
# the HostEndpoint format is [hostname]-[ifname]-if-hep
for hep in $(kubectl --kubeconfig=/etc/kubernetes/admin.conf get hostendpoints --no-headers | grep ${hostname} | awk '{print $1}'); do
    # We are not handling the OAM hostendpoint interface for now
    if [[ ! ${hep} =~ .*"-oam-if-hep" ]]; then
        count=$(grep -c ${hep} /tmp/hep_active.txt);
        if [ "$count" == "0" ]; then
            log_it "remove non-active ${hep} from calico"
            kubectl --kubeconfig=/etc/kubernetes/admin.conf delete hostendpoints ${hep};
        fi
    fi
done

exit 0

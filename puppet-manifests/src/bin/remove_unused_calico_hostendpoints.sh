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

hostname=${1}
hep_active_file=${2}

if [ ! -f ${hep_active_file} ]; then
    log_it "file ${hep_active_file} does not exist, cannot proceed";
    exit 1
fi

kubeconfig="/etc/kubernetes/admin.conf"

# the HostEndpoint format is [hostname]-[ifname]-if-hep
for hep in $(kubectl --kubeconfig=${kubeconfig} get hostendpoints --no-headers | grep ${hostname} | awk '{print $1}'); do
    # We are not handling the OAM hostendpoint interface for now
    if [[ ! ${hep} =~ .*"-oam-if-hep" ]]; then
        count=$(grep -c ${hep} ${hep_active_file});
        if [ "$count" == "0" ]; then
            log_it "remove non-active ${hep} from calico";
            kubectl --kubeconfig=${kubeconfig} delete hostendpoints ${hep};
            if [ "$?" -ne 0 ]; then
                log_it "Failed to delete ${hep} with ${hep_active_file}"
                exit 1
            fi
        fi
    fi
done

exit 0

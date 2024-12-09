#!/bin/bash

################################################################################
# Copyright (c) 2023-2024 Wind River Systems, Inc.
#
# SPDX-License-Identifier: Apache-2.0
#
################################################################################

#
#  The purpose of this script is to apply globalnetworkpolicies to calico.
#

function log_it {
    # check /var/log/user.log for the messages
    logger "${BASH_SOURCE[1]} ${1}"
}


gnp_name=${1}
file_name_gnp=${2}
kubeconfig=${3}

resource_name='globalnetworkpolicies.crd.projectcalico.org';

resource_exist=$(kubectl --kubeconfig=${kubeconfig} get --no-headers customresourcedefinitions.apiextensions.k8s.io ${resource_name} | awk '{print $1}');
if [[ ${resource_exist} == "${resource_name}" ]]; then
    gnp_exist=$(kubectl --kubeconfig=${kubeconfig} get --no-headers ${resource_name} ${gnp_name} 2> /dev/null | awk '{print $1}');
    if [[ ${gnp_exist} == "${gnp_name}" ]]; then
        # Remove annotation as it contains last-applied-configuration with
        # resourceVersion in it, which will require the gnp re-apply to
        # provide a matching resourceVersion in the yaml file.
        kubectl --kubeconfig=${kubeconfig} annotate ${resource_name} ${gnp_name} kubectl.kubernetes.io/last-applied-configuration-;
        if [ "$?" -ne 0 ]; then
            log_it "Failed to remove last-applied-configuration annotation from ${gnp_name}"
            exit 1
        fi
        kubectl --kubeconfig=${kubeconfig} replace -f ${file_name_gnp};
        if [ "$?" -ne 0 ]; then
            log_it "Failed to replace ${gnp_name} with ${file_name_gnp}"
            exit 1
        fi
    else
        kubectl --kubeconfig=${kubeconfig} create -f ${file_name_gnp};
        if [ "$?" -ne 0 ]; then
            log_it "Failed to create ${gnp_name} with ${file_name_gnp}"
            exit 1
        fi
    fi

    log_it "Successfully applied ${gnp_name} with ${file_name_gnp}"
    if [ -f /etc/platform/.platform_firewall_config_required ]; then
        log_it "remove flag platform_firewall_config_required"
        rm -fv /etc/platform/.platform_firewall_config_required
    fi
else
    log_it "Failed to check ${resource_name} exists, mark for sysinv to reapply"
    touch /etc/platform/.platform_firewall_config_required
fi

exit 0

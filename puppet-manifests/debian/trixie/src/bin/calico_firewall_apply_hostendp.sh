#!/bin/bash

################################################################################
# Copyright (c) 2023-2025 Wind River Systems, Inc.
#
# SPDX-License-Identifier: Apache-2.0
#
################################################################################

#
#  The purpose of this script is to apply hostendpoints to calico.
#

function log_it {
    # check /var/log/user.log for the messages
    logger "${BASH_SOURCE[1]} ${1}"
}

function _is_kubeapi_server_avail {
    local config=${1}
    api_status=$(KUBECONFIG=${config} kubectl get --raw "/readyz"  2> /dev/null)
    if [[ ${api_status} == "ok" ]]; then
        return 0
    else
        log_it "Kubernetes API isn't available, status=${api_status}"
        return 1
    fi
}

hep_name=${1}
file_name_hep=${2}
kubeconfig=${3}

# Ensure all required arguments are provided
if [[ -z "${hep_name}" || -z "${file_name_hep}" || -z "${kubeconfig}" ]]; then
    log_it "Error: Missing required arguments. Usage: $0 <hep_name> <file_name_hep> <kubeconfig_path>"
    exit 1
fi

if ! _is_kubeapi_server_avail "${kubeconfig}"; then
    log_it "Kubernetes API isn't available, mark for sysinv to reapply"
    touch /etc/platform/.platform_firewall_config_required
    exit 0
fi

if [[ ! -f ${file_name_hep} ]]; then
    log_it "for ${hep_name} file ${file_name_hep} does not exist"
    exit 1
fi

resource_name='hostendpoints.crd.projectcalico.org';

resource_exist=$(kubectl --kubeconfig="${kubeconfig}" get  --no-headers customresourcedefinitions.apiextensions.k8s.io ${resource_name} | awk '{print $1}');
if [[ ${resource_exist} == "${resource_name}" ]]; then
    if ! kubectl --kubeconfig="${kubeconfig}" apply -f "${file_name_hep}"; then
        log_it "Failed to apply ${hep_name} with ${file_name_hep}"
        exit 1
    else
        log_it "Successfully applied ${hep_name} with ${file_name_hep}"
        if [ -f /etc/platform/.platform_firewall_config_required ]; then
            log_it "remove flag platform_firewall_config_required"
            rm -fv /etc/platform/.platform_firewall_config_required
        fi
    fi
else
    log_it "Failed to check if ${resource_name} exists, mark for sysinv to reapply"
    touch /etc/platform/.platform_firewall_config_required
fi

exit 0

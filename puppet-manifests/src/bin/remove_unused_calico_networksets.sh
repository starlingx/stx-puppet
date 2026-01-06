#!/bin/bash

################################################################################
# Copyright (c) 2025 Wind River Systems, Inc.
#
# SPDX-License-Identifier: Apache-2.0
#
################################################################################

#
#  The purpose of this script is to remove unused globalnetworksets from calico.
#
#  Called by the puppet class platform::firewall::calico::gnset execution
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

gns_name=${1}
kubeconfig=${2}

# Ensure all required arguments are provided
if [[ -z "${gns_name}" || -z "${kubeconfig}" ]]; then
    log_it "Error: Missing required arguments. Usage: $0 <gns_name> <kubeconfig_path>"
    exit 1
fi

if ! _is_kubeapi_server_avail "${kubeconfig}"; then
    log_it "Kubernetes API isn't available, mark for sysinv to reapply"
    touch /etc/platform/.platform_firewall_config_required
    exit 0
fi

resource_name='globalnetworksets.crd.projectcalico.org';
resource_exist=$(kubectl --kubeconfig="${kubeconfig}" get --no-headers customresourcedefinitions.apiextensions.k8s.io ${resource_name} | awk '{print $1}');
if [[ ${resource_exist} == "${resource_name}" ]]; then
    gns_exist=$(kubectl --kubeconfig="${kubeconfig}" get --no-headers ${resource_name} "${gns_name}" 2> /dev/null | awk '{print $1}');
    if [[ ${gns_exist} == "${gns_name}" ]]; then
        if ! kubectl --kubeconfig="${kubeconfig}" delete ${resource_name} "${gns_name}"; then
            log_it "Failed to delete ${gns_name}"
            exit 1
        else
            log_it "Successfully deleted ${gns_name}"
        fi
    fi
else
    log_it "Failed to check if ${resource_name} exists"
    exit 1
fi

exit 0

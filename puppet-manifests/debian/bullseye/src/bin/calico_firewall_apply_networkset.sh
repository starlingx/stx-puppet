#!/bin/bash

################################################################################
# Copyright (c) 2025 Wind River Systems, Inc.
#
# SPDX-License-Identifier: Apache-2.0
#
################################################################################

#
#  The purpose of this script is to apply globalnetworksets to calico.
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
file_name_gns=${2}
kubeconfig=${3}

# Ensure all required arguments are provided
if [[ -z "${gns_name}" || -z "${file_name_gns}" || -z "${kubeconfig}" ]]; then
    log_it "Error: Missing required arguments. Usage: $0 <gns_name> <gnp_file> <kubeconfig_path>"
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
        # Remove annotation as it contains last-applied-configuration with
        # resourceVersion in it, which will require the gnp re-apply to
        # provide a matching resourceVersion in the yaml file.
        if ! kubectl --kubeconfig="${kubeconfig}" annotate ${resource_name} "${gns_name}" kubectl.kubernetes.io/last-applied-configuration-; then
            log_it "Failed to remove last-applied-configuration annotation from ${gns_name}"
            exit 1
        fi
        if ! kubectl --kubeconfig="${kubeconfig}" replace -f "${file_name_gns}"; then
            log_it "Failed to replace ${gns_name} with ${file_name_gns}"
            exit 1
        fi
    else
        if ! kubectl --kubeconfig="${kubeconfig}" create -f "${file_name_gns}"; then
            log_it "Failed to create ${gns_name} with ${file_name_gns}"
            exit 1
        fi
    fi

    log_it "Successfully applied ${gns_name} with ${file_name_gns}"
    if [ -f /etc/platform/.platform_firewall_config_required ]; then
        log_it "remove flag platform_firewall_config_required"
        rm -fv /etc/platform/.platform_firewall_config_required
    fi
else
    log_it "Failed to check ${resource_name} exists, mark for sysinv to reapply"
    touch /etc/platform/.platform_firewall_config_required
fi

exit 0

#!/bin/bash

################################################################################
# Copyright (c) 2023-2026 Wind River Systems, Inc.
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

gnp_name=${1}
file_name_gnp=${2}
kubeconfig=${3}

# Ensure all required arguments are provided
if [[ -z "${gnp_name}" || -z "${file_name_gnp}" || -z "${kubeconfig}" ]]; then
    log_it "Error: Missing required arguments. Usage: $0 <gnp_name> <file_name_gnp> <kubeconfig_path>"
    exit 1
fi

if ! _is_kubeapi_server_avail "${kubeconfig}"; then
    log_it "Kubernetes API isn't available, mark for sysinv to reapply"
    touch /etc/platform/.platform_firewall_config_required
    exit 0
fi

resource_name='globalnetworkpolicies.crd.projectcalico.org';

resource_exist=$(kubectl --kubeconfig="${kubeconfig}" get --no-headers customresourcedefinitions.apiextensions.k8s.io ${resource_name} | awk '{print $1}');
if [[ ${resource_exist} == "${resource_name}" ]]; then
    gnp_exist=$(kubectl --kubeconfig="${kubeconfig}" get --no-headers ${resource_name} "${gnp_name}" 2> /dev/null | awk '{print $1}');
    if [[ ${gnp_exist} == "${gnp_name}" ]]; then
        # Remove annotation as it contains last-applied-configuration with
        # resourceVersion in it, which will require the gnp re-apply to
        # provide a matching resourceVersion in the yaml file.
        if ! kubectl --kubeconfig="${kubeconfig}" annotate ${resource_name} "${gnp_name}" kubectl.kubernetes.io/last-applied-configuration-; then
            log_it "Failed to remove last-applied-configuration annotation from ${gnp_name}"
            exit 1
        fi
    fi
    if ! kubectl --kubeconfig="${kubeconfig}" apply -f "${file_name_gnp}"; then
        log_it "Failed to apply ${gnp_name} with ${file_name_gnp}"
        exit 1
    else
        log_it "Successfully applied ${gnp_name} with ${file_name_gnp}"
        if [ -f /etc/platform/.platform_firewall_config_required ]; then
            log_it "remove flag platform_firewall_config_required"
            rm -fv /etc/platform/.platform_firewall_config_required
        fi
    fi

else
    log_it "Failed to check ${resource_name} exists, mark for sysinv to reapply"
    touch /etc/platform/.platform_firewall_config_required
fi

exit 0

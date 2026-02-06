#!/bin/bash

################################################################################
# Copyright (c) 2023-2025 Wind River Systems, Inc.
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

hostname=${1}
hep_active_file=${2}
kubeconfig=${3}

# Ensure all required arguments are provided
if [[ -z "${hostname}" || -z "${hep_active_file}" || -z "${kubeconfig}" ]]; then
    log_it "Error: Missing required arguments. Usage: $0 <gnp_name> <file_name_gnp> <kubeconfig_path>"
    exit 1
fi

if ! _is_kubeapi_server_avail "${kubeconfig}"; then
    log_it "Kubernetes API isn't available, mark for sysinv to reapply"
    touch /etc/platform/.platform_firewall_config_required
    exit 0
fi

if [ ! -f "${hep_active_file}" ]; then
    log_it "file ${hep_active_file} does not exist, cannot proceed";
    exit 1
fi

# the HostEndpoint format is [hostname]-[ifname]-if-hep
for hep in $(kubectl --kubeconfig="${kubeconfig}" get hostendpoints --no-headers | grep "${hostname}" | awk '{print $1}'); do
    count=$(grep -c "${hep}" "${hep_active_file}");
    if [ "${count}" == "0" ]; then
        log_it "remove non-active ${hep} from calico";
        if ! kubectl --kubeconfig="${kubeconfig}" delete hostendpoints "${hep}"; then
            log_it "Failed to delete ${hep} with ${hep_active_file}"
            exit 1
        fi
    fi
done

exit 0

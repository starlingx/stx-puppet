#!/bin/bash

################################################################################
# Copyright (c) 2023 Wind River Systems, Inc.
#
# SPDX-License-Identifier: Apache-2.0
#
################################################################################

#
#  The purpose of this script is to remotely apply the globalnetworkpolicies
#  configuration, from the worker nodes in the controller.
#
#  This is necessary as it is not possible to execute kubectl from the workers. It
#  uses ansible ad-hoc commands.
#

function log_it {
    # check /var/log/user.log for the messages
    logger "${BASH_SOURCE[1]} ${1}"
}

gnp_name=${1}
file_name_gnp=${2}

hostname=$(cat /etc/hostname)

# shellcheck disable=SC1091
source /etc/build.info
OS_PASSWORD=$(TERM=linux /opt/platform/.keyring/${SW_VERSION}/.CREDENTIAL 2>/dev/null)
cat <<EOF > /tmp/ansible_adhoc_host
---
all:
  hosts:
    controller:
      ansible_connection: ssh

  vars:
    ansible_ssh_user: sysadmin
    ansible_ssh_pass: ${OS_PASSWORD}
EOF

dest_file="${file_name_gnp}.${hostname}"

ansible controller -i /tmp/ansible_adhoc_host -m ansible.builtin.copy -a "src=${file_name_gnp} dest=${dest_file}"
if [ "$?" -ne 0 ]; then
    log_it "Failed to remote copy ${hostname}:${file_name_gnp} to controller:${dest_file} "
    rm -f /tmp/ansible_adhoc_host
    touch /etc/platform/.platform_firewall_config_required
    exit 0
fi

ansible controller -i /tmp/ansible_adhoc_host -m ansible.builtin.shell -a "/usr/local/bin/calico_firewall_apply_policy.sh ${gnp_name} ${dest_file}"
if [ "$?" -ne 0 ]; then
    log_it "Failed to remote apply globalnetworkpolicy ${gnp_name} with file ${file_name_gnp}"
    rm -f /tmp/ansible_adhoc_host
    touch /etc/platform/.platform_firewall_config_required
    exit 0
else
    log_it "Successfully applied ${gnp_name} with ${file_name_gnp}"
    if [ -f /etc/platform/.platform_firewall_config_required ]; then
        log_it "remove flag platform_firewall_config_required"
        rm -fv /etc/platform/.platform_firewall_config_required
    fi
fi

rm -f /tmp/ansible_adhoc_host
exit 0

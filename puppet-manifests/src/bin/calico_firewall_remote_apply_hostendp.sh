#!/bin/bash

################################################################################
# Copyright (c) 2023 Wind River Systems, Inc.
#
# SPDX-License-Identifier: Apache-2.0
#
################################################################################

#
#  The purpose of this script is to remotely apply the HostEndpoints configuration,
#  from the worker nodes in the controller.
#
#  This is necessary as it is not possible to execute kubectl from the workers. It
#  uses ansible ad-hoc commands.
#

function log_it {
    # check /var/log/user.log for the messages
    logger "${BASH_SOURCE[1]} ${1}"
}

hep_name=${1}
file_name_hep=${2}

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

ansible controller -i /tmp/ansible_adhoc_host -m ansible.builtin.copy -a "src=${file_name_hep} dest=${file_name_hep}"
if [ "$?" -ne 0 ]; then
    hostname=$(cat /etc/hostname)
    log_it "Failed to remote copy ${hostname}:${file_name_hep} to controller:${file_name_hep} "
    rm -f /tmp/ansible_adhoc_host
    exit 1
fi

ansible controller -i /tmp/ansible_adhoc_host -m ansible.builtin.shell -a "/usr/local/bin/calico_firewall_apply_hostendp.sh ${hep_name} ${file_name_hep}"
if [ "$?" -ne 0 ]; then
    log_it "Failed to remote apply hostendpoint ${hep_name} with file ${file_name_hep}"
    rm -f /tmp/ansible_adhoc_host
    exit 1
fi

rm -f /tmp/ansible_adhoc_host
exit 0

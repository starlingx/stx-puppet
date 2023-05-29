#!/bin/bash

################################################################################
# Copyright (c) 2023 Wind River Systems, Inc.
#
# SPDX-License-Identifier: Apache-2.0
#
################################################################################

#
#  The purpose of this script is to remotely remove the unused HostEndpoints,
#  from the worker nodes in the controller.
#
#  This is necessary as it is not possible to execute kubectl from the workers. It
#  uses ansible ad-hoc commands.
#

function log_it {
    # check /var/log/user.log for the messages
    logger "${BASH_SOURCE[1]} ${1}"
}

hostname=${1}
hep_active_file=${2}

if [ ! -f ${hep_active_file} ]; then
    log_it "file /tmp/hep_active.txt does not exist, cannot proceed";
    exit 1
fi

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

dest_file="${hep_active_file}.${hostname}"

ansible controller -i /tmp/ansible_adhoc_host -m ansible.builtin.copy -a "src=${hep_active_file} dest=${dest_file}"
if [ "$?" -ne 0 ]; then
    log_it "Failed to remote copy ${hostname}:${hep_active_file} to controller:${dest_file}"
    rm -f /tmp/ansible_adhoc_host
    exit 1
fi

ansible controller -i /tmp/ansible_adhoc_host -m ansible.builtin.shell -a "/usr/local/bin/remove_unused_calico_hostendpoints.sh ${hostname} ${dest_file}"
if [ "$?" -ne 0 ]; then
    log_it "Failed to remove unused  hostendpoint ${hep_name} with file ${dest_file}"
    rm -f /tmp/ansible_adhoc_host
    exit 1
fi

rm -f /tmp/ansible_adhoc_host
exit 0

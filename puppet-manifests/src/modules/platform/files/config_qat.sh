#!/bin/bash
#
# Copyright (c) 2024 Wind River Systems, Inc.
#
# SPDX-License-Identifier: Apache-2.0
#
#The purpose of this script is to create
#PF and VF configuration files in
#/etc directory. The configuration
#files will be used by the qat_service
#to up the respective PF and VF's
#

CONFIG_DIRECTORY="/etc"
CONFIG_FILE_PREFIX="4xxx*"
TEMP_LOCATION="/tmp"
CONFIG_SCRIPT_DIR="/etc/qat/script_files"
CONFIG_PF_SCRIPT="generate_conf_files.sh"
CONFIG_TEMPLATE_DIR="/etc/qat/conf_files"
CONFIG_PF_TEMPLATE="4xxx_template.conf"
CONFIG_VF_TEMPLATE="4xxxvf_dev0.conf.vm"
INTEL_VENDORID="8086"
QAT_4XXX_DEV_NO="4940"
QAT_401XX_DEV_NO="4942"
INSTALL="/usr/bin/install -c"
QAT_4XXX_NUM_VFS=16

# Logging info.
LOG_PATH=/var/log/
LOG_FILE=${LOG_PATH}/user.log
SCRIPT_NAME="/usr/share/puppet/modules/platform/files/config_qat.sh"

SYS_4XXX_PF_DEV=$(
    lspci -n \
    | grep -E -c "${INTEL_VENDORID}:(${QAT_4XXX_DEV_NO}|${QAT_401XX_DEV_NO})"
)
MAX_PF_INDEX=${SYS_4XXX_PF_DEV}-1

log_message() {
    mess="$1"
    time_stamp="$(date "+%Y-%m-%d %H:%M:%S.%3N")"
    echo "${time_stamp} <${SCRIPT_NAME}> : ${mess}" >> ${LOG_FILE}
}

# Function to delete all PF and VF configuration files
delete_config_files() {
    log_message "QAT config files cleaned, if any"
    rm -f ${CONFIG_DIRECTORY}/${CONFIG_FILE_PREFIX}
}

# Function to create PF configuration
create_pf_config() {
    local pf_seq="$1"
    local pf_config_file="/etc/4xxx_dev${pf_seq}.conf"

    # Check if the PF configuration file already exists
    if [ -f "${pf_config_file}" ]; then
        log_message "QAT PF config file ${pf_config_file} already exists."
        return
    fi

    find "${TEMP_LOCATION}" -type f -name \
        "${CONFIG_FILE_PREFIX}" -exec rm -f {} \;

    if [[ ${SYS_4XXX_PF_DEV} -gt 0 ]]; then
        ${CONFIG_SCRIPT_DIR}/${CONFIG_PF_SCRIPT} -n "${SYS_4XXX_PF_DEV}" \
            -f ${CONFIG_TEMPLATE_DIR}/${CONFIG_PF_TEMPLATE} -o ${TEMP_LOCATION}
    fi
    ${INSTALL} -D -m 640 ${TEMP_LOCATION}/4xxx_dev${pf_seq}.conf \
        "${pf_config_file}"
    log_message "QAT PF config file ${pf_config_file} created successfully."
}

# Function to create VF configuration
create_vf_config() {
    local pf_seq="$1"
    local vf_cnt="$2"
    start_index="${pf_seq}*${QAT_4XXX_NUM_VFS}"
    end_index=${start_index}+${vf_cnt}-1

    for (( vf_dev=${start_index};vf_dev<=${end_index};vf_dev++ )); do
        local vf_config_file="/etc/4xxxvf_dev${vf_dev}.conf"
        # Check if the VF configuration file already exists
        if [ -f "${vf_config_file}" ]; then
            log_message "QAT VF config file ${vf_config_file} already exists."
            continue
        fi

        ${INSTALL} -D -m 640 ${CONFIG_TEMPLATE_DIR}/${CONFIG_VF_TEMPLATE} \
            "${vf_config_file}"
        log_message "QAT VF config file ${vf_config_file} created \
        successfully."
    done
}

# Function to create configuration files
create_config_files() {
    local pf_seq="$1"
    local vf_cnt="$2"
    create_pf_config ${pf_seq}
    create_vf_config ${pf_seq} ${vf_cnt}
}

# Check if the script is running as the superuser
if [[ ${EUID} -ne 0 ]]; then
    log_message "This config_qat.sh must be run as root (sudo)."
    exit 1
fi

if [[ "$#" -eq 0 ]]; then
    if [ "${SYS_4XXX_PF_DEV}" -gt 0 ]; then
        for ((i = 0; i < ${SYS_4XXX_PF_DEV}; i++)); do
            create_config_files $i 16
        done
    else
        log_message "No QAT device found..."
    fi
fi

if [[ "$#" -gt "${SYS_4XXX_PF_DEV}" ]]; then
    log_message "Usage: $0 <Max ${SYS_4XXX_PF_DEV} \
        vf_count argument are supported> ..."
    exit 1
fi

pf_seq=0
for vf in "$@"; do
    vf_cnt="${vf}"
    if [[ ${vf_cnt} -gt 16 || ${vf_cnt} -eq 0 ]]; then
        pf_seq=${pf_seq}+1
        continue
    fi
    log_message "pf_seq: ${pf_seq}, vf_cnt: ${vf_cnt}"
    create_config_files ${pf_seq} ${vf_cnt}
    pf_seq=${pf_seq}+1
done

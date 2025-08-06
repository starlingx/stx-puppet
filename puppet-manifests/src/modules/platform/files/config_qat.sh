#!/bin/bash
#
# Copyright (c) 2024-2025 Wind River Systems, Inc.
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
CONFIG_4XXX_FILE_PREFIX="4xxx*"
CONFIG_420XX_FILE_PREFIX="420xx*"
TEMP_LOCATION="/tmp/qat_config_files"
CONFIG_SCRIPT_DIR="/etc/qat/script_files"
CONFIG_PF_SCRIPT="generate_conf_files.sh"
CONFIG_TEMPLATE_DIR="/etc/qat/conf_files"
CONFIG_TEMPLATE_TEMP_DIRECTORY="/tmp/qat_template_files"
CONFIG_4XXX_PF_TEMPLATE="4xxx_template.conf"
CONFIG_4XXX_VF_TEMPLATE="4xxxvf_dev0.conf.vm"
CONFIG_420XX_PF_TEMPLATE="420xx_template.conf"
CONFIG_420XX_VF_TEMPLATE="420xxvf_dev0.conf.vm"
INTEL_VENDORID="8086"
QAT_4XXX_DEV_NO="4940"
QAT_401XX_DEV_NO="4942"
QAT_420XX_DEV_NO="4946"
QAT_4XXX_DEV_STR="4xxx"
QAT_420XX_DEV_STR="420xx"

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

SYS_420XX_PF_DEV=$(
    lspci -n \
    | grep -E -c "${INTEL_VENDORID}:(${QAT_420XX_DEV_NO})"
)

CONFIG_FILE_PREFIX=${CONFIG_4XXX_FILE_PREFIX}
QAT_DEV_STR=${QAT_4XXX_DEV_STR}
CONFIG_PF_TEMPLATE=${CONFIG_4XXX_PF_TEMPLATE}
CONFIG_VF_TEMPLATE=${CONFIG_4XXX_VF_TEMPLATE}
SYS_NUM_PF_DEV=${SYS_4XXX_PF_DEV}

if [[ "${SYS_420XX_PF_DEV}" -gt 0 ]]; then
    CONFIG_FILE_PREFIX=${CONFIG_420XX_FILE_PREFIX}
    QAT_DEV_STR=${QAT_420XX_DEV_STR}
    CONFIG_PF_TEMPLATE=${CONFIG_420XX_PF_TEMPLATE}
    CONFIG_VF_TEMPLATE=${CONFIG_420XX_VF_TEMPLATE}
    SYS_NUM_PF_DEV=${SYS_420XX_PF_DEV}
fi

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
    local pf_config_file="/etc/${QAT_DEV_STR}_dev${pf_seq}.conf"

    # Check if the PF configuration file already exists
    if [ -f "${pf_config_file}" ]; then
        log_message "QAT PF config file ${pf_config_file} already exists."
        return
    fi

    find "${TEMP_LOCATION}" -type f -name \
        "${CONFIG_FILE_PREFIX}" -exec rm -f {} \;

    if [[ ${SYS_NUM_PF_DEV} -gt 0 ]]; then
        ${CONFIG_SCRIPT_DIR}/${CONFIG_PF_SCRIPT} -n "${SYS_NUM_PF_DEV}" \
            -f ${CONFIG_TEMPLATE_TEMP_DIRECTORY}/${CONFIG_PF_TEMPLATE} -o ${TEMP_LOCATION}
    fi
    ${INSTALL} -D -m 640 ${TEMP_LOCATION}/${QAT_DEV_STR}_dev${pf_seq}.conf \
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
        local vf_config_file="/etc/${QAT_DEV_STR}vf_dev${vf_dev}.conf"
        # Check if the VF configuration file already exists
        if [ -f "${vf_config_file}" ]; then
            log_message "QAT VF config file ${vf_config_file} already exists."
            continue
        fi

        ${INSTALL} -D -m 640 ${CONFIG_TEMPLATE_TEMP_DIRECTORY}/${CONFIG_VF_TEMPLATE} \
            "${vf_config_file}"
        log_message "QAT VF config file ${vf_config_file} created \
        successfully."
    done
}

# Function to modify pf vf config template files
modify_pf_vf_config_template_files() {
    FILES=("${CONFIG_TEMPLATE_TEMP_DIRECTORY}/${CONFIG_PF_TEMPLATE}" \
            "${CONFIG_TEMPLATE_TEMP_DIRECTORY}/${CONFIG_VF_TEMPLATE}")

    # Modify pf and vf template files
    for FILE in "${FILES[@]}"; do
        # Check if the file exists

        if [ ! -f "${FILE}" ]; then
            log_message "File does not exist: ${FILE}"
            exit 1
        fi
        # Replace asym;dc with sym;dc using sed
        sed -i 's/ServicesEnabled = asym;dc/ServicesEnabled = sym;dc/g' "${FILE}"
        # Check if the sed command was successful
        if [ $? -eq 0 ]; then
            log_message "File modified successfully: ${FILE}"
        else
            log_message "Failed to modify file: ${FILE}"
            exit 1
        fi
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

if [ -d "${TEMP_LOCATION}" ]; then
    rm -rf ${TEMP_LOCATION}
fi

if [ -d "${CONFIG_TEMPLATE_TEMP_DIRECTORY}" ]; then
    rm -rf ${CONFIG_TEMPLATE_TEMP_DIRECTORY}
fi

mkdir -p ${TEMP_LOCATION}
mkdir -p ${CONFIG_TEMPLATE_TEMP_DIRECTORY}

# Copy pf and vf config template files to temp location
cp ${CONFIG_TEMPLATE_DIR}/${CONFIG_PF_TEMPLATE} ${CONFIG_TEMPLATE_TEMP_DIRECTORY}
cp ${CONFIG_TEMPLATE_DIR}/${CONFIG_VF_TEMPLATE} ${CONFIG_TEMPLATE_TEMP_DIRECTORY}

# Modify pf vf config template files
modify_pf_vf_config_template_files

if [[ "$#" -eq 0 ]]; then
    if [ "${SYS_NUM_PF_DEV}" -gt 0 ]; then
        for ((i = 0; i < ${SYS_NUM_PF_DEV}; i++)); do
            create_config_files $i 16
        done
    else
        log_message "No QAT device found..."
    fi
fi

if [[ "$#" -gt "${SYS_NUM_PF_DEV}" ]]; then
    log_message "Usage: $0 <Max ${SYS_NUM_PF_DEV} \
        vf_count argument are supported> ..."
    rm -rf ${TEMP_LOCATION}
    rm -rf ${CONFIG_TEMPLATE_TEMP_DIRECTORY}
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

# Delete temp folders
rm -rf ${TEMP_LOCATION}
rm -rf ${CONFIG_TEMPLATE_TEMP_DIRECTORY}

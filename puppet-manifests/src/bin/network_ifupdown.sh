################################################################################
# Copyright (c) 2022 Wind River Systems, Inc.
#
# SPDX-License-Identifier: Apache-2.0
#
################################################################################

#
# This file purpose is to provide helper functions if the system is Debian based
# for the apply_network_config.sh script
#

export IFNAME_INCLUDE="ifcfg-*"
export PUPPET_FILE="/var/run/network-scripts.puppet/interfaces"
export ETC_DIR="/etc/network/interfaces.d/"

#
# Execute ifup script
# returns $(false) if argument $1 is invalid
#
function do_if_up {
    local cfg=$1
    local search_file=''
    local iface=''
    local if_name=''
    if [ -f ${cfg} ]; then
        search_file=${cfg}
    elif [ -f ${PUPPET_DIR}/${cfg} ]; then
        search_file=${PUPPET_DIR}/${cfg}
    elif [ -f ${PUPPET_DIR}/ifcfg-${cfg} ]; then
        search_file=${PUPPET_DIR}/ifcfg-${cfg}
    else
        log_it "do_if_up: cannot process argument ${cfg}"
        return $(false)
    fi
    iface=$( grep iface ${search_file} )
    if_name=$( echo "${iface}" | awk '{print $2}' )
    log_it "Bringing ${if_name} up"
    /sbin/ifup ${if_name}
}

#
# Execute ifdown script
# returns $(false) if argument $1 is invalid
#
function do_if_down {
    local cfg=$1
    local search_file=''
    local iface=''
    local if_name=''
    if [ -f ${cfg} ]; then
        search_file=${cfg}
    elif [ -f ${ETC_DIR}/${cfg} ]; then
        search_file=${ETC_DIR}/${cfg}
    elif [ -f ${ETC_DIR}/ifcfg-${cfg} ]; then
        search_file=${ETC_DIR}/ifcfg-${cfg}
    else
        log_it "do_if_down: cannot process argument ${cfg}"
        return $(false)
    fi
    iface=$( grep iface ${search_file} )
    if_name=$( echo "${iface}" | awk '{print $2}' )
    log_it "Bringing ${if_name} down"
    /sbin/ifdown ${if_name}
}

#
# Parse /var/run/network-scripts.puppet/interfaces
# into /var/run/network-scripts.puppet/ifcfg-[interface mane] files
#
function parse_interface_stanzas {
    local is_iface
    local is_auto
    local iface_name=''
    local last_generated=''
    local puppet_data

    do_rm ${PUPPET_DIR}/auto
    do_rm ${PUPPET_DIR}/ifcfg-\*

    is_iface=$(false)
    is_auto=$(false)
    last_generated=$( grep -E ".*Last generated.*" ${PUPPET_FILE}  )
    puppet_data=$(grep -v HEADER ${PUPPET_FILE})
    while read interfaceLine; do
        local startLine
        startLine=$( echo "${interfaceLine}" | awk '{print $1}' )
        if [[ "${startLine}" == "auto" ]] ; then
            is_auto=$(true)
            echo "${last_generated}" >> ${PUPPET_DIR}/auto
            echo "${interfaceLine}" >> ${PUPPET_DIR}/auto
        elif [[ "$startLine" == "iface" ]] ; then
            iface_name=$( echo "${interfaceLine}" | awk '{print $2}' )
            echo "${last_generated}" >> ${PUPPET_DIR}/ifcfg-${iface_name}
            echo "${interfaceLine}" >> ${PUPPET_DIR}/ifcfg-${iface_name}
        elif [[ "${startLine}" == "" ]] ; then
            is_iface=$(false)
            is_auto=$(false)
            iface_name=''
        else
            if [[ ${is_iface} == $(true) ]] ; then
                echo "${interfaceLine}" >> ${PUPPET_DIR}/ifcfg-${iface_name}
            elif [[ ${is_auto} == $(true) ]] ; then
                echo "${interfaceLine}" >> ${PUPPET_DIR}/auto
            fi
        fi
    done <<< ${puppet_data}
}

#
# returns $(true) if vlan device is configured in the kernel
#
function is_vlan_device_present_on_kernel {
    local cfg=$1
    local device_value=''
    local iface=''
    iface=$( grep iface ${cfg} )
    if [ -f ${cfg} ]; then
        device_value=$( echo "${iface}" | awk '{print $2}' )
        /usr/sbin/ip link show dev ${device_value} > /dev/null 2>&1
        if [[ $? -eq 0 ]]; then
            return $(true)
        fi
    fi
    return $(false)
}

#
# Compare files in ETC_DIR to check if all VLANs are created on the kernel
#
function verify_all_vlans_created {
    for cfg_path in $(find ${ETC_DIR} -name "${IFNAME_INCLUDE}"); do
        cfg=$(basename ${cfg_path})
        if is_vlan ${ETC_DIR}/${cfg}; then
            is_vlan_device_present_on_kernel ${cfg_path}
            if [ $? -ne 0 ] ; then
                log_it "${cfg} - not present on the kernel, bring up before proceeding"
                do_if_up ${cfg_path}
                is_vlan_device_present_on_kernel ${ETC_DIR}/${cfg}
                if [ $? -ne 0 ] ; then
                    log_it "${cfg} - failed to add VLAN interface on kernel"
                fi
            fi
        fi
    done
}

#
# returns $(true) if device is of VLAN type
#
function is_vlan {
    local cfg=$1
    local iface=''
    local if_name=''
    local regex=''
    if [ -f ${cfg} ]; then
        iface=$( grep iface ${cfg} )
        if_name=$( echo "${iface}" | awk '{print $2}' )
        regex="(vlan.*)|(.*\..*)"
        if [[ ${if_name} =~ ${regex} ]]; then
            return $(true)
        else
            if [[ $( grep -c vlan-raw-device ${cfg} ) == '1' ]]; then
                return $(true)
            fi
        fi
    fi
    return $(false)
}

#
# returns $(true) if interface is using DHCP
#
function is_dhcp {
    local cfg=$1
    if [ -f ${cfg} ]; then
        if [[ $( grep -c dhcp ${cfg} ) == '1' ]]; then
            return $(true)
        fi
    fi
    return $(false)
}

#
# returns $(true) if interface is the physical interface and not
#                 part of a bond
#
function is_ethernet {
    local cfg=$1
    if [ -f ${cfg} ]; then
        if ! is_vlan ${cfg}; then
            if ! is_slave ${cfg}; then
                return $(true)
            fi
        fi
    fi
    return $(false)
}

#
# returns $(true) if interface is the interface is part of a bond
#
function is_slave {
    local cfg=$1
    if [ -f ${cfg} ]; then
        if [[ $( grep -c bond-master ${cfg} ) == '1' ]]; then
            return $(true)
        fi
    fi
    return $(false)
}

#
# returns $(true) if ifcfg files have the same number of VFs
#
#
function is_eq_sriov_numvfs {
    local cfg_1=$1
    local cfg_2=$2
    local sriov_numvfs_1
    sriov_numvfs_1=$(grep -o 'echo *[1-9].*sriov_numvfs' ${cfg_1} | awk {'print $2'})
    local sriov_numvfs_2
    sriov_numvfs_2=$(grep -o 'echo *[1-9].*sriov_numvfs' ${cfg_2} | awk {'print $2'})

    sriov_numvfs_1=${sriov_numvfs_1:-0}
    sriov_numvfs_2=${sriov_numvfs_2:-0}

    if [[ "${sriov_numvfs_1}" != "${sriov_numvfs_2}" ]]; then
        log_it "${cfg_1} and ${cfg_2} differ on attribute sriov_numvfs [${sriov_numvfs_1}:${sriov_numvfs_2}]"
        return $(false)
    fi

    return $(true)
}

#
# returns $(true) if configurations are equal, $(false) otherwise
#
function is_eq_ifcfg {
    local puppet_cfg=$1
    local etc_cfg=$2
    local pup_iface
    local pup_if_name
    local pup_family
    local pup_method
    local etc_iface
    local etc_if_name
    local etc_family
    local etc_method
    local puppet_data
    local etc_data

    if [ ! -f $etc_cfg ]; then
        return $(false)
    fi

    pup_iface=$( grep iface ${puppet_cfg} )
    pup_if_name=$( echo "${pup_iface}" | awk '{print $2}' )
    pup_family=$( echo "${pup_iface}" | awk '{print $3}' )
    pup_method=$( echo "${pup_iface}" | awk '{print $4}' )

    etc_iface=$( grep iface ${etc_cfg} )
    etc_if_name=$( echo ${etc_iface} | awk '{print $2}' )
    etc_family=$( echo ${etc_iface} | awk '{print $3}' )
    etc_method=$( echo ${etc_iface} | awk '{print $4}' )

    if [[ ${pup_family} != "${etc_family}" || ${pup_method} != "${etc_method}" ]]; then
        return $(false)
    fi

    # search added or modified parameters from puppet to etc
    puppet_data=$(grep -E -v '(HEADER)|(iface)' ${puppet_cfg})
    etc_data=$(grep -E -v '(HEADER)|(iface)' ${etc_cfg})
    while read puppetLine; do
        local pup_param
        pup_param=$( echo "${puppetLine}" | awk '{print $1}' )

        if [[ $( grep -c "${pup_param}" ${etc_cfg} ) == '0' ]]; then
            log_it "parameter ${pup_param} added by puppet in ${pup_if_name}"
            return $(false)
        fi

        while read etcLine; do
            local etc_param
            etc_param=$( echo "${etcLine}" | awk '{print $1}' )
            if [[ ${pup_param} == "${etc_param}" ]]; then
                if [[ ${puppetLine} != "${etcLine}" ]]; then
                    log_it "parameter ${pup_param} modified by puppet in ${pup_if_name}"
                    return $(false)
                fi
            fi
        done <<< ${etc_data}
    done <<< ${puppet_data}

    # search removed parameters from puppet to etc
    while read etcLine; do
        local etc_param
        etc_param=$( echo ${etcLine} | awk '{print $1}' )
        if [[ $( grep -c "${etc_param}" ${puppet_cfg} ) == '0' ]]; then
            log_it "parameter ${etc_param} removed from puppet in ${pup_if_name}"
            return $(false)
        fi
    done <<< ${etc_data}

    is_eq_sriov_numvfs ${puppet_cfg} ${etc_cfg}
    return $?
}

#
# returns $(true) if cfg file has the given interface_name as a PHYSDEV
#
function has_physdev {
    local vlan=$1
    local device=$2
    local phydev=''
    local iface
    local if_name
    local regex_dot_vlan
    local regex_vlan

    iface=$( grep iface ${vlan} )
    if_name=$( echo "${iface}" | awk '{print $2}' )
    regex_dot_vlan=".*\..*"
    regex_vlan="vlan.*"

    if [[ ${if_name} =~ ${regex_dot_vlan} ]]; then
        phydev=$( echo "${if_name}" | awk --field-separator=. '{print $1}' )
    elif [[ ${if_name} =~ ${regex_vlan} ]]; then
        vlan_raw_device=$(grep vlan-raw-device ${vlan})
        phydev=$( echo "${vlan_raw_device}" | awk '{print $2}' )
    fi

    if [[ ${device} == "${phydev}" ]]; then
        if [[ -f ${PUPPET_DIR}/ifcfg-${device} ]]; then
            return $(true)
        fi
    fi

    return $(false)
}

#
# returns $(true) if interface is of the requested type (dhcp, vlan, ethernet or slave)
#
function iftype_filter {
    local iftype=$1
    local cfg=$2
    is_${iftype} ${cfg}
    if [ $? -eq 0 ] ; then
        return $(true)
    fi
    return $(false)
}


#
# Process static routes
#
function update_routes {
    log_it "to be implemented: update_routes"
}


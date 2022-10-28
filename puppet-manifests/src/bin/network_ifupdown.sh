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
export PUPPET_ROUTES_FILE="/var/run/network-scripts.puppet/routes"
export PUPPET_ROUTES6_FILE="/var/run/network-scripts.puppet/routes6"
export ETC_ROUTES_FILE="/etc/network/routes"
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
    /sbin/ifup ${if_name} || log_it "Failed bringing ${if_name} up"
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
    /sbin/ifdown ${if_name} || log_it "Failed bringing ${if_name} down"
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

    # sysinv generates the stanza "allow-[master] [slave]" as part of options due
    # to the lack of support in puppet-network module. To not break ifup parsing
    # we move the stanza to the end of the file.
    for cfg_path in $(find ${PUPPET_DIR} -name "${IFNAME_INCLUDE}"); do
        local allow_bond
        local iface_file
        iface_file=$(basename ${cfg_path})
        iface_name=${iface_file#ifcfg-}
        allow_bond=$( grep -E "allow-.*${iface_name}" ${cfg_path} )
        if [ -n "${allow_bond}" ]; then
            awk -v search="${allow_bond}" \
                '$0==search{lastline=$0;next}{print $0}END{print lastline}' \
                ${cfg_path} > ${cfg_path}.tmp
            mv -f ${cfg_path}.tmp ${cfg_path}
        fi
    done

    # if inet6, search for the first labeled interface (label=':1') and remove the label
    # from instanza, since all labeled inet6 interface adresses are created with
    # preferred_lifetime=0 and that marks the address as deprecated. So the first labeled
    # interface must apply the address over the interface itself
    # e.g. stanza vlan100:1 needs to be vlan100
    for cfg_path in $(find ${PUPPET_DIR} -name "${IFNAME_INCLUDE}" | sort); do
        local iface_file
        iface_file=$(basename ${cfg_path})
        iface_name=${iface_file#ifcfg-}
        base_iface_name=${iface_name%:*}
        is_inet6_label=$( grep -E "iface ${base_iface_name}:[1-9] inet6" ${cfg_path} )
        if [ -n "${is_inet6_label}" ]; then
            if [[ -e ${cfg_path%:*} ]]; then
                is_inet6_manual=$( grep -E "iface ${base_iface_name} inet6 manual" ${cfg_path%:*} )
                if [ -n "${is_inet6_manual}" ]; then
                    # Collect the base interface operations
                    puppet_data=$(grep -v HEADER ${cfg_path%:*})
                    while read interfaceLine; do
                        local startLine
                        local operations=("pre-up" "up" "post-up" "pre-down" "down" "post-down")
                        startLine=$( echo "${interfaceLine}" | awk '{print $1}' )
                        if printf '%s\0' "${operations[@]}" | grep -Fxqz -- "${startLine}"; then
                            echo "${interfaceLine}" >> ${cfg_path}
                        fi
                    done <<< ${puppet_data}
                    # remove the label from stanza
                    local label
                    label=${iface_name#*:}
                    sed -i "s/:${label}//" ${cfg_path}
                    # use the merged stanza
                    mv ${cfg_path} ${cfg_path%:*}
                    sed -i "s/# HEADER/# HEADER: for inet6 handles ${iface_name}\n# HEADER/" ${cfg_path%:*}
                fi
            fi
        fi
    done
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
        # do not process labeled interfaces
        if [[ $cfg != *":"* ]]; then
            log_it "verify_all_vlans_created process $cfg"
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

    if [ ! -f ${etc_cfg} ]; then
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

# If in Debian, return interface name, with or without label
function get_search_ifname {
    cfg=$1
    base_cfg=${cfg}
    echo ${base_cfg}
}

# Note: any change on this function need to be mirrored on
# the patch for ifupdown-extra in the integ repo
function get_prefix_length {
    netmask=$1
    if [[ ${netmask} =~ .*:.* ]]; then
        # IPv6
        awk -F: '{
            split($0, octets)
                for (i in octets) {
                    decval = strtonum("0x"octets[i])
                    mask += 16 - log(2**16 - decval)/log(2);
                }
            print "/" mask
        }' <<< ${netmask}
    elif [[ ${netmask} =~ .*\..* ]]; then
        # IPv4
        awk -F. '{
            split($0, octets)
            for (i in octets) {
                mask += 8 - log(2**8 - octets[i])/log(2);
            }
            print "/" mask
        }' <<< ${netmask}
    elif [[ ${netmask} =~ ^[0-9]+$ ]]; then
        echo "/${netmask}"
    fi
}

# if route is default, remove prefix_len
function get_linux_network {
    network=$1
    prefix_len=$2
    local linux_network
    linux_network="${network}${prefix_len}"
    if [ "${network}" == "default" ]; then
        linux_network="${network}"
    fi
    echo "${linux_network}"
}

function route_add {
    local routeLine="$*"
    local route
    local netmask
    local nexthop
    local ifname
    local prefix
    local metric
    local linux_network

    route=$( echo "${routeLine}" | awk '{print $1}' )
    netmask=$( echo "${routeLine}" | awk '{print $2}' )
    nexthop=$( echo "${routeLine}" | awk '{print $3}' )
    ifname=$( echo "${routeLine}" | awk '{print $4}' )
    metric=$( echo "${routeLine}" | awk '{print $6}' )
    prefix=$(get_prefix_length ${netmask})
    linux_network=$(get_linux_network ${route} ${prefix})

    if [ "$linux_network" != "" ] && [ "$nexthop" != "" ] && [ "$ifname" != "" ] && [ "$metric" != "" ]; then
        log_it "Adding route: ${linux_network} via ${nexthop} dev ${ifname} netmask ${netmask} metric ${metric}"
        /usr/sbin/ip route add ${linux_network} via ${nexthop} dev ${ifname} metric ${metric}
        if [ $? -ne 0 ] ; then
            log_it "Failed adding route: ${linux_network} via ${nexthop} dev ${ifname} netmask ${netmask} metric ${metric}"
        fi
    else
        log_it "Route add with invalid parameter: ${linux_network} via ${nexthop} dev ${ifname} netmask ${netmask} metric ${metric}."
    fi
}

function route_del {
    local routeLine="$*"
    local route
    local netmask
    local nexthop
    local ifname

    route=$( echo "${routeLine}" | awk '{print $1}' )
    netmask=$( echo "${routeLine}" | awk '{print $2}' )
    nexthop=$( echo "${routeLine}" | awk '{print $3}' )
    ifname=$( echo "${routeLine}" | awk '{print $4}' )
    prefix=$(get_prefix_length ${netmask})
    linux_network=$(get_linux_network ${route} ${prefix})

    if [ "$linux_network" != "" ] && [ "$nexthop" != "" ] && [ "$ifname" != "" ]; then
        log_it "Removing route: ${linux_network} via ${nexthop} dev ${ifname} netmask ${netmask}"
        /usr/sbin/ip route del ${linux_network} via ${nexthop} dev ${ifname}
        if [ $? -ne 0 ] ; then
            log_it "Failed removing route: ${linux_network} via ${nexthop} dev ${ifname} netmask ${netmask}"
        fi
    else
        log_it "Route del with invalid parameter: ${linux_network} via ${nexthop} dev ${ifname} netmask ${netmask}."
    fi
}

#
# Process static routes
#
function update_routes {
    local etc_data
    local puppet_data

    if [ -f ${PUPPET_ROUTES6_FILE} ]; then
        log_it "add IPv6 routes generated in network.pp"
        if [ -f ${PUPPET_ROUTES_FILE} ]; then
            puppet_data=$(grep -v HEADER ${PUPPET_ROUTES6_FILE})
            while read route6Line; do
                route_exists=$( grep -E "${route6Line}" ${PUPPET_ROUTES_FILE} )
                if [ "${route_exists}" == "" ]; then
                    echo "${route6Line}" >> ${PUPPET_ROUTES_FILE}
                fi
            done <<< ${puppet_data}
        else
            cat ${PUPPET_ROUTES6_FILE} >> ${PUPPET_ROUTES_FILE}
        fi
    fi

    if [ ! -f ${PUPPET_ROUTES_FILE} ] ; then
        log_it "no puppet routes to process, remove existing ones and return"
        if [ -f ${ETC_ROUTES_FILE} ] ; then
            log_it "process routes in ${ETC_ROUTES_FILE}"
            etc_data=$(grep -v -E '(HEADER)|(^#)' ${ETC_ROUTES_FILE})
            while read etcRouteLine; do
                route_del "${etcRouteLine}"
                sed -i "s/${etcRouteLine}//g" ${ETC_ROUTES_FILE}
            done <<< ${etc_data}
        fi
        return $(true)
    fi

    if [ -f ${ETC_ROUTES_FILE} ]; then

        # There is an existing route file.  Check if there are changes.
        diff -I ".*Last generated.*" -q ${PUPPET_ROUTES_FILE} \
                                        ${ETC_ROUTES_FILE} >/dev/null 2>&1
        if [ $? -ne 0 ] ; then
            log_it "diff found between ${PUPPET_ROUTES_FILE} and ${ETC_ROUTES_FILE}"

            # process deleted routes
            etc_data=$(grep -v -E '(HEADER)|(^#)' ${ETC_ROUTES_FILE})
            while read etcRouteLine; do
                grepCmd="grep -q '${etcRouteLine}' ${PUPPET_ROUTES_FILE} > /dev/null"
                eval ${grepCmd}
                if [ $? -ne 0 ] ; then
                    route_del "${etcRouteLine}"
                fi
            done <<< ${etc_data}

            # process added routes
            puppet_data=$(grep -v -E '(HEADER)|(^#)' ${PUPPET_ROUTES_FILE})
            while read puppetRouteLine; do
                grepCmd="grep -q '${puppetRouteLine}' ${ETC_ROUTES_FILE} > /dev/null"
                eval ${grepCmd}
                if [ $? -ne 0 ] ; then
                    route_add "${puppetRouteLine}"
                fi
            done <<< ${puppet_data}

            do_rm ${ETC_ROUTES_FILE}
            do_cp ${PUPPET_ROUTES_FILE} ${ETC_ROUTES_FILE}
        fi

    else
        # process added routes
        puppet_data=$(grep -v -E '(HEADER)|(^#)' ${PUPPET_ROUTES_FILE})
        while read puppetRouteLine; do
            route_add "${puppetRouteLine}"
        done <<< ${puppet_data}

        do_cp ${PUPPET_ROUTES_FILE} ${ETC_ROUTES_FILE}
    fi
}

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
export ETC_DIR="/etc/network/interfaces.d"
export PUPPET_DIR="/var/run/network-scripts.puppet"
export CFG_PREFIX="ifcfg-"

#
# Sets interface to UP state
#
function do_if_up {
    local if_name=$1

    log_it notice "Bringing ${if_name} up"

    /sbin/ifup ${if_name} > /dev/null 2>&1

    if [ $? -ne 0 ]; then
        log_it err "Failed bringing ${if_name} up"
    fi
}

#
# Remove all IP adresses from the interface if it exists in the kernel
#
function reset_ips {
    local iface=$1
    local response
    if [ -d /sys/class/net/${iface} ]; then
        response=$(/usr/sbin/ip addr flush dev ${iface} 2>&1)
        if [ $? -ne 0 ]; then
            log_it err "Command 'ip addr flush' failed for interface ${iface}: '${result}'"
        fi
    fi
}

#
# Sets interface to DOWN state
#
function do_if_down {
    local if_name=$1
    local st_file="/run/network/ifstate.${if_name}"
    local response

    log_it notice "Bringing ${if_name} down"

    if [ -f ${st_file} ] && [[ $(< ${st_file}) == "${if_name}" ]]; then
        /sbin/ifdown ${if_name} > /dev/null 2>&1
        if [ $? -ne 0 ]; then
            log_it err "Command 'ifdown' failed for interface ${if_name}"
        fi
    fi

    if [ -d /sys/class/net/${iface} ]; then
        response=$(/usr/sbin/ip link set down dev ${if_name} 2>&1)
        if [ $? -ne 0 ]; then
            log_it err "Command 'ip link set down' failed for interface ${if_name}: '${response}'"
        fi
    fi

    reset_ips ${if_name}
}

#
# Parse /var/run/network-scripts.puppet/interfaces
# into /var/run/network-scripts.puppet/ifcfg-[interface name] files
#
function parse_interface_stanzas {
    local is_iface
    local is_auto
    local iface_name=''
    local last_generated=''
    local puppet_data

    log_it info "remove ${PUPPET_DIR}/auto"
    rm -f ${PUPPET_DIR}/auto
    log_it info "remove ${PUPPET_DIR}/ifcfg-*"
    rm -f ${PUPPET_DIR}/ifcfg-*

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

    # in Debian the package ifenslave can also configure the slave interfaces
    # but it requires that ifup execute the bonded interface first when executing
    # with --all, the section below edits the auto file to put the interfaces in
    # the order "auto lo [bond interfaces] [ethernet interfaces] [vlan interfaces]"
    bonded_if=()
    vlan_if=()
    ethernet_if=()
    auto_arr=($(grep -v HEADER ${PUPPET_DIR}/auto))
    for auto_if in ${auto_arr[@]:1}; do
        if [[ ${auto_if} == "auto" ]]; then
            continue
        fi
        bond_slaves=$(grep -c bond-slaves ${PUPPET_DIR}/ifcfg-${auto_if})
        vlan_raw_device=$(grep -c vlan-raw-device ${PUPPET_DIR}/ifcfg-${auto_if})
        if [ "${bond_slaves}" == "1" ]; then
            bonded_if+=( ${auto_if} )
        elif [ "${vlan_raw_device}" == "1" ]; then
            vlan_if+=( ${auto_if} )
        elif [[ "${bond_slaves}" == "0" && "${vlan_raw_device}" == "0" ]]; then
            ethernet_if+=( ${auto_if} )
        fi
    done
    new_auto=( "auto" )
    for intf in ${bonded_if[@]}; do
        new_auto+=("${intf}");
    done
    for intf in ${ethernet_if[@]}; do
        new_auto+=("${intf}");
    done
    for intf in ${vlan_if[@]}; do
        new_auto+=("${intf}");
    done
    echo "${new_auto[@]}" > ${PUPPET_DIR}/auto

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
# returns $(true) if interface device is configured in the kernel
#
function is_interface_present_on_kernel {
    /usr/sbin/ip link show dev ${1} > /dev/null 2>&1
}

#
# Compare files in ETC_DIR to check if all VLANs are created on the kernel
# only search over platform interfaces, from the ${ETC_DIR}/auto file
#
function verify_all_vlans_created {

    local auto_etc=( )
    if [ -f ${ETC_DIR}/auto ]; then
        auto_etc=( $(grep -v HEADER ${ETC_DIR}/auto) )
    fi

    for cfg_path in $(find ${ETC_DIR} -name "${IFNAME_INCLUDE}"); do
        cfg=$(basename ${cfg_path})
        iface_name="${cfg#ifcfg-}"
        # only process interfaces that are in the generated auto file
        if grep -q "${iface_name}" <<< "${auto_etc[@]}"; then
            # do not process labeled interfaces
            if [[ $cfg != *":"* ]]; then
                if is_vlan ${ETC_DIR}/${cfg}; then
                    log_it info "verify_all_vlans_created process $cfg"
                    is_vlan_device_present_on_kernel ${cfg_path}
                    if [ $? -ne 0 ] ; then
                        log_it notice "${cfg} - not present on the kernel, bring up before proceeding"
                        do_if_up ${cfg:6}
                        is_vlan_device_present_on_kernel ${ETC_DIR}/${cfg}
                        if [ $? -ne 0 ] ; then
                            log_it warning "${cfg} - failed to add VLAN interface on kernel"
                        fi
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
    local regex2=''
    if [ -f ${cfg} ]; then
        iface=$( grep iface ${cfg} )
        if_name=$( echo "${iface}" | awk '{print $2}' )
        regex="(vlan[0-9]+)|(.*\..*)"
        regex2="pre-up .*ip link add link.*type vlan"
        if [[ ${if_name} =~ ${regex} ]]; then
            return $(true)
        elif [[ $( grep -c -E "${regex2}" ${cfg} ) == '1' ]]; then
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
# gets the master interface of a bond-slave
# returns $(true) if there is one or $(false) if not
#
function get_master {
    local cfg=$1
    local result
    if [ -f ${cfg} ]; then
        result=$( grep bond-master ${cfg} )
        if [ $? -eq 0 ]; then
            echo "${result}" | awk '{print $2}'
            return $(true)
        fi
    fi
    return $(false)
}

#
# returns $(true) if interface is the interface is part of a bond
#
function is_slave {
    master=$( get_master $1 )
}

#
# gets the slave interfaces of a bonding
# returns $(true) if it has slaves or $(false) if not
#
function get_slaves {
    local cfg=$1
    local slaves
    if [ -f ${cfg} ]; then
        slaves=($( grep bond-slaves ${cfg} ))
        if [ $? -eq 0 ]; then
            echo "${slaves[@]:1}"
            return $(true)
        fi
    fi
    return $(false)
}

#
# returns $(true) if interface is a bonding
#
function is_bonding {
    get_slaves $1 >/dev/null 2>&1
}

#
# returns $(true) if ifcfg files have the same number of VFs
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
        log_it notice "${cfg_1} and ${cfg_2} differ on attribute sriov_numvfs [${sriov_numvfs_1}:${sriov_numvfs_2}]"
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
            log_it notice "parameter ${pup_param} added by puppet in ${pup_if_name}"
            return $(false)
        fi

        while read etcLine; do
            local etc_param
            etc_param=$( echo "${etcLine}" | awk '{print $1}' )
            if [[ ${pup_param} == "${etc_param}" ]]; then
                if [[ ${puppetLine} != "${etcLine}" ]]; then
                    log_it notice "parameter ${pup_param} modified by puppet in ${pup_if_name}"
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
            log_it notice "parameter ${etc_param} removed from puppet in ${pup_if_name}"
            return $(false)
        fi
    done <<< ${etc_data}

    is_eq_sriov_numvfs ${puppet_cfg} ${etc_cfg}
    return $?
}

#
# gets physical device for a vlan
#
function get_physdev {
    local vlan=$1
    local phydev=''
    local iface
    local if_name
    local regex_dot_vlan
    local regex_vlan

    iface=$( grep iface ${vlan} )
    if_name=$( echo "${iface}" | awk '{print $2}' )
    regex_dot_vlan=".*\..*"
    regex_vlan="vlan[0-9]+"
    regex_preup="pre-up .*ip link add link.*type vlan"

    if [[ ${if_name} =~ ${regex_dot_vlan} ]]; then
        echo "${if_name}" | awk --field-separator=. '{print $1}'
        return $(true)
    elif [[ ${if_name} =~ ${regex_vlan} ]]; then
        vlan_raw_device=$(grep vlan-raw-device ${vlan})
        echo "${vlan_raw_device}" | awk '{print $2}'
        return $(true)
    else
        preup=$( grep -E "${regex_preup}" ${vlan} )
        if [ $? -eq 0 ] ; then
            echo "${preup}" | sed -En 's/.*ip link add link (.+) name.*/\1/p'
            return $(true)
        else
            return $(false)
        fi
    fi
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
    local output
    local prot=""

    route=$( echo "${routeLine}" | awk '{print $1}' )
    netmask=$( echo "${routeLine}" | awk '{print $2}' )
    nexthop=$( echo "${routeLine}" | awk '{print $3}' )
    ifname=$( echo "${routeLine}" | awk '{print $4}' )
    metric=$( echo "${routeLine}" | awk '{print $6}' )
    prefix=$(get_prefix_length ${netmask})
    linux_network=$(get_linux_network ${route} ${prefix})

    if [[ "${nexthop}" =~ ":" ]]; then
        prot="-6"
    fi

    if [ "$linux_network" != "" ] && [ "$nexthop" != "" ] && [ "$ifname" != "" ] && [ "$metric" != "" ]; then
        log_it notice "Adding route: ${linux_network} via ${nexthop} dev ${ifname} netmask ${netmask} metric ${metric}"
        output=$( /usr/sbin/ip ${prot} route show ${linux_network} via ${nexthop} dev ${ifname} metric ${metric} 2>&1 )
        if [ $? -eq 0 ] && [[ " ${output} " =~ " ${linux_network} " ]] ; then
            log_it notice "Route already exists, skipping"
        else
            output=$( /usr/sbin/ip route add ${linux_network} via ${nexthop} dev ${ifname} metric ${metric} 2>&1 )
            if [ $? -ne 0 ] ; then
                log_it err "Failed adding route: ${linux_network} via ${nexthop} dev ${ifname} netmask ${netmask} metric ${metric}, output: '${output}'"
            fi
        fi
    else
        log_it err "Route add with invalid parameter: ${linux_network} via ${nexthop} dev ${ifname} netmask ${netmask} metric ${metric}."
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
        log_it notice "Removing route: ${linux_network} via ${nexthop} dev ${ifname} netmask ${netmask}"
        /usr/sbin/ip route del ${linux_network} via ${nexthop} dev ${ifname}
        if [ $? -ne 0 ] ; then
            log_it err "Failed removing route: ${linux_network} via ${nexthop} dev ${ifname} netmask ${netmask}"
        fi
    else
        log_it err "Route del with invalid parameter: ${linux_network} via ${nexthop} dev ${ifname} netmask ${netmask}."
    fi
}

#
# Process static routes
#
function update_routes {
    local etc_data
    local puppet_data
    local ifaces=($@)

    if [ ${#ifaces[@]} -ne 0 ]; then
        log_it info "Updating routes, modified interfaces: '${ifaces[*]}'"
    else
        log_it info "Updating routes, no modified interfaces"
    fi

    if [ -f ${PUPPET_ROUTES6_FILE} ]; then
        log_it info "add IPv6 routes generated in network.pp"
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
        log_it info "no puppet routes to process, remove existing ones and return"
        if [ -f ${ETC_ROUTES_FILE} ] ; then
            log_it info "process routes in ${ETC_ROUTES_FILE}"
            etc_data=$(grep -v -E '^\s*#' ${ETC_ROUTES_FILE})
            while read etcRouteLine; do
                if [ -n "${etcRouteLine}" ]; then
                    route_del "${etcRouteLine}"
                    sed -i "s/${etcRouteLine}//g" ${ETC_ROUTES_FILE}
                fi
            done <<< ${etc_data}
        fi
        return $(true)
    fi

    if [ -f ${ETC_ROUTES_FILE} ]; then

        # There is an existing route file.  Check if there are changes.
        diff -I ".*Last generated.*" -q ${PUPPET_ROUTES_FILE} \
                                        ${ETC_ROUTES_FILE} >/dev/null 2>&1
        if [ $? -ne 0 ] ; then
            log_it notice "Differences found between ${PUPPET_ROUTES_FILE} and ${ETC_ROUTES_FILE}"

            # process deleted routes
            etc_data=$(grep -v -E '^\s*#' ${ETC_ROUTES_FILE})
            while read etcRouteLine; do
                grepCmd="grep -q '${etcRouteLine}' ${PUPPET_ROUTES_FILE} > /dev/null"
                eval ${grepCmd}
                if [ $? -ne 0 ] ; then
                    route_del "${etcRouteLine}"
                fi
            done <<< ${etc_data}

            # process added routes
            puppet_data=$(grep -v -E '^\s*#' ${PUPPET_ROUTES_FILE})
            while read puppetRouteLine; do
                grepCmd="grep -q '${puppetRouteLine}' ${ETC_ROUTES_FILE} > /dev/null"
                eval ${grepCmd}
                if [ $? -ne 0 ] ; then
                    route_add "${puppetRouteLine}"
                elif [ ${#ifaces[@]} -ne 0 ] ; then
                    ifname=$( echo "${puppetRouteLine}" | awk '{print $4}' )
                    if [[ " ${ifaces[@]} " =~ " ${ifname} " ]]; then
                        log_it notice "Route is already present in ${ETC_ROUTES_FILE}, but is associated with an updated interface, adding"
                        route_add "${puppetRouteLine}"
                    fi
                fi
            done <<< ${puppet_data}

            do_rm ${ETC_ROUTES_FILE}
            do_cp ${PUPPET_ROUTES_FILE} ${ETC_ROUTES_FILE}
        elif [ ${#ifaces[@]} -ne 0 ] ; then
            log_it notice "No difference found between ${PUPPET_ROUTES_FILE} and ${ETC_ROUTES_FILE}"
            puppet_data=$(grep -v -E '^\s*#' ${PUPPET_ROUTES_FILE})
            while read puppetRouteLine; do
                ifname=$( echo "${puppetRouteLine}" | awk '{print $4}' )
                if [[ " ${ifaces[@]} " =~ " ${ifname} " ]]; then
                    log_it notice "Route is associated with an updated interface, adding"
                    route_add "${puppetRouteLine}"
                fi
            done <<< ${puppet_data}
        fi

    else
        log_it notice "File /etc/network/routes missing, adding routes from puppet"
        # process added routes
        puppet_data=$(grep -v -E '^\s*#' ${PUPPET_ROUTES_FILE})
        while read puppetRouteLine; do
            route_add "${puppetRouteLine}"
        done <<< ${puppet_data}

        do_cp ${PUPPET_ROUTES_FILE} ${ETC_ROUTES_FILE}
    fi
}

#
# Return $(true) if interface is missing or in DOWN state
#
function is_interface_missing_or_down {
    local iface=$1
    local state

    if [ ! -f /sys/class/net/${iface}/operstate ]; then
        return $(true)
    fi

    state=$(</sys/class/net/${iface}/operstate)

    if [[ "${state}" == "down" ]]; then
        return $(true)
    fi

    return $(false)
}

#
# Add an IP address to an interface if it's not yet present
#
function add_ip_to_iface {
    local iface=$1
    local new_addr=$2
    local response
    local result

    log_it notice "Adding IP ${new_addr} to interface ${iface}"

    response=$( /usr/sbin/ip -br addr show dev "${iface}" 2>&1 )

    if [ $? -eq 0 ]; then
        local addresses=($response)
        for addr in "${addresses[@]:2}"; do
            if [ "${addr}" == "${new_addr}" ]; then
                log_it notice "Interface ${iface} already has address ${new_addr}, skipping"
                return $(true)
            fi
        done

        result=$( /usr/sbin/ip address add ${new_addr} dev ${iface} 2>&1 )
        if [ $? -ne 0 ]; then
            log_it err "Failed to add IP address to interface ${iface}: '${result}'"
            return $(false)
        fi

        return $(true)
    else
        log_it err "Failed to get IP address list from ${iface}: '${response}'"
        return $(false)
    fi
}

#
# Add a default route to an interface if it's not yet present
#
function add_default_route {
    local iface=$1
    local nexthop=$2
    local prot=""
    local routes
    local result

    log_it notice "Adding default route via ${nexthop} to interface ${iface}"

    if [[ "${nexthop}" =~ ":" ]]; then
        prot="-6"
    fi

    routes=$( /usr/sbin/ip ${prot} route show dev ${iface} | grep default )

    if [ $? -eq 0 ]; then
        while IFS= read -r line; do
            if [[ "${line} " =~ " ${nexthop} " ]]; then
                log_it notice "Default route via ${nexthop} for ${iface} already exists, skipping"
                return $(true)
            fi
        done <<< "$routes"
    fi

    result=$( /usr/sbin/ip route add default via ${nexthop} dev ${iface} 2>&1 )

    if [ $? -ne 0 ]; then
        log_it err "Failed to add default route to interface ${iface}: '${result}'"
        return $(false)
    fi

    return $(true)
}

#
# Check if interface has its IP address and default route configured, add them if needed
#
function ensure_iface_configured {
    local iface=$1
    local cfgfile=${ETC_DIR}/ifcfg-${iface}
    local addr_line
    local netmask_line
    local address
    local netmask
    local prefix
    local gateway_line
    local gateway

    log_it notice "Ensuring that interface ${iface} is properly configured"

    addr_line=$( grep "^address" ${cfgfile} )
    if [ $? -eq 0 ]; then
        netmask_line=$( grep netmask ${cfgfile} )

        if [ $? -eq 0 ]; then
            address=$( echo "${addr_line}" | awk '{print $2}' )
            netmask=$( echo "${netmask_line}" | awk '{print $2}' )
            prefix=$( get_prefix_length ${netmask} )
            add_ip_to_iface "${iface}" "${address}${prefix}"
        else
            log_it err "Unable to get netmask of ${iface} interface"
        fi
    fi

    gateway_line=$( grep gateway ${cfgfile} )

    if [ $? -eq 0 ]; then
        gateway=$( echo "${gateway_line}" | awk '{print $2}' )
        add_default_route ${iface} ${gateway}
    fi
}

#
# Check if interface is part of a bonding, return all related interfaces
#
function get_bonding_compound {
    local iface=$1
    local master
    local slaves

    master=$( get_master ${PUPPET_DIR}/${CFG_PREFIX}${iface} )
    if [ $? -eq 0 ]; then
        slaves=$( get_slaves ${PUPPET_DIR}/${CFG_PREFIX}${master} )
        echo ${master} ${slaves}
        return $(true)
    fi

    slaves=$( get_slaves ${PUPPET_DIR}/${CFG_PREFIX}${iface} )
    if [ $? -eq 0 ]; then
        echo ${iface} ${slaves}
        return $(true)
    fi

    return $(false)
}

#
# Check if interface is loopback or a VLAN on top of the loopback
#
function is_loopback {
    [[ "$1" =~ ^lo(:[0-9]+)?$ ]]
}

#
# Log network info
#
function log_network_info {
    local contents
    contents=$(
        {
            echo
            echo "************ Links/addresses ************"
            /usr/sbin/ip addr show
            echo "************ IPv4 routes ****************"
            /usr/sbin/ip route show
            echo "************ IPv6 routes ****************"
            /usr/sbin/ip -6 route show
            echo "*****************************************"
        }
    )
    logger -p info -S 64KiB $(basename "${BASH_SOURCE[1]}") "Network info:${contents}"
}

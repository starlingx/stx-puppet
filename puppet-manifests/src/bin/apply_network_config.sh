#!/bin/bash

################################################################################
# Copyright (c) 2016-2024 Wind River Systems, Inc.
#
# SPDX-License-Identifier: Apache-2.0
#
################################################################################

# WARNING: This file is OBSOLETE, use apply_network_config.py instead

#
#  Purpose of this script is to copy the puppet-built ifcfg-* network config
#  files from the PUPPET_DIR to the ETC_DIR. Only files that are detected as
#  different are copied.
#
#  Then for each network puppet config files that are different from ETC_DIR
#  version of the same config file,  perform a network restart on the related iface.
#
#  Based on the system distro (CentOS or Debian) helper files are provided for
#  each one to do the ifcfg-* file parsing
#
#  Please note:  function is_eq_ifcfg() is used to determine if
#                cfg files are different
#

ACQUIRE_LOCK=1
RELEASE_LOCK=0

declare ROUTES_ONLY="no"

function usage {
    cat <<EOF >&2
$0 [ --routes ]

Options:
  --routes : Update routes config only
EOF
}

OPTS=$(getopt -o h -l help,routes -- "$@")
if [ $? -ne 0 ]; then
    usage
    exit 1
fi

eval set -- "${OPTS}"

while true; do
    case $1 in
        --)
            # End of getopt arguments
            shift
            break
            ;;
        --routes)
            ROUTES_ONLY="yes"
            shift
            ;;
        -h | --help )
            usage
            exit 1
            ;;
        *)
            usage
            exit 1
            ;;
    esac
done

function log_it {
    logger -p "$1" $(basename "${BASH_SOURCE[1]}"): "${@:2}"
}

function do_rm {
    local theFile=$1
    log_it notice "Removing ${theFile}"
    /bin/rm "${theFile}"
}

function do_cp {
    local srcFile=$1
    local dstFile=$2
    log_it notice "copying network cfg ${srcFile} to ${dstFile}"
    cp  ${srcFile} ${dstFile}
}

# Return items in list1 that are not in list2
function array_diff {
    list1=${!1}
    list2=${!2}

    result=()
    l2=" ${list2[*]} "
    for item in ${list1[@]}; do
        if [[ ! $l2 =~ " ${item} " ]] ; then
            result+=(${item})
        fi
    done

    echo  ${result[@]}
}

# Synchronize with sysinv-agent audit (ifup/down to query link speed).
function sysinv_agent_lock {
    case $1 in
    ${ACQUIRE_LOCK})
        log_it notice "Acquiring lock to synchronize with sysinv-agent audit"
        local lock_file="/var/run/apply_network_config.lock"
        # Lock file should be the same as defined in sysinv agent code
        local lock_timeout=5
        local max=15
        local n=1
        LOCK_FD=0
        exec {LOCK_FD}>${lock_file}
        while [[ ${n} -le ${max} ]]; do

            flock -w ${lock_timeout} ${LOCK_FD} && break
            log_it warning "Failed to get lock(${LOCK_FD}) after ${lock_timeout} seconds (${n}/${max}), will retry"
            sleep 1
            n=$((${n}+1))
        done
        if [[ ${n} -gt ${max} ]]; then
            log_it err "Failed to acquire lock(${LOCK_FD}) even after ${max} retries"
            exit 1
        fi
        ;;
    ${RELEASE_LOCK})
        log_it notice "Releasing lock"
        [[ ${LOCK_FD} -gt 0 ]] && flock -u ${LOCK_FD}
        ;;
    esac
}

# Returns $(true) if interface is base, $(false) if label
function is_base_iface {
    if [[ "$1" =~ ":" ]]; then
        return $(false)
    fi
    return $(true)
}

# Returns 0 if address is IPv6, 1 otherwise
function is_ipv6 {
    local addr=$1
    # simple check for ':'
    if [ "${addr/:/}" != "${addr}" ]; then
        # addr is ipv6
        return 0
    fi
    return 1
}

# Gets base interface name for a label
function get_base_iface {
    base_cfg=${1/:*/}
    echo ${base_cfg}
}

# Gets interface type
function get_type {
    if ! is_base_iface $1; then
        echo label
    elif is_vlan $1; then
        echo vlan
    elif is_slave $1; then
        echo slave
    elif is_bonding $1; then
        echo bonding
    else
        echo eth
    fi
}

# Updates interfaces according to puppet generated files
function update_interfaces {
    is_upgrade=$(($1))
    changed=()
    removed=()
    vlans=()
    labels=()

    down_label=()
    down_vlan=()
    down_slave=()
    down_bonding=()
    down_eth=()

    up_label=()
    up_vlan=()
    up_slave=()
    up_bonding=()
    up_eth=()

    auto_etc=( $(grep -v HEADER ${ETC_DIR}/auto) )
    auto_puppet=( $(grep -v HEADER ${PUPPET_DIR}/auto) )

    # build a list of interfaces that were removed and also add them to the down list
    for auto_if in ${auto_etc[@]:1}; do
        if [[ ! " ${auto_puppet[@]:1} " =~ " ${auto_if} " ]]; then
            iftype=$( get_type ${ETC_DIR}/${CFG_PREFIX}${auto_if} )
            eval down_${iftype}+=\(\$auto_if\)
            removed+=($auto_if)
        fi
    done

    for auto_if in ${auto_puppet[@]:1}; do
        cfg="${CFG_PREFIX}${auto_if}"
        iftype=$( get_type ${PUPPET_DIR}/${cfg} )
        include=1

        if [ "${iftype}" == "label" ]; then
            labels+=("${auto_if}")
        elif [ "${iftype}" == "vlan" ]; then
            vlans+=("${auto_if}")
        fi

        diff -I ".*Last generated.*" -q ${PUPPET_DIR}/${cfg} ${ETC_DIR}/${cfg} >/dev/null 2>&1

        if [ $? -ne 0 ] ; then
            # puppet file needs to be copied to network dir because diff detected
            changed+=(${cfg})

            if is_dhcp ${PUPPET_DIR}/${cfg} || is_dhcp ${ETC_DIR}/${cfg}; then
                # if dhcp type iface, then too many possible attr's to compare against, so just add
                # the interface to the up/down list because we know (from above) cfg file is changed
                log_it notice "DHCP detected for ${auto_if}, adding to up/down list"
                include=0
            else
                # not in dhcp situation so check if any significant
                # cfg attributes have changed to warrant an iface restart
                is_eq_ifcfg ${PUPPET_DIR}/${cfg} ${ETC_DIR}/${cfg}
                if [ $? -ne 0 ] ; then
                    log_it notice "${cfg} changed"
                    include=0
                fi
            fi
        fi

        # if is vlan or bonding and is not present in the kernel, add to list
        if [ ${include} -ne 0 ] && [[ " vlan bonding " =~ " ${iftype} " ]]; then
            if ! is_interface_present_on_kernel ${auto_if}; then
                log_it notice "Interface ${auto_if} of type ${iftype} is not present in the" \
                    "kernel, adding to up/down list"
                include=0
            fi
        fi

        if [ ${include} -eq 0 ]; then
            # add interface to up and down lists
            eval up_${iftype}+=\(\$auto_if\)
            eval down_${iftype}+=\(\$auto_if\)
        fi
    done

    log_it info "Labels: ${labels[*]}"
    log_it info "VLANs: ${vlans[*]}"

    # include master interfaces for all slaves that are being modified
    for iface in ${up_slave[@]}; do
        master=$( get_master ${PUPPET_DIR}/${CFG_PREFIX}${iface} )
        if [[ ! " ${up_bonding[@]} " =~ " ${master} " ]]; then
            log_it notice "Adding bonding interface ${master} to up/down list since" \
                "slave ${iface} is changing"
            up_bonding+=($master)
            down_bonding+=($master)
        fi
    done

    # include slave interfaces for all bondings that are being modified
    for iface in ${up_bonding[@]}; do
        slaves=($( get_slaves ${PUPPET_DIR}/${CFG_PREFIX}${iface} ))
        for slave in ${slaves[@]}; do
            if [[ ! " ${up_slave[@]} " =~ " ${slave} " ]]; then
                log_it notice "Adding slave interface ${slave} to up/down list since" \
                    "bonding ${iface} is changing"
                up_slave+=($slave)
                down_slave+=($slave)
            fi
        done
    done

    # include vlan interfaces for all eth and bondings that are being modified
    for iface in ${vlans[@]}; do
        physdev=$( get_physdev ${PUPPET_DIR}/${CFG_PREFIX}${iface} )
        if [[ " ${up_eth[@]} ${up_bonding[@]} " =~ " ${physdev} " ]]; then
            if [[ ! " ${up_vlan[@]} " =~ " ${iface} " ]]; then
                log_it notice "Adding ${iface} to up/down list since physdev ${physdev} is changing"
                up_vlan+=($iface)
                down_vlan+=($iface)
            fi
        fi
    done

    # include labels for all interfaces that are being modified
    for iface in ${labels[@]}; do
        base_iface=$( get_base_iface $iface )
        if [[ " ${up_eth[@]} ${up_bonding[@]} ${up_vlan[@]} " =~ " ${base_iface} " ]]; then
            if [[ ! " ${up_label[@]} " =~ " ${iface} " ]]; then
                log_it notice "Adding ${iface} to up/down list since base ${base_iface} is changing"
                up_label+=($iface)
                down_label+=($iface)
            fi
        fi
    done

    if [ ${is_upgrade} -ne 0 ]; then
        # synchronize with sysinv-agent audit
        sysinv_agent_lock ${ACQUIRE_LOCK}
    fi

    # set interfaces down
    if [ ${is_upgrade} -ne 0 ]; then
        for iftype in label vlan bonding slave eth; do
            eval list=\${down_${iftype}[@]}
            for iface in ${list[@]}; do
                do_if_down ${iface}
            done
        done
    fi

    # remove configs that are in ${ETC_DIR} but not in ${PUPPET_DIR}
    for iface in ${removed[@]}; do
        do_rm ${ETC_DIR}/${CFG_PREFIX}${iface}
    done

    # copy the puppet changed interfaces to ${ETC_DIR}
    for cfg in ${changed[@]}; do
        do_cp ${PUPPET_DIR}/${cfg} ${ETC_DIR}/${cfg}
    done

    # copy the start on boot interfaces to ${ETC_DIR}
    if [ -f ${PUPPET_DIR}/auto ]; then
        diff -I ".*Last generated.*" -q ${PUPPET_DIR}/auto ${ETC_DIR}/auto >/dev/null 2>&1
        if [ $? -ne 0 ] ; then
            do_cp ${PUPPET_DIR}/auto ${ETC_DIR}/auto
        fi
    fi

    # now ifup changed ifaces by dealing with labels and vlan interfaces last so that their
    # dependencies are met before they are configured. Bonding slaves are not included because ifup
    # deals with them automatically.
    for iftype in eth bonding vlan label; do
        eval list=\${up_${iftype}[@]}
        for iface in ${list[@]}; do
            if [ ${is_upgrade} -eq 0 ]; then
                if is_loopback ${iface}; then
                    log_it info "Interface '${iface}' is loopback, skipping"
                elif is_interface_missing_or_down ${iface}; then
                    reset_ips ${iface}
                    do_if_up ${iface}
                else
                    ensure_iface_configured ${iface}
                fi
            else
                do_if_up ${iface}
            fi
        done
    done

    if [ ${is_upgrade} -ne 0 ]; then
        # unlock: synchronize with sysinv-agent audit
        sysinv_agent_lock ${RELEASE_LOCK}
    fi

    # build a list of interfaces that were changed and need to have their routes recreated
    changed_ifaces=("${up_eth[@]} ${up_bonding[@]} ${up_vlan[@]}")
    for iface in ${up_label[@]}; do
        base_iface=$( get_base_iface $iface )
        if [[ ! " ${changed_ifaces[@]} " =~ " ${base_iface} " ]]; then
            changed_ifaces+=("${base_iface}")
        fi
    done

    echo "${changed_ifaces[@]}"
}

if [ ${ROUTES_ONLY} = "yes" ]; then
    if [ -d /etc/sysconfig/network-scripts/ ] ; then

        log_it info "process CentOS route config"

        # shellcheck disable=SC1091
        source /usr/local/bin/network_sysconfig.sh

    elif [ -d /etc/network/interfaces.d/ ] ; then

        log_it info "process Debian route config"

        # shellcheck disable=SC1091
        source /usr/local/bin/network_ifupdown.sh

    else
        log_it err "Not using sysconfig or ifupdown, cannot go further! Aborting..."
        exit 1
    fi

    update_routes
else

    if [ ! -d /var/run/network-scripts.puppet/ ] ; then
        # No puppet files? Nothing to do!
        log_it err "No puppet files? Nothing to do! Aborting..."
        exit 1
    fi

    if [ -d /etc/sysconfig/network-scripts/ ] ; then

        log_it info "process CentOS network config"

        # shellcheck disable=SC1091
        source /usr/local/bin/network_sysconfig.sh

        update_routes
        # capture echo in a dummy variable so it doesn't go to stdout
        ifaces=$(update_interfaces)

    elif [ -d /etc/network/interfaces.d/ ] ; then

        log_it info "process Debian network config"

        # shellcheck disable=SC1091
        source /usr/local/bin/network_ifupdown.sh
        if [ ! -f ${PUPPET_FILE} ] ; then
            log_it err "${PUPPET_FILE} not found"
            exit 1
        fi

        log_network_info

        parse_interface_stanzas

        auto_intf=$(grep -v HEADER ${PUPPET_DIR}/auto)
        log_it info "auto interfaces='${auto_intf}'"
        if [ "${auto_intf}" == "auto lo" ]; then
            # if an empty configuration is provided by puppet we should ignore it, otherwise
            # it will remove the present network configuration and put nothing back in its place
            log_it info "generated ${PUPPET_FILE} with empty configuration:'${auto_intf}', exiting"
            exit 0
        fi

        if [ -f /etc/network/interfaces.d/ifcfg-pxeboot ]; then
            iface_name=$( cat /etc/network/interfaces.d/ifcfg-pxeboot | grep iface | awk '{print $2}' )
            log_it "turn off pxeboot install config for ${iface_name}, will be turned on later"
            do_if_down ${iface_name}
            log_it "remove ifcfg-pxeboot, left from pxeboot install phase"
            rm /etc/network/interfaces.d/ifcfg-pxeboot
        fi

        upgr_bootstrap=1

        if [ -f /var/run/.network_upgrade_bootstrap ]; then
            upgr_bootstrap=0
            log_it info "Upgrade bootstrap is in execution"
        fi

        ifaces=$(update_interfaces ${upgr_bootstrap})
        update_routes "${ifaces}"

        # In case of subcloud enrollment
        if [ -f /var/run/.enroll-init-reconfigure ]; then
            # OAM reconfiguration should not overwrite cloud-init's intended default route.
            # Enrollment depends on cloud-init configured IP/route on interface/vlan, which
            # could be different than OAM interface/vlan. We don't want oam-modify to set
            # the default route via original OAM interface/vlan.
            # Force back default route via new interface/vlan given by cloud-init.
            cfg=/etc/network/interfaces.d/50-cloud-init
            if [ -f ${cfg} ]; then
                log_it info "Enrollment: Updating default OAM route"
                iface_line=$( cat ${cfg} |grep ^iface | grep -v 'iface lo' )
                if_name=$( echo "${iface_line}" | awk '{print $2}' )
                gateway_line=$( cat ${cfg} |grep gateway)
                oam_gateway_ip=$( echo "${gateway_line}" | awk '{print $2}' )

                log_it info "OAM gateway IP:${oam_gateway_ip}, Cloud-init if-name:${if_name}"
                ip_command='ip'
                if is_ipv6 "${oam_gateway_ip}"; then
                    ip_command='ip -6'
                fi

                default_ip_route_before=$(${ip_command} route |grep default)
                log_it info "default route before modification: ${default_ip_route_before}"
                ip_route_results=$(${ip_command} route replace default via ${oam_gateway_ip} dev ${if_name} 2>&1)
                log_it info "ip route add/replace errors: ${ip_route_results}"
                default_ip_route_after=$(${ip_command} route |grep default)
                log_it info "default route after modification: ${default_ip_route_after}"
            fi
        fi

        log_network_info

    else
        log_it err "Not using sysconfig or ifupdown, cannot advance!  Aborting..."
        exit 1
    fi

fi

log_it info "Finished"

#!/bin/bash

################################################################################
# Copyright (c) 2016-2022 Wind River Systems, Inc.
#
# SPDX-License-Identifier: Apache-2.0
#
################################################################################

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
    logger "${BASH_SOURCE[1]} ${1}"
}


function do_rm {
    local theFile=$1
    log_it "Removing ${theFile}"
    /bin/rm  ${theFile}
}

function do_cp {
    local srcFile=$1
    local dstFile=$2
    log_it "copying network cfg ${srcFile} to ${dstFile}"
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
        log_it "Acquiring lock to synchronize with sysinv-agent audit"
        local lock_file="/var/run/apply_network_config.lock"
        # Lock file should be the same as defined in sysinv agent code
        local lock_timeout=5
        local max=15
        local n=1
        LOCK_FD=0
        exec {LOCK_FD}>${lock_file}
        while [[ ${n} -le ${max} ]]; do

            flock -w ${lock_timeout} ${LOCK_FD} && break
            log_it "Failed to get lock(${LOCK_FD}) after ${lock_timeout} seconds (${n}/${max}), will retry"
            sleep 1
            n=$((${n}+1))
        done
        if [[ ${n} -gt ${max} ]]; then
            log_it "Failed to acquire lock(${LOCK_FD}) even after ${max} retries"
            exit 1
        fi
        ;;
    ${RELEASE_LOCK})
        log_it "Releasing lock"
        [[ ${LOCK_FD} -gt 0 ]] && flock -u ${LOCK_FD}
        ;;
    esac
}

function update_interfaces {
    is_upgrade=$(($1))
    upDown=()
    changed=()
    vlans=()

    # in DOR scenarios systemd might timeout to configure some interfaces since DHCP server
    # might not be ready yet on the controller. If this happens the next interfaces in
    # ${ETC_DIR}/ will not be configured, as the timeout will interrupt
    # the network service.
    verify_all_vlans_created

    # the auto file contains the correct ordered execution list
    auto_puppet=( $(grep -v HEADER ${PUPPET_DIR}/auto) )
    for auto_if in ${auto_puppet[@]:1}; do
        cfg="${CFG_PREFIX}${auto_if}"

        if is_vlan ${ETC_DIR}/${cfg}; then
            vlans+=(${auto_if})
        fi

        diff -I ".*Last generated.*" -q ${PUPPET_DIR}/${cfg} ${ETC_DIR}/${cfg} >/dev/null 2>&1

        if [ $? -ne 0 ] ; then
            # puppet file needs to be copied to network dir because diff detected
            changed+=(${cfg})

            to_add=""
            if is_dhcp ${PUPPET_DIR}/${cfg} || is_dhcp ${ETC_DIR}/${cfg}  ; then
                # if dhcp type iface, then too many possible attr's to compare against, so just add
                # the interface to the upDown list because we know (from above) cfg file is changed
                log_it "DHCP detected for ${auto_if}, adding to upDown list"
                to_add=${auto_if}
            else
                # not in dhcp situation so check if any significant
                # cfg attributes have changed to warrant an iface restart
                is_eq_ifcfg ${PUPPET_DIR}/${cfg} ${ETC_DIR}/${cfg}
                if [ $? -ne 0 ] ; then
                    log_it "${cfg} changed"
                    # Check if the base interface is already on the list for
                    # restart. If not, add it to the list.
                    # If in CentOS, remove alias portion in the interface name if any.
                    #               The alias interface does not need to be restarted.
                    # If in Debian, use the interface name, with or without label
                    base_cfg=$(get_search_ifname ${auto_if})
                    found=0
                    for chk in ${upDown[@]}; do
                        if [ "${base_cfg}" = "${chk}" ]; then
                            found=1
                            break
                        fi
                    done

                    if [ ${found} -eq 0 ]; then
                        to_add=${base_cfg}
                    fi
                fi
            fi

            # skip if already in list
            if [ -n "${to_add}" ] && [[ " ${upDown[@]} " =~ " ${to_add} " ]]; then
                to_add=""
            fi

            if [ -n "${to_add}" ]; then
                # check if is part of a bonding
                if_list=($( get_bonding_compound ${to_add} ))
                if [ $? -ne 0 ]; then
                    if_list=(${to_add})
                else
                    log_it "Bonding compound detected: '${if_list[*]}'"
                fi

                for iface in ${if_list[@]}; do
                    if [[ ! " ${upDown[@]} " =~ " ${iface} " ]]; then
                        log_it "Adding ${iface} to upDown list"
                        upDown+=("${iface}")
                    fi
                done
            fi
        fi
    done

    current=()
    if [ -f ${ETC_DIR}/auto ]; then
        auto_etc=( $(grep -v HEADER ${ETC_DIR}/auto) )
        current=( ${auto_etc[@]:1} )
    fi

    active=( ${auto_puppet[@]} )

    if [ ${is_upgrade} -ne 0 ]; then
        # synchronize with sysinv-agent audit
        sysinv_agent_lock ${ACQUIRE_LOCK}
    fi

    remove=$(array_diff current[@] active[@])
    for iface in ${remove[@]}; do
        if [ ${is_upgrade} -ne 0 ]; then
            # Bring down interface before we execute network restart, interfaces
            # that do not have an ifcfg are not managed by init script
            do_if_down ${iface}
        fi
        do_rm ${ETC_DIR}/${CFG_PREFIX}${iface}
    done

    # If a lower ethernet interface is being changed, the upper vlan interface(s) will lose
    # configuration such as (IPv6) addresses and (IPv4, IPv6) default routes.  If the vlan
    # interface is not already in the up/down list, then explicitly add it.
    for iface in ${upDown[@]}; do
        for vlan in ${vlans[@]}; do
            if has_physdev ${PUPPET_DIR}/${CFG_PREFIX}${vlan} ${iface}; then
                if [[ ! " ${upDown[@]} " =~ " ${vlan} " ]]; then
                    log_it "Adding ${vlan} to up/down list since physdev ${iface} is changing"
                    upDown+=($vlan)
                fi
            fi
        done
    done

    if [ ${is_upgrade} -ne 0 ]; then
        # now down the changed ifaces by dealing with vlan interfaces first so that
        # they are brought down gracefully (i.e., without taking their dependencies
        # away unexpectedly).
        for iftype in vlan ethernet slave; do
            for iface in ${upDown[@]}; do
                ifcfg=${PUPPET_DIR}/${CFG_PREFIX}${iface}
                if iftype_filter ${iftype} ${ifcfg}; then
                    do_if_down ${iface}
                fi
            done
        done
    fi

    # now copy the puppet changed interfaces to ${ETC_DIR}
    for cfg in ${changed[@]}; do
        do_cp ${PUPPET_DIR}/${cfg} ${ETC_DIR}/${cfg}
    done
    # copy the start on boot interfaces (for Debian) to ETC_DIR
    if [ -f ${PUPPET_DIR}/auto ]; then
        diff -I ".*Last generated.*" -q ${PUPPET_DIR}/auto ${ETC_DIR}/auto >/dev/null 2>&1
        if [ $? -ne 0 ] ; then
            do_cp ${PUPPET_DIR}/auto ${ETC_DIR}/auto
        fi
    fi

    # now ifup changed ifaces by dealing with vlan interfaces last so that their
    # dependencies are met before they are configured. Bonding slaves are not
    # included because ifup deals with them automatically.
    for iftype in ethernet vlan; do
        for iface in ${upDown[@]}; do
            ifcfg=${PUPPET_DIR}/${CFG_PREFIX}${iface}
            if iftype_filter ${iftype} ${ifcfg}; then
                if [ ${is_upgrade} -eq 0 ]; then
                    if is_loopback ${iface}; then
                        log_it "Interface '${iface}' is loopback, skipping"
                    elif is_interface_missing_or_down ${iface}; then
                        reset_ips ${iface}
                        do_if_up ${iface}
                    else
                        ensure_iface_configured ${iface}
                    fi
                else
                    do_if_up ${iface}
                fi
            fi
        done
    done

    if [ ${is_upgrade} -ne 0 ]; then
        # unlock: synchronize with sysinv-agent audit
        sysinv_agent_lock ${RELEASE_LOCK}
    fi

    echo "${upDown[@]}"
}

if [ ${ROUTES_ONLY} = "yes" ]; then
    if [ -d /etc/sysconfig/network-scripts/ ] ; then

        log_it "process CentOS route config"

        # shellcheck disable=SC1091
        source /usr/local/bin/network_sysconfig.sh

    elif [ -d /etc/network/interfaces.d/ ] ; then

        log_it "process Debian route config"

        # shellcheck disable=SC1091
        source /usr/local/bin/network_ifupdown.sh

    else
        log_it "Not using sysconfig or ifupdown, cannot go further! Aborting..."
        exit 1
    fi

    update_routes
else

    if [ ! -d /var/run/network-scripts.puppet/ ] ; then
        # No puppet files? Nothing to do!
        log_it "No puppet files? Nothing to do!  Aborting..."
        exit 1
    fi

    if [ -d /etc/sysconfig/network-scripts/ ] ; then

        log_it "process CentOS network config"

        # shellcheck disable=SC1091
        source /usr/local/bin/network_sysconfig.sh

        update_routes
        # capture echo in a dummy variable so it doesn't go to stdout
        ifaces=$(update_interfaces)

    elif [ -d /etc/network/interfaces.d/ ] ; then

        log_it "process Debian network config"

        # shellcheck disable=SC1091
        source /usr/local/bin/network_ifupdown.sh
        if [ ! -f ${PUPPET_FILE} ] ; then
            log_it "${PUPPET_FILE} not found"
            exit 1
        fi

        log_network_info

        parse_interface_stanzas

        [ -f /var/run/.network_upgrade_bootstrap ]
        upgr_bootstrap=$?

        if [ ${upgr_bootstrap} -eq 0 ]; then
            log_it "Upgrade bootstrap is in execution"
        fi

        ifaces=$(update_interfaces ${upgr_bootstrap})
        update_routes "${ifaces}"

        log_network_info

    else
        log_it "Not using sysconfig or ifupdown, cannot advance!  Aborting..."
        exit 1
    fi

fi

log_it "Finished"

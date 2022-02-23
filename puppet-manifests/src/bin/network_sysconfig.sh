################################################################################
# Copyright (c) 2022 Wind River Systems, Inc.
#
# SPDX-License-Identifier: Apache-2.0
#
################################################################################

#
# This file purpose is to provide helper functions if the system is CentOS based
# for the apply_network_config.sh script
#

export IFNAME_INCLUDE="ifcfg-*"
export RTNAME_INCLUDE="route-*"
export ETC_DIR="/etc/sysconfig/network-scripts/"

function do_if_up {
    local iface=$1
    log_it "Bringing ${iface} up"
    /sbin/ifup ${iface}
}

function do_if_down {
    local iface=$1
    log_it "Bringing ${iface} down"
    /sbin/ifdown ${iface}
}

#
# returns $(true) if vlan device is configured in the kernel
#
function is_vlan_device_present_on_kernel {
    local cfg=$1
    local device_value=''
    if [ -f ${cfg} ]; then
        device_value=$(cat ${cfg} | grep DEVICE= | awk -F "=" {'print $2'})
        /usr/sbin/ip link show dev ${device_value} > /dev/null 2>&1
        if [[ $? -eq 0 ]]; then
            return $(true)
        fi
    fi
    return $(false)
}


function normalized_cfg_attr_value {
    local cfg=$1
    local attr_name=$2
    local attr_value
    attr_value=$(cat ${cfg} | grep ${attr_name}= | awk -F "=" {'print $2'})


    #
    # Special case BONDING_OPTS attribute.
    #
    # The BONDING_OPTS attribute contains '=' characters, so is not correctly
    # parsed by splitting on '=' as done above.  This results in changes to
    # BONDING_OPTS not causing the interface to be restarted, so the old
    # BONDING_OPTS still be used.  Because this is only checking for changes,
    # rather than actually using the returned value, we can return the whole
    # line.
    #
    if [[ "${attr_name}" == "BONDING_OPTS" ]]; then
        echo "$(cat ${cfg} | grep ${attr_name}=)"
        return $(true)
    fi

    if [[ "${attr_name}" != "BOOTPROTO" ]]; then
        echo "${attr_value}"
        return $(true)
    fi
    #
    # Special case BOOTPROTO attribute.
    #
    # The BOOTPROTO attribute is not populated consistently by various aspects
    # of the system.  Different values are used to indicate a manually
    # configured interfaces (i.e., one that does not expect to have an IP
    # address) and so to avoid reconfiguring an interface that has different
    # values with the same meaning we normalize them here before making any
    # decisions.
    #
    # From a user perspective the values "manual", "none", and "" all have the
    # same meaning - an interface without an IP address while "dhcp" and
    # "static" are distinct values with a separate meaning.  In practice
    # however, the only value that matters from a ifup/ifdown script point of
    # view is "dhcp".  All other values are ignored.
    #
    # In our system we set BOOTPROTO to "static" to indicate that IP address
    # attributes exist and to "manual"/"none" to indicate that no IP address
    # attributes exist.  These are not needed by ifup/ifdown as it looks for
    # the "IPADDR" attribute whenever BOOTPROTO is set to anything other than
    # "dhcp".
    #
    if [[ "${attr_value}" == "none" ]]; then
        attr_value="none"
    fi
    if [[ "${attr_value}" == "manual" ]]; then
        attr_value="none"
    fi
    if [[ "${attr_value}" == "" ]]; then
        attr_value="none"
    fi
    echo "${attr_value}"
    return $(true)
}

#
# returns $(true) if cfg file ( $1 ) has property propName ( $2 ) with a value of propValue ( $3 )
#
function cfg_has_property_with_value {
    local cfg=$1
    local propname=$2
    local propvalue=$3
    if [ -f ${cfg} ]; then
        if [[ "$(normalized_cfg_attr_value ${cfg} ${propname})" == "${propvalue}" ]]; then
            return $(true)
        fi
    fi
    return $(false)
}

#
# returns $(true) if cfg file is configured as a slave
#
function is_slave {
    cfg_has_property_with_value $1 "SLAVE" "yes"
    return $?
}

#
# returns $(true) if cfg file is configured for DHCP
#
function is_dhcp {
    cfg_has_property_with_value $1 "BOOTPROTO" "dhcp"
}

#
# returns $(true) if cfg file is configured as a VLAN interface
#
function is_vlan {
    cfg_has_property_with_value $1 "VLAN" "yes"
    return $?
}

#
# returns $(true) if cfg file has the given interface_name as a PHYSDEV
#
function has_physdev {
    cfg_has_property_with_value $1 "PHYSDEV" $2
}

#
# returns $(true) if cfg file is configured as an ethernet interface.  For the
# purposes of this script "ethernet" is considered as any interface that is not
# a vlan or a slave.  This includes both regular ethernet interfaces and bonded
# interfaces.
#
function is_ethernet {
    if ! is_vlan $1; then
        if ! is_slave $1; then
            return $(true)
        fi
    fi
    return $(false)
}

#
# returns $(true) if cfg file represents an interface of the specified type.
#
function iftype_filter {
    local iftype=$1

    return $(is_${iftype} $2)
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
# returns $(true) if ifcfg files are equal
#
# Warning:  Only compares against cfg file attributes:
#            BOOTPROTO DEVICE IPADDR NETMASK GATEWAY MTU BONDING_OPTS SRIOV_NUMVFS
#            IPV6ADDR IPV6_DEFAULTGW
#
function is_eq_ifcfg {
    local cfg_1=$1
    local cfg_2=$2

    for attr in BOOTPROTO DEVICE IPADDR NETMASK GATEWAY MTU BONDING_OPTS IPV6ADDR IPV6_DEFAULTGW; do
        local attr_value1
        attr_value1=$(normalized_cfg_attr_value ${cfg_1} ${attr})
        local attr_value2
        attr_value2=$(normalized_cfg_attr_value ${cfg_2} ${attr})
        if [[ "${attr_value1}" != "${attr_value2}"  ]]; then
            log_it "${cfg_1} and ${cfg_2} differ on attribute ${attr}"
            return $(false)
        fi
    done

    is_eq_sriov_numvfs $1 $2
    return $?
}

function verify_all_vlans_created {
    for cfg_path in $(find ${ETC_DIR} -name "${IFNAME_INCLUDE}"); do
        cfg=$(basename ${cfg_path})
        if is_vlan ${ETC_DIR}/${cfg}; then
            is_vlan_device_present_on_kernel ${cfg_path}
            if [ $? -ne 0 ] ; then
                log_it "${cfg} - not present on the kernel, bring up before proceeding"
                do_if_up ${cfg_path}
                is_vlan_device_present_on_kernel ${cfg_path}
                if [ $? -ne 0 ] ; then
                    log_it "${cfg_path} - failed to add VLAN interface on kernel"
                fi

            fi
        fi
    done
}

function update_routes {
    # First thing to do is deal with the case of there being no routes left on an interface.
    # In this case, there will be no route-<if> in the puppet directory.
    # We'll just create an empty one so that the below will loop will work in all cases.

    if [ ! -d ${PUPPET_DIR} ] ; then
        mkdir -p ${PUPPET_DIR}
    fi

    for rt_path in $(find ${ETC_DIR} -name "${RTNAME_INCLUDE}"); do
        rt=$(basename ${rt_path})

        if [ ! -e ${PUPPET_DIR}/${rt} ]; then
            touch ${PUPPET_DIR}/${rt}
        fi
    done

    for rt_path in $(find ${PUPPET_DIR} -name "${RTNAME_INCLUDE}"); do
        rt=$(basename ${rt_path})
        iface_rt=${rt#route-}

        if [ -e ${ETC_DIR}/${rt} ]; then
            # There is an existing route file.  Check if there are changes.
            diff -I ".*Last generated.*" -q ${PUPPET_DIR}/${rt} \
                                            ${ETC_DIR}/${rt} >/dev/null 2>&1

            if [ $? -ne 0 ] ; then
                # We may need to perform some manual route deletes
                # Look for route lines that are present in the current netscripts route file,
                # but not in the new puppet version.  Need to manually delete these routes.
                grep -v HEADER ${ETC_DIR}/${rt} | while read oldRouteLine
                do
                    grepCmd="grep -q '${oldRouteLine}' ${rt_path} > /dev/null"
                    eval ${grepCmd}
                    if [ $? -ne 0 ] ; then
                        log_it "Removing route: ${oldRouteLine}"
                        $(/usr/sbin/ip route del ${oldRouteLine})
                    fi
                done
            fi
        fi


        if [ -s ${PUPPET_DIR}/${rt} ] ; then
            # Whether this is a new routes file or there are changes, ultimately we will need
            # to ifup the file to add any potentially new routes.

            do_cp ${PUPPET_DIR}/${rt} ${ETC_DIR}/${rt}
            ${ETC_DIR}/ifup-routes ${iface_rt}

        else
            # Puppet routes file is empty, because we created an empty one due to absence of any routes
            # so that our check with the existing netscripts routes would work.
            # Just delete the netscripts file as there are no static routes left on this interface.
            do_rm ${ETC_DIR}/${rt}
        fi

        # Puppet redhat.rb file does not support removing routes from the same resource file.
        # Need to smoke the temp one so it will be properly recreated next time.

        do_cp ${PUPPET_DIR}/${rt} ${PUPPET_DIR}/${iface_rt}.back
        do_rm ${PUPPET_DIR}/${rt}

    done
}

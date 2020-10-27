#!/bin/bash
#
# Copyright (c) 2020 Wind River Systems, Inc.
#
# SPDX-License-Identifier: Apache-2.0
#
# Utility to add or remove cmdline options from /etc/default/grub
#

scriptname=$(basename $0)

function remove_options {
    local boot_arg
    local persisted_arg

    for boot_arg in "$@"; do
        # Get the persisted arg from /etc/default/grub, if it exists
        persisted_arg=$(
            grep "^GRUB_CMDLINE_LINUX=" /etc/default/grub \
                | sed -r -e "s/.*[\x22[:space:]](${boot_arg}|${boot_arg}=[^[:space:]]*)[\x22[:space:]].*/\1/"
        )

        # If sed couldn't find the arg, it returns the whole line, so clear it
        if [[ ${persisted_arg} =~ ^GRUB_CMDLINE_LINUX= ]]; then
            persisted_arg=""
        fi

        if [ -n "${persisted_arg}" ]; then
            # Remove option from /etc/default/grub and cleanup the whitespace
            echo "${scriptname}: Removing ${boot_arg}"
            sed -i -r \
                -e "/^GRUB_CMDLINE_LINUX=/ s/([\x22[:space:]])(${boot_arg}|${boot_arg}=[^[:space:]]*)([\x22[:space:]])/\1\3/" \
                -e "/^GRUB_CMDLINE_LINUX=/ s/[[:space:]][[:space:]]*/ /g" \
                -e "/^GRUB_CMDLINE_LINUX=/ s/[[:space:]]\x22$/\x22/" \
                -e "/^GRUB_CMDLINE_LINUX=/ s/^(GRUB_CMDLINE_LINUX=\x22)[[:space:]]/\1/" \
                /etc/default/grub
        fi
    done
}

function add_options {
    local boot_opt
    local boot_arg
    local persisted_arg

    for boot_opt in "$@"; do
        boot_arg=${boot_opt/=*/}

        # Get the persisted arg from /etc/default/grub, if it exists
        persisted_arg=$(
            grep "^GRUB_CMDLINE_LINUX=" /etc/default/grub \
                | sed -r -e "s/.*[\x22[:space:]](${boot_arg}|${boot_arg}=[^[:space:]]*)[\x22[:space:]].*/\1/"
        )

        # If sed couldn't find the arg, it returns the whole line, so clear it
        if [[ ${persisted_arg} =~ ^GRUB_CMDLINE_LINUX= ]]; then
            persisted_arg=""
        fi

        if [ -z "${persisted_arg}" ]; then
            # Add option to /etc/default/grub
            echo "${scriptname}: Adding ${boot_arg}"
            sed -i -r \
                -e "/^GRUB_CMDLINE_LINUX=/ s/\x22$/ ${boot_opt}\x22/" \
                /etc/default/grub
        else
            # Change option in /etc/default/grub
            echo "${scriptname}: Updating ${boot_arg}"
            sed -i -r \
                -e "/^GRUB_CMDLINE_LINUX=/ s/([\x22[:space:]])(${boot_arg}|${boot_arg}=[^[:space:]]*)([\x22[:space:]])/\1${boot_opt}\3/" \
                /etc/default/grub
        fi
    done
}

if [ "$1" = "--remove" ]; then
    shift; remove_options "$@"
elif [ "$1" = "--add" ]; then
    shift; add_options "$@"
else
    echo "${scriptname}: Expected --add or --remove option" >&2
    exit 1
fi

exit 0


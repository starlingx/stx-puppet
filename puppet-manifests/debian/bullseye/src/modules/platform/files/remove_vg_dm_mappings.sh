#!/bin/bash
#
# Copyright (c) 2026 Wind River Systems, Inc.
#
# SPDX-License-Identifier: Apache-2.0
#

# Remove the device-mapper mappings that belong to a single volume group.
#
# The mappings are selected by the VG name that device-mapper itself parses
# from the mapping UUID (dmsetup --select vg_name=...). The VG name is never
# matched as a prefix of the mapping name, so hyphenated VG names (dm doubles
# every hyphen: "my-vg" + "lv" => "my--vg-lv") are handled and a VG whose name
# extends another one (e.g. "vg" and "vg-fast") is left untouched.
#
# Usage: remove_vg_dm_mappings.sh <vg_name>
#
# Removal order matters for thin pools: LVs first, then the pool, then its
# hidden _tdata/_tmeta devices. Individual removal failures are tolerated and
# the script always exits 0, so the caller can proceed with vgremove.

VG="$1"

if [ -z "${VG}" ]; then
    echo "Usage: $0 <vg_name>" >&2
    exit 1
fi

MAPS=$(dmsetup info -c --noheadings -o name \
    --select "vg_name=\"${VG}\"" 2>/dev/null | sed 's/^[[:space:]]*//')

# remove_maps <phase>: lv | pool | hidden
remove_maps() {
    local phase="$1" map
    while IFS= read -r map; do
        [ -n "${map}" ] || continue
        case "${phase}:${map}" in
            lv:*_tdata|lv:*_tmeta|lv:*-tpool) continue ;;
            lv:*) ;;
            pool:*-tpool) ;;
            hidden:*_tdata|hidden:*_tmeta) ;;
            *) continue ;;
        esac
        echo "Removing dm mapping ${map} of VG ${VG}"
        dmsetup remove --force "${map}" || true
    done <<< "${MAPS}"
}

remove_maps lv
remove_maps pool
remove_maps hidden

exit 0

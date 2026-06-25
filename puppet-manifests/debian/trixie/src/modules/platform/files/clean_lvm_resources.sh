#!/bin/bash
#
# Copyright (c) 2026 Wind River Systems, Inc.
#
# SPDX-License-Identifier: Apache-2.0
#

# List all lvs with lvm-csi tag
LVS=$(lvs --config 'devices { filter=["a|.*|"] global_filter=["a|.*|"] }' --select 'vg_tags=lvm-csi' --noheading -o lv_path)

if [ -z "$LVS" ]; then
    echo "No LV found for lvm-csi purpose"
    exit 0
fi

# Load PVs list from argument (comma-separated)
PVS=$(echo "$1" | tr ',' ' ')

# Validate if LV is in use. If no PV is using the LV, remove it
for lv in $LVS; do
    base_lv=$(basename ${lv})
    if [[ " ${PVS} " == *" $base_lv "* ]]; then
        echo "${lv} is in use on a PV"
        continue
    else
        echo "Deleting LV ${lv}"
        # Delete lv
        lvremove ${lv} --force --config 'devices { filter=["a|.*|"] global_filter=["a|.*|"] }' 2>/dev/null
    fi
done

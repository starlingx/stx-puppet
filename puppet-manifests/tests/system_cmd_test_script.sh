#!/bin/bash

################################################################################
# Copyright (c) 2025 Wind River Systems, Inc.
#
# SPDX-License-Identifier: Apache-2.0
#
################################################################################

#
# This script is used by the automated tests
# tests.test_apply_network_config.GeneralTests.test_execute_system_cmd_timeout_*, it simulates a
# command that takes too long to terminate and triggers a timeout. In certain situations, the ifup
# command can exhibit this behavior.
#

return_code=$1
extra_sleep=$2

terminate()
{
    echo "< SIGTERM RECEIVED >"

    if [[ "$extra_sleep" == "-e" ]]; then
        sleep 10
        echo "< AFTER EXTRA SLEEP >"
    fi

    exit $return_code
}

trap terminate 15

echo "< BEFORE SLEEP >"
sleep 10
echo "< AFTER SLEEP >"

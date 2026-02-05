#!/usr/bin/python3
#
# Copyright (c) 2023 Wind River Systems, Inc.
#
# SPDX-License-Identifier: Apache-2.0
#
''' This program searches the IPv6 addresses to identify if there
are some in DAD tentative state, if the interface is operstate=UP
'''
import json
import subprocess
import sys

tentative = 0
result = subprocess.run(['ip', '-j', '-6', 'addr', 'show'], check=True, stdout=subprocess.PIPE)
intf_list = json.loads(result.stdout)
for intf in intf_list:
    if intf['operstate'] == "UP":
        for addr in intf["addr_info"]:
            if "tentative" in addr.keys():
                print(f"ipv6 address in state tentative for {intf['ifname']}:{addr}")
                tentative += 1

if tentative:
    sys.exit(1)
else:
    sys.exit(0)

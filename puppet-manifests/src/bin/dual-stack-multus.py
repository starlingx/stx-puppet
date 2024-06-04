#!/usr/bin/python3
#
# Copyright (c) 2024 Wind River Systems, Inc.
#
# SPDX-License-Identifier: Apache-2.0
#
''' This script updates the multus config to handle single or dual-stack
'''

import sys
import subprocess
import time
import re
from datetime import datetime

multus_config_map_file = "/tmp/multus-configmap.yaml"
kubectl_config = "--kubeconfig=/etc/kubernetes/admin.conf"


def prepend_timestamp_line(file_name):
    timestamp_str = datetime.now().strftime(format="%Y-%m-%d %H:%M:%S")
    with open(file_name, 'r') as read_file:
        lines = read_file.readlines()
    lines.insert(0, f"# generated at {timestamp_str}" + "\n")  # Add newline character
    with open(file_name, 'w') as write_file:
        write_file.writelines(lines)


def save_configmap(cmd, config_map_file):

    for i in range(0, 9):
        res = subprocess.run(cmd, check=False, capture_output=True)
        if res.returncode == 0:
            output = res.stdout.decode()
            with open(config_map_file, "wb") as output_file:
                output_file.write(output.encode())
                print(f"Successfully saved configmap to {config_map_file}")
                break
        else:
            if i == 9:
                print(f"An error occurred getting data, attempt={i}: {res}")
                sys.exit(1)
            else:
                time.sleep(5)


if __name__ == "__main__":
    if len(sys.argv) < 4:
        print("Usage: dual-stack-multus.py <protocol> <state> <restart_wait>")
        sys.exit(1)

    protocol = sys.argv[1].lower()
    if protocol not in ["ipv4", "ipv6"]:
        print("invalid IP protocol")
        sys.exit(1)

    state = sys.argv[2].lower()
    if state not in ["true", "false"]:
        print("invalid state for protocol")
        sys.exit(1)

    wait = 0
    try:
        wait = int(sys.argv[3])
    except ValueError:
        print(f"Error: restart_wait='{sys.argv[3]}' cannot be converted to an integer.")
        sys.exit(1)

    print(f"dual-stack-multus {protocol} {state} {wait}")

    print("execute: kubectl get cm -n kube-system multus-cni-config.v1 -o yaml")
    command = ["kubectl", kubectl_config, "-n", "kube-system",
               "get", "cm", "multus-cni-config.v1", "-o", "yaml"]
    save_configmap(command, multus_config_map_file)

    modified_data = str()
    with open(multus_config_map_file, "r") as file:
        multus_config_map = file.read()
        if protocol == "ipv4":
            match = re.search(r'"assign_ipv4": "(true|false)"', multus_config_map)
            if match:
                new_val = f'\"assign_ipv4\": \"{state}\"'
                modified_data = multus_config_map.replace(match.group(), new_val)
        elif protocol == "ipv6":
            match = re.search(r'"assign_ipv6": "(true|false)"', multus_config_map)
            if match:
                new_val = f'\"assign_ipv6\": \"{state}\"'
                modified_data = multus_config_map.replace(match.group(), new_val)

    with open(multus_config_map_file, "w") as file:
        file.write(modified_data)
    prepend_timestamp_line(multus_config_map_file)

    print(f"execute: kubectl apply -f {multus_config_map_file}")
    result = subprocess.run(["kubectl", kubectl_config,
                             "apply", "-f", multus_config_map_file],
                            check=False, stdout=subprocess.PIPE)
    print(f"update multus configmap result={result}")
    if result.returncode != 0:
        sys.exit(1)

    print("execute: kubectl rollout restart daemonset/multus -n kube-system")
    result = subprocess.run(["kubectl", kubectl_config, "-n", "kube-system",
                             "rollout", "restart", "daemonset", "kube-multus-ds-amd64"],
                            check=False, stdout=subprocess.PIPE)
    print(result)
    if result.returncode != 0:
        sys.exit(1)

print(f"wait {wait} seconds for the restarts")
time.sleep(wait)
sys.exit(0)

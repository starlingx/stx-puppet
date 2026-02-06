#!/usr/bin/python3
#
# Copyright (c) 2024 Wind River Systems, Inc.
#
# SPDX-License-Identifier: Apache-2.0
#
''' This script updates the calico config to handle single or dual-stack
'''

import sys
import subprocess
import yaml
import time
import re
import netaddr

from datetime import datetime


calico_config_map_file = "/tmp/calico-configmap.yaml"
calico_daemonset_file = "/tmp/calico-daemonset.yaml"

kubectl_config = "--kubeconfig=/etc/kubernetes/admin.conf"


def get_yaml_data(cmd, attempts=15):
    data = dict()
    for i in range(0, attempts):
        res = subprocess.run(cmd, check=False, stdout=subprocess.PIPE)
        if res.returncode != 0:
            if i == attempts:
                print(f"An error occurred getting data, attempt={i}: {res}")
                sys.exit(1)
            else:
                time.sleep(5)
        else:
            print("yaml data was collected")
            data = yaml.load(res.stdout, Loader=yaml.Loader)
            break
    return data


def is_valid_ip(address):
    try:
        if netaddr.valid_ipv4(address):
            return True
        if netaddr.valid_ipv6(address):
            return True
    except netaddr.AddrFormatError:
        pass
    return False


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
    if len(sys.argv) < 5:
        print("Usage: dual-stack-calico.py <protocol> <state> <c0_address> <restart_wait>")
        sys.exit(1)

    protocol = sys.argv[1].lower()
    if protocol not in ["ipv4", "ipv6"]:
        print("invalid IP protocol")
        sys.exit(1)

    state = sys.argv[2].lower()
    if state not in ["true", "false"]:
        print("invalid state for protocol")
        sys.exit(1)

    c0_address = sys.argv[3]
    if not is_valid_ip(c0_address):
        if state == "true":
            print(f"Error: invalid node_ip '{c0_address}', exit")
            sys.exit(1)
        else:
            c0_address = None

    wait = 0
    try:
        wait = int(sys.argv[4])
    except ValueError:
        print(f"Error: restart_wait='{sys.argv[4]}' cannot be converted to an integer.")
        sys.exit(1)

    print(f"dual-stack-calico {protocol} {state} {c0_address} {wait}")

    print("execute: kubectl get cm -n kube-system calico-config -o yaml")
    command = ["kubectl", kubectl_config, "-n", "kube-system",
               "get", "cm", "calico-config", "-o", "yaml"]
    save_configmap(command, calico_config_map_file)

    modified_data = str()
    with open(calico_config_map_file, "r") as file:
        calico_config_map = file.read()
        if protocol == "ipv4":
            match = re.search(r'"assign_ipv4": "(true|false)"', calico_config_map)
            if match:
                new_val = f'\"assign_ipv4\": \"{state}\"'
                modified_data = calico_config_map.replace(match.group(), new_val)
        elif protocol == "ipv6":
            match = re.search(r'"assign_ipv6": "(true|false)"', calico_config_map)
            if match:
                new_val = f'\"assign_ipv6\": \"{state}\"'
                modified_data = calico_config_map.replace(match.group(), new_val)

    with open(calico_config_map_file, "w") as file:
        file.write(modified_data)
    prepend_timestamp_line(calico_config_map_file)

    print(f"execute: kubectl apply -f {calico_config_map_file}")
    result = subprocess.run(["kubectl", kubectl_config, "apply", "-f", calico_config_map_file],
                            check=False, stdout=subprocess.PIPE)
    print(f"update calico configmap result={result}")
    if result.returncode != 0:
        sys.exit(1)

    print("execute: kubectl -n kube-system get daemonset calico-node -o yaml")
    command = ["kubectl", kubectl_config, "-n", "kube-system",
               "get", "daemonset", "calico-node", "-o", "yaml"]
    calico_ds_data = get_yaml_data(command, 9)

    for container in calico_ds_data['spec']['template']['spec']['containers']:
        ipv4_autodetect = False
        ipv6_autodetect = False
        for env in container['env']:
            if protocol == "ipv4":
                if env["name"] == "IP":
                    env["value"] = "autodetect" if state == "true" else "none"
                if env["name"] == "IP_AUTODETECTION_METHOD":
                    ipv4_autodetect = True
            if protocol == "ipv6":
                if env["name"] == "IP6":
                    env["value"] = "autodetect" if state == "true" else "none"
                if env["name"] == "IP6_AUTODETECTION_METHOD":
                    ipv6_autodetect = True
        if not ipv4_autodetect and protocol == "ipv4" and state == "true":
            container['env'].append({"name": "IP_AUTODETECTION_METHOD",
                                     "value": f"can-reach={c0_address}"})
        if not ipv6_autodetect and protocol == "ipv6" and state == "true":
            container['env'].append({"name": "IP6_AUTODETECTION_METHOD",
                                     "value": f"can-reach={c0_address}"})
        if ipv4_autodetect and protocol == "ipv4" and state == "false":
            container['env'] = [env for env in container['env']
                                if not env["name"] == "IP_AUTODETECTION_METHOD"]
        if ipv6_autodetect and protocol == "ipv6" and state == "false":
            container['env'] = [env for env in container['env']
                                if not env["name"] == "IP6_AUTODETECTION_METHOD"]

    with open(calico_daemonset_file, 'w') as config_file:
        yaml.dump(calico_ds_data, config_file, default_flow_style=False)
    prepend_timestamp_line(calico_daemonset_file)

    print(f"execute: kubectl apply -f {calico_daemonset_file}")
    result = subprocess.run(["kubectl", kubectl_config, "apply", "-f", calico_daemonset_file],
                            check=False, stdout=subprocess.PIPE)
    print(f"update calico daemonset result={result}")
    if result.returncode != 0:
        sys.exit(1)

print(f"wait {wait} seconds for the restarts")
time.sleep(wait)
sys.exit(0)

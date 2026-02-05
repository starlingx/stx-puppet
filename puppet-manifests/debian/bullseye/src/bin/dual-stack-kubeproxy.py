#!/usr/bin/python3
#
# Copyright (c) 2024 Wind River Systems, Inc.
#
# SPDX-License-Identifier: Apache-2.0
#
''' This script updates the kube-proxy config to handle single or dual-stack
'''

import sys
import subprocess
import yaml
import time
import netaddr

from datetime import datetime


config_map_file = "/tmp/kube-proxy-config.yaml"
proxy_config_file = "/tmp/kube-proxy-config-data.yaml"

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


def prepend_timestamp_line(file_name):
    timestamp_str = datetime.now().strftime(format="%Y-%m-%d %H:%M:%S")
    with open(file_name, 'r') as read_file:
        lines = read_file.readlines()
    lines.insert(0, f"# generated at {timestamp_str}" + "\n")  # Add newline character
    with open(file_name, 'w') as write_file:
        write_file.writelines(lines)


def is_valid_network(address):
    """
    This function checks if the provided string is a valid network address using netaddr.
    """
    try:
        netaddr.IPNetwork(address)
        return True
    except netaddr.AddrFormatError as ex:
        print(f"exception {str(ex)}")
    return False


if __name__ == "__main__":
    if len(sys.argv) < 4:
        print("Usage: dual-stack-kubeproxy.py <pod_prim_subnet> <pod_sec_subnet> <restart_wait>")
        sys.exit(1)

    pod_prim_subnet = sys.argv[1]
    pod_sec_subnet = sys.argv[2]

    if not is_valid_network(pod_prim_subnet):
        print(f"Error: invalid pod_prim_subnet '{pod_prim_subnet}', exit")
        sys.exit(1)

    if not is_valid_network(pod_sec_subnet):
        pod_sec_subnet = None

    wait = 0
    try:
        wait = int(sys.argv[3])
    except ValueError:
        print(f"Error: restart_wait='{sys.argv[3]}' cannot be converted to an integer.")
        sys.exit(1)

    print(f"dual-stack-kubeproxy {pod_prim_subnet} {pod_sec_subnet} {wait}")

    print("execute: kubectl -n kube-system get configmap kube-proxy -o yaml")
    command = ["kubectl", kubectl_config, "-n", "kube-system",
               "get", "configmap", "kube-proxy", "-o", "yaml"]
    yaml_data = get_yaml_data(command, 15)
    proxy_cfg_yaml = yaml_data["data"]["config.conf"]
    proxy_cfg = yaml.load(proxy_cfg_yaml, Loader=yaml.Loader)
    if pod_prim_subnet and pod_sec_subnet:
        proxy_cfg["clusterCIDR"] = f"{pod_prim_subnet},{pod_sec_subnet}"
    elif pod_prim_subnet and not pod_sec_subnet:
        proxy_cfg["clusterCIDR"] = f"{pod_prim_subnet}"

    with open(proxy_config_file, 'w') as config_file:
        yaml.dump(proxy_cfg, config_file, default_flow_style=False)

    proxy_config_str = str()
    with open(proxy_config_file, "r") as file:
        proxy_config_lines = file.readlines()
        for line in proxy_config_lines:
            proxy_config_str = proxy_config_str + line
    yaml_data["data"]["config.conf"] = proxy_config_str
    prepend_timestamp_line(proxy_config_file)

    with open(config_map_file, 'w') as config_file:
        yaml.dump(yaml_data, config_file, default_flow_style=False)
    prepend_timestamp_line(config_map_file)

    print(f"execute: kubectl apply -f {config_map_file}")
    result = subprocess.run(["kubectl", kubectl_config, "apply", "-f", config_map_file],
                            check=False, stdout=subprocess.PIPE)
    print(f"update configmap result={result}")
    if result.returncode != 0:
        sys.exit(1)

    print("execute: kubectl rollout restart daemonset -n kube-system kube-proxy")
    result = subprocess.run(["kubectl", kubectl_config, "-n", "kube-system",
                             "rollout", "restart", "daemonset", "kube-proxy"],
                            check=False, stdout=subprocess.PIPE)
    print(result)
    if result.returncode != 0:
        sys.exit(1)

print(f"wait {wait} seconds for the restarts")
time.sleep(wait)
sys.exit(0)

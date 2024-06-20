#!/usr/bin/python3
#
# Copyright (c) 2024 Wind River Systems, Inc.
#
# SPDX-License-Identifier: Apache-2.0
#
''' This script updates the kubeadm config to handle single or dual-stack
'''

import sys
import subprocess
import yaml
import time
import os
import netaddr

from datetime import datetime


config_map_file = "/tmp/kubeadm-config.yaml"
cluster_config_file = "/tmp/kubeadm-config-cluster.yaml"
kubectl_config = "--kubeconfig=/etc/kubernetes/admin.conf"
active_controller_puppet_path = '/opt/platform/puppet/'
INITCONFIG_TEMPLATE = '''---
apiVersion: kubeadm.k8s.io/v1beta3
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: {}'''


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
    if len(sys.argv) < 7:
        print("Usage: dual-stack-kubeadm.py <pod_prim_subnet>"
              " <svc_prim_subnet> <pod_sec_subnet> <svc_sec_subnet> <restart_wait>"
              " <advertise_address>")
        sys.exit(1)

    pod_prim_subnet = sys.argv[1]
    svc_prim_subnet = sys.argv[2]
    pod_sec_subnet = sys.argv[3]
    svc_sec_subnet = sys.argv[4]
    advertise_address = sys.argv[6]

    if not is_valid_network(pod_prim_subnet):
        print(f"Error: invalid pod_prim_subnet '{pod_prim_subnet}', exit")
        sys.exit(1)

    if not is_valid_network(svc_prim_subnet):
        print(f"Error: invalid svc_prim_subnet '{svc_prim_subnet}', exit")
        sys.exit(1)

    if not is_valid_ip(advertise_address):
        print(f"Error: invalid advertise_address '{advertise_address}', exit")
        sys.exit(1)

    if not is_valid_network(pod_sec_subnet):
        pod_sec_subnet = None

    if not is_valid_network(svc_sec_subnet):
        svc_sec_subnet = None

    wait = 0
    try:
        wait = int(sys.argv[5])
    except ValueError:
        print(f"Error: restart_wait='{sys.argv[5]}' cannot be converted to an integer.")
        sys.exit(1)

    print(f"dual-stack-kubeadm {pod_prim_subnet} {svc_prim_subnet}"
          f" {pod_sec_subnet} {svc_sec_subnet} {wait}")

    print("execute: kubectl -n kube-system get configmap kubeadm-config -o yaml")
    command = ["kubectl", kubectl_config, "-n", "kube-system",
               "get", "configmap", "kubeadm-config", "-o", "yaml"]
    yaml_data = get_yaml_data(command, 9)
    cluster_cfg_yaml = yaml_data["data"]["ClusterConfiguration"]
    cluster_cfg = yaml.load(cluster_cfg_yaml, Loader=yaml.Loader)
    configmap_reconfig = False
    if pod_prim_subnet and pod_sec_subnet:
        if cluster_cfg["networking"]["podSubnet"] != f"{pod_prim_subnet},{pod_sec_subnet}":
            cluster_cfg["networking"]["podSubnet"] = f"{pod_prim_subnet},{pod_sec_subnet}"
            configmap_reconfig = True
    elif pod_prim_subnet and not pod_sec_subnet:
        if cluster_cfg["networking"]["podSubnet"] != f"{pod_prim_subnet}":
            cluster_cfg["networking"]["podSubnet"] = f"{pod_prim_subnet}"
            configmap_reconfig = True
    if svc_prim_subnet and svc_sec_subnet:
        if cluster_cfg["networking"]["serviceSubnet"] != f"{svc_prim_subnet},{svc_sec_subnet}":
            cluster_cfg["networking"]["serviceSubnet"] = f"{svc_prim_subnet},{svc_sec_subnet}"
            configmap_reconfig = True
    elif svc_prim_subnet and not svc_sec_subnet:
        if cluster_cfg["networking"]["serviceSubnet"] != f"{svc_prim_subnet}":
            cluster_cfg["networking"]["serviceSubnet"] = f"{svc_prim_subnet}"
            configmap_reconfig = True

    with open(cluster_config_file, 'w') as config_file:
        yaml.dump(cluster_cfg, config_file, default_flow_style=False)

    cluster_config_str = str()
    with open(cluster_config_file, "r") as file:
        cluster_config_lines = file.readlines()
        for line in cluster_config_lines:
            cluster_config_str = cluster_config_str + line
    yaml_data["data"]["ClusterConfiguration"] = cluster_config_str

    with open(config_map_file, 'w') as config_file:
        yaml.dump(yaml_data, config_file, default_flow_style=False)
    prepend_timestamp_line(config_map_file)

    if configmap_reconfig:
        if os.path.exists(active_controller_puppet_path):
            print(f"execute: kubectl apply -f {config_map_file}")
            result = subprocess.run(["kubectl", kubectl_config, "apply", "-f", config_map_file],
                                    check=False, stdout=subprocess.PIPE)
            print(f"update configmap result={result}")
            if result.returncode != 0:
                sys.exit(1)
    else:
        print("configmap kubeadm-config already updated")

    print("execute: kubeadm init phase control-plane controller-manager --config"
          f" {cluster_config_file}")
    result = subprocess.run(["kubeadm", "init", "phase", "control-plane", "controller-manager",
                            "--config", cluster_config_file],
                            check=False, stdout=subprocess.PIPE)
    print(result)
    if result.returncode != 0:
        sys.exit(1)

    with open(cluster_config_file, 'a') as file:
        file.write(INITCONFIG_TEMPLATE.format(advertise_address))
    prepend_timestamp_line(cluster_config_file)

    # kubeadm init phase control-plane apiserver --config /tmp/kubeadm-config-cluster.yaml
    print(f"execute: kubeadm init phase control-plane apiserver --config {cluster_config_file}"
          f" --apiserver-advertise-address {advertise_address}")
    result = subprocess.run(["kubeadm", "init", "phase", "control-plane", "apiserver",
                             "--config", cluster_config_file],
                            check=False, stdout=subprocess.PIPE)
    print(result)
    if result.returncode != 0:
        sys.exit(1)

print(f"wait {wait} seconds for the restarts")
time.sleep(wait)
sys.exit(0)

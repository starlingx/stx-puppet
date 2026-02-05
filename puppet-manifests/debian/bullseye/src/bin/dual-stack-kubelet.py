#!/usr/bin/python3
#
# Copyright (c) 2024 Wind River Systems, Inc.
#
# SPDX-License-Identifier: Apache-2.0
#
''' This script updates the kubelet config to handle single or dual-stack
'''
import sys
import subprocess
import time
import yaml
import netaddr


filename = "/etc/default/kubelet"


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


if __name__ == "__main__":
    if len(sys.argv) < 5:
        print("Usage: dual-stack-kubelet.py <node_ip> <node_ip_secondary>"
              " <restart_wait> <kube-config>")
        sys.exit(1)

    node_ip = sys.argv[1]
    node_ip_secondary = sys.argv[2]

    if not is_valid_ip(node_ip):
        print(f"Error: invalid node_ip '{node_ip}', exit")
        sys.exit(1)

    if not is_valid_ip(node_ip_secondary):
        node_ip_secondary = None

    wait = 0
    try:
        wait = int(sys.argv[3])
    except ValueError:
        print(f"Error: restart_wait='{sys.argv[3]}' cannot be converted to an integer.")
        sys.exit(1)

    kubectl_config = ''
    if sys.argv[4]:
        kubectl_config = f"--kubeconfig={sys.argv[4]}"
    else:
        print(f"Error: invalid kubectl config='{kubectl_config}'")
        sys.exit(1)

    print(f"dual-stack-kubelet {node_ip} {node_ip_secondary} {wait} {kubectl_config}")

    # execute get to test availability of kube-api server
    print("execute: kubectl -n kube-system get configmap kubeadm-config -o yaml")
    command = ["kubectl", kubectl_config, "-n", "kube-system",
               "get", "configmap", "kubeadm-config", "-o", "yaml"]
    get_yaml_data(command, 20)

    try:
        # Open the file for reading
        with open(filename, "r") as file:
            # Read all lines from the file
            lines = file.readlines()
    except FileNotFoundError:
        print(f"Error: File '{filename}' not found.")
        sys.exit(1)
    # Check for empty line
    if not lines:
        print(f"filename {filename} is empty")
        sys.exit(1)
    line = str()
    for value in lines:
        if "KUBELET_EXTRA_ARGS" in value:
            line = value
    if not line:
        print(f"filename {filename} do not contain KUBELET_EXTRA_ARGS")
        sys.exit(1)
    kubelet = line.split('=', 1)
    kubelet_args = kubelet[1].split()
    need_reconfig = False
    modified_strings = []
    for arg in kubelet_args:
        if "--node-ip" in arg:
            if node_ip_secondary and arg != f"--node-ip={node_ip},{node_ip_secondary}":
                modified_strings.append(f"--node-ip={node_ip},{node_ip_secondary}")
                need_reconfig = True
            elif not node_ip_secondary and arg != f"--node-ip={node_ip}":
                modified_strings.append(f"--node-ip={node_ip}")
                need_reconfig = True
        else:
            modified_strings.append(arg)
    print(f"need_reconfig={need_reconfig}")
    if (need_reconfig):
        kubelet_args = modified_strings
        output_kubelet = str("# Overrides config file for kubelet\nKUBELET_EXTRA_ARGS=")
        output_kubelet += ' '.join(kubelet_args) + "\n"
        print(output_kubelet)
        with open(filename, "w") as file:
            file.writelines(output_kubelet)
        print("execute: kubeadm upgrade node phase kubelet-config")
        result = subprocess.run(['kubeadm', 'upgrade', 'node', 'phase', 'kubelet-config'],
                                check=False, stdout=subprocess.PIPE)
        print(result)
        if result.returncode != 0:
            sys.exit(1)
        print("execute: /usr/local/sbin/pmon-restart kubelet")
        result = subprocess.run(['/usr/local/sbin/pmon-restart', 'kubelet'],
                                check=False, stdout=subprocess.PIPE)
        print(result)
        if result.returncode != 0:
            sys.exit(1)

print(f"wait {wait} seconds for the restarts")
time.sleep(wait)
sys.exit(0)

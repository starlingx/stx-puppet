#
# Copyright (c) 2021 Wind River Systems, Inc.
#
# SPDX-License-Identifier: Apache-2.0
#
# This script edits a file containing a kubernetes ClusterConfiguration,
# appending to it the current InitConfiguration retrieved from kubeadm.
# This is especially useful during the command 'kubeadm init phase control-plane
# apiserver' which will reset the advertise-address parameter when called
# without a InitConfiguration.

import argparse
import ruamel.yaml as yaml

INIT_CONFIGURATION = 'InitConfiguration'

parser = argparse.ArgumentParser()
parser.add_argument('--cluster_config_file', required=True)
args = parser.parse_args()

cluster_config_path = args.cluster_config_file

with open(cluster_config_path, 'r') as cluster_config_file:
    cluster_config = yaml.load(cluster_config_file,
                               Loader=yaml.RoundTripLoader)

with open('/etc/kubernetes/kubeadm.yaml', 'r') as kubeadm_file:
    kubeadm_config = yaml.load_all(kubeadm_file, Loader=yaml.RoundTripLoader)
    init_config = next(config for config in kubeadm_config
                       if config['kind'] == INIT_CONFIGURATION)

with open(cluster_config_path, 'w') as cluster_config_file:
    yaml.dump_all([init_config, cluster_config],
                  cluster_config_file,
                  Dumper=yaml.RoundTripDumper,
                  default_flow_style=False)

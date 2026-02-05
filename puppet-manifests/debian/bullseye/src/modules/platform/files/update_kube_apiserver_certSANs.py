#
# Copyright (c) 2020 Wind River Systems, Inc.
#
# SPDX-License-Identifier: Apache-2.0
#
# This script updates the apiServer.certSANs of a file containing a
# kubernetes cluster configmap.

import argparse
import ruamel.yaml as yaml

parser = argparse.ArgumentParser()
parser.add_argument("--configmap_file", required=True)
parser.add_argument("--certsans", required=True)
args = parser.parse_args()

configmap_file = args.configmap_file

with open(configmap_file, 'r') as dest:
    configmap = yaml.load(dest, Loader=yaml.RoundTripLoader)
    # cluster config is a single string, so we need to parse the string
    # in order to modify it correctly
    cluster_config = yaml.load(configmap['data']['ClusterConfiguration'],
                               Loader=yaml.RoundTripLoader)

cluster_config['apiServer']['certSANs'] = \
    [item.strip() for item in args.certsans.split(',')]

cluster_config_string = yaml.dump(cluster_config, Dumper=yaml.RoundTripDumper,
                                  default_flow_style=False)

# use yaml.scalarstring.PreservedScalarString to make sure the yaml is
# constructed with proper formatting and tabbing
cluster_config_string = yaml.scalarstring.PreservedScalarString(
    cluster_config_string)
configmap['data']['ClusterConfiguration'] = cluster_config_string
with open(configmap_file, 'w') as dest:
    yaml.dump(configmap, dest, Dumper=yaml.RoundTripDumper,
              default_flow_style=False)

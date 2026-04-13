#
# Copyright (c) 2020, 2026 Wind River Systems, Inc.
#
# SPDX-License-Identifier: Apache-2.0
#
# This script updates the apiServer.certSANs of a file containing a
# kubernetes cluster configmap.

import argparse
from ruamel.yaml import YAML
from ruamel.yaml.compat import StringIO
from ruamel.yaml.scalarstring import PreservedScalarString

_yaml_rt = YAML(typ='rt')
_yaml_rt.default_flow_style = False

parser = argparse.ArgumentParser()
parser.add_argument("--configmap_file", required=True)
parser.add_argument("--certsans", required=True)
args = parser.parse_args()

configmap_file = args.configmap_file

with open(configmap_file, 'r') as dest:
    configmap = _yaml_rt.load(dest)
    # cluster config is a single string, so we need to parse the string
    # in order to modify it correctly
    cluster_config = _yaml_rt.load(configmap['data']['ClusterConfiguration'])

cluster_config['apiServer']['certSANs'] = \
    [item.strip() for item in args.certsans.split(',')]

outstream = StringIO()
_yaml_rt.dump(cluster_config, outstream)
cluster_config_string = outstream.getvalue()

# use PreservedScalarString to make sure the yaml is
# constructed with proper formatting and tabbing
cluster_config_string = PreservedScalarString(cluster_config_string)
configmap['data']['ClusterConfiguration'] = cluster_config_string
with open(configmap_file, 'w') as dest:
    _yaml_rt.dump(configmap, dest)

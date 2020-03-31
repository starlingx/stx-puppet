#
# Copyright (c) 2020 Wind River Systems, Inc.
#
# SPDX-License-Identifier: Apache-2.0
#
# This script edits a file containing a kubernetes cluster configmap.
# It currently adds/removes certain kube-apiserver startup parameters.
# If the script is run without a particular kube-apiserver parameter
# passed in as an argument, the existing kube-apiserver parameter will
# be removed.

import argparse
import ruamel.yaml as yaml

configmap_file = '/tmp/cluster_configmap.yaml'
parser = argparse.ArgumentParser()
parser.add_argument("--configmap_file")
parser.add_argument("--oidc_issuer_url")
parser.add_argument("--oidc_client_id")
parser.add_argument("--oidc_username_claim")
parser.add_argument("--oidc_groups_claim")
parser.add_argument("--admission_plugins")
args = parser.parse_args()

if args.configmap_file:
    configmap_file = args.configmap_file

with open(configmap_file, 'r') as dest:
    configmap = yaml.load(dest, Loader=yaml.RoundTripLoader)
    # cluster config is a single string, so we need to parse the string
    # in order to modify it correctly
    cluster_config = yaml.load(configmap['data']['ClusterConfiguration'],
                               Loader=yaml.RoundTripLoader)

if args.oidc_issuer_url:
    cluster_config['apiServer']['extraArgs']['oidc-issuer-url'] = \
        args.oidc_issuer_url
else:
    if 'oidc-issuer-url' in cluster_config['apiServer']['extraArgs']:
        del cluster_config['apiServer']['extraArgs']['oidc-issuer-url']

if args.oidc_client_id:
    cluster_config['apiServer']['extraArgs']['oidc-client-id'] = \
        args.oidc_client_id
else:
    if 'oidc-client-id' in cluster_config['apiServer']['extraArgs']:
        del cluster_config['apiServer']['extraArgs']['oidc-client-id']

if args.oidc_username_claim:
    cluster_config['apiServer']['extraArgs']['oidc-username-claim'] = \
        args.oidc_username_claim
else:
    if 'oidc-username-claim' in cluster_config['apiServer']['extraArgs']:
        del cluster_config['apiServer']['extraArgs']['oidc-username-claim']

if args.oidc_groups_claim:
    cluster_config['apiServer']['extraArgs']['oidc-groups-claim'] = \
        args.oidc_groups_claim
else:
    if 'oidc-groups-claim' in cluster_config['apiServer']['extraArgs']:
        del cluster_config['apiServer']['extraArgs']['oidc-groups-claim']

if args.admission_plugins:
    cluster_config['apiServer']['extraArgs']['enable-admission-plugins'] = \
        args.admission_plugins
else:
    plugins = 'enable-admission-plugins'
    if plugins in cluster_config['apiServer']['extraArgs']:
        del cluster_config['apiServer']['extraArgs'][plugins]

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

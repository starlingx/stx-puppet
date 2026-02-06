#
# Copyright (c) 2022 Wind River Systems, Inc.
#
# SPDX-License-Identifier: Apache-2.0
#
# This script updates kubernetes evictionHard and imageGC parameters
# to a yaml file containing kubernetes kubelet-config configmap.
# The original input file is overwritten with merged values.

import argparse
import ruamel.yaml as yaml

parser = argparse.ArgumentParser()
parser.add_argument('--configmap_file', required=True)
parser.add_argument('--image_gc_low_threshold_percent', type=int, default=75)
parser.add_argument('--image_gc_high_threshold_percent', type=int, default=79)
parser.add_argument('--eviction_hard_imagefs_available', default='2Gi')
args = parser.parse_args()

configmap_file = args.configmap_file

# The following are kubernetes evictionHard default settings, see reference:
# kubernetes/pkg/kubelet/apis/config/v1beta1/defaults_linux.go .
# All four parameters require explicit definition if we want to modify a
# subset of the values.
evictionHard_default = {
    'memory.available': '100Mi',
    'nodefs.available': '10%',
    'nodefs.inodesFree': '5%',
    'imagefs.available': '15%'
}

with open(configmap_file, 'r') as dest:
    configmap = yaml.load(dest, Loader=yaml.RoundTripLoader)

    # kubelet config is a single string. We need to parse the string
    # in order to modify it correctly.
    kubelet_config = yaml.load(configmap['data']['kubelet'],
                               Loader=yaml.RoundTripLoader)

    # Update imageGC parameters
    kubelet_config['imageGCLowThresholdPercent'] = args.image_gc_low_threshold_percent
    kubelet_config['imageGCHighThresholdPercent'] = args.image_gc_high_threshold_percent
    kubelet_config['evictionHard'] = evictionHard_default
    kubelet_config['evictionHard']['imagefs.available'] = args.eviction_hard_imagefs_available

    kubelet_config_string = yaml.dump(kubelet_config, Dumper=yaml.RoundTripDumper,
                                      default_flow_style=False)

# use yaml.scalarstring.PreservedScalarString to make sure the yaml is
# constructed with proper formatting and tabbing
kubelet_config_string = yaml.scalarstring.PreservedScalarString(
    kubelet_config_string)
configmap['data']['kubelet'] = kubelet_config_string
with open(configmap_file, 'w') as dest:
    yaml.dump(configmap, dest, Dumper=yaml.RoundTripDumper,
              default_flow_style=False)

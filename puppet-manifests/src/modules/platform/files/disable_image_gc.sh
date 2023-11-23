#!/bin/bash

#
# Copyright (c) 2023 Wind River Systems, Inc.
#
# SPDX-License-Identifier: Apache-2.0
#

FILENAME="/var/lib/kubelet/kubeadm-flags.env"

# If image-gc-high-threshold hasn't been set in the kubeadm
# flag file, then set it and restart kubelet
if ! grep -q "image-gc-high-threshold" ${FILENAME}; then
    /usr/bin/sed -i 's/ARGS="/ARGS="--image-gc-high-threshold 100 /' ${FILENAME}
    /usr/local/sbin/pmon-restart kubelet
fi

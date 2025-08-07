#
# Copyright (c) 2025 Wind River Systems, Inc.
#
# SPDX-License-Identifier: Apache-2.0
#
# Simple utility to read a kubeconfig file and export the client
# certificate/key pair bundled to a file.
#
# P.S: If more than one user is described in the file, it will
# take only the data for the first.
#

import argparse
import base64
import os

K8S_ADMIN_KUBECONFIG = '/etc/kubernetes/admin.conf'

parser = argparse.ArgumentParser()
parser.add_argument("--kubeconfig", required=False, default=K8S_ADMIN_KUBECONFIG)
parser.add_argument("--output_file", required=True)
args = parser.parse_args()

kubeconfig = args.kubeconfig
output_file = args.output_file

b64_cert_string = ''
b64_key_string = ''

with open(kubeconfig, 'r') as origin:
    cert_data_found = False
    key_data_found = False
    for line in origin.readlines():
        if 'client-certificate-data' in line:
            b64_cert_string = line.split()[-1]
            cert_data_found = True
        if 'client-key-data' in line:
            b64_key_string = line.split()[-1]
            key_data_found = True
        if cert_data_found and key_data_found:
            break

with open(output_file, 'w') as target:
    target.write(base64.b64decode(b64_cert_string).decode('utf-8'))
    target.write(base64.b64decode(b64_key_string).decode('utf-8'))

os.chmod(output_file, 0o600)

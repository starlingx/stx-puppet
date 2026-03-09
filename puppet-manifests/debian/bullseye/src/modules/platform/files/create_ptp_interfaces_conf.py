# Copyright (c) 2026 Wind River Systems, Inc.
#
# SPDX-License-Identifier: Apache-2.0

import argparse
from glob import glob
import os
import sys
import subprocess


def read_all_config_files(ptp_conf_dir):
    """
    Read all PTP configuration files and get
    all configured interface names.
    """
    # Create a list of PTP configuration files
    config_files = []
    for service in ['ptp4l', 'phc2sys', 'ts2phc']:
        pattern = f"{ptp_conf_dir}{service}-*.conf"
        config_files += glob(pattern)

    # Create a list of unique port names from all
    # PTP configuration files.
    ports = set()
    for config_file in config_files:
        with open(config_file, 'r', encoding='utf-8') as infile:
            for line in infile:
                line = line.lstrip().rstrip()
                if line.startswith('[') and line.endswith(']'):
                    port = line.strip('[]')
                    if port not in ['global', 'unicast_master_table']:
                        ports.add(port)
    return ports


def read_phc2sys_cmdlines(ptp_opt_dir):
    """
    Read phc2sys command line files and get
    all configured interface names.
    """
    # Create a list of phc2sys command line files
    pattern = f"{ptp_opt_dir}phc2sys-instance-*"
    files = glob(pattern)

    # Create a list of unique port names from all
    # command line files.
    ports = set()
    for file in files:
        with open(file, 'r', encoding='utf-8') as infile:
            data = infile.read()
            data = data.removeprefix('OPTIONS=')
            data = data.strip('\n').strip('"')
            split_data = data.split(' ')
            for i in range(len(split_data)):
                item = split_data[i]
                if item == '-s' and i + 1 < len(split_data):
                    ports.add(split_data[i + 1])
    return ports


def get_ports_phc_index(port_name):
    """
    Get port's PHC index.
    """
    # Execute ethtool command using -T option to retrieve
    # ports PTP information
    data = subprocess.check_output([
        '/usr/sbin/ethtool',
        '-T',
        f'{port_name}'
    ])
    data = data.decode()
    for line in data.split(os.linesep):
        if 'PTP Hardware Clock:' in line:
            split_line = line.split(':')
            if len(split_line) > 0:
                phc_index = split_line[1]
                return phc_index.lstrip().rstrip()
    return ''


def get_base_port(phc_index):
    """
    Get port's base port.
    """
    # Get PHC full path
    phc_path = f"/sys/class/net/*/device/ptp/ptp{phc_index}"
    ptp_devices = glob(phc_path)
    if len(ptp_devices) > 0:
        ptp_device = ptp_devices[0]
        split_device = ptp_device.split(os.sep)
        if len(split_device) > 4:
            return split_device[4].lstrip().rstrip()
    return ''


def main():
    """
    This script creates a new PTP configuration file to
    help map ports to its PHC index and base port.

    The way it retrieves the port information is reliable
    because it doesn't depend on port naming scheme or
    PCI slot id.

    This is an example of the file created in a GNR-D
    system, which uses two different prefix enp19 and
    enp27 for port of the same embedded NIC.

    # cat /etc/linuxptp/ptpinstance/ptp-interfaces.conf
    [enp19s0f0]
    phc_index 0
    base_port enp19s0f0
    [enp27s0f0]
    phc_index 0
    base_port enp19s0f0
    [enp108s0f7]
    phc_index 1
    base_port enp108s0f0

    The following example is from another GNR-D system
    that uses the eno* naming scheme.

    # cat /etc/linuxptp/ptpinstance/ptp-interfaces.conf
    [enp81s0f2]
    phc_index 0
    base_port enp81s0f0
    [enp138s0f1]
    phc_index 3
    base_port enp138s0f0
    [enp138s0f0]
    phc_index 3
    base_port enp138s0f0
    [enp81s0f1]
    phc_index 0
    base_port enp81s0f0

    Arguments:
    ----------
    - ptp_conf_dir: PTP configuration directory
    (usually /etc/linuxptp/ptpinstance)

    Returns:
    This script always returns 0

    """

    # Get PTP configuration files path from arguments list
    parser = argparse.ArgumentParser()
    parser.add_argument(
        'ptp_conf_dir',
        help='PTP configuration directory'
    )
    parser.add_argument(
        'ptp_opt_dir',
        help='PTP options directory'
    )
    args = parser.parse_args()
    ptp_conf_dir = args.ptp_conf_dir
    ptp_opt_dir = args.ptp_opt_dir

    try:
        ports = read_all_config_files(ptp_conf_dir)
        ports.update(read_phc2sys_cmdlines(ptp_opt_dir))
        filename = ptp_conf_dir + 'ptp-interfaces.conf'
        with open(filename, 'w', encoding='utf-8') as outfile:
            for port in ports:
                # Write port name
                outfile.write(f"[{port}]\n")
                # Write phc index
                phc_index = get_ports_phc_index(port)
                if phc_index != '':
                    outfile.write(f"phc_index {phc_index}\n")
                # Write base port
                base_port = get_base_port(phc_index)
                if base_port != '':
                    outfile.write(f"base_port {base_port}\n")
    except Exception as err:    # pylint: disable=W0703
        # Print the error message to puppet.log but
        # doesn't stop puppet.
        print(f'Create PTP interface config file failed, reason: {err}',
              file=sys.stdout)

    return 0


if __name__ == "__main__":
    sys.exit(main())

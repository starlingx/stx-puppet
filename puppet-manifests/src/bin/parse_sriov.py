#!/usr/bin/python3
#
# Copyright (c) 2025 Wind River Systems, Inc.
#
# SPDX-License-Identifier: Apache-2.0
#

from collections import defaultdict
import json
import os
import subprocess
import sys
import time
import yaml

DRIVER_NONE = "NONE"
DRIVER_VFIO = "vfio-pci"


def execute_command(command_to_run):
    """
    Executes a shell command and captures its output.

    Args:
        command_to_run (list): Command and arguments as a list of strings.

    Returns:
        tuple: (bool success/fail, str cmd output or error message)
    """
    message = ""
    try:
        result = subprocess.run(
            command_to_run,
            capture_output=True,
            text=True,
            check=True,
            encoding='utf-8',
            timeout=30
        )
        res = True

        if result.stdout:
            message += f"stdout: {result.stdout.strip()}"
        if result.stderr:
            # ignore message if ADDR was already bound to the driver
            if "skipping" not in result.stderr.strip().lower():
                message += f"\nstderr: {result.stderr.strip()}"
                res = False

        return res, message.strip()

    except subprocess.CalledProcessError as e:
        error_message = f"CalledProcessError. Error Code: {e.returncode}.\n"
        if e.stdout:
            error_message += f"  (stdout):\n{e.stdout.strip()}\n"
        if e.stderr:
            error_message += f"  (stderr):\n{e.stderr.strip()}\n"
        return False, error_message.strip()

    except (subprocess.TimeoutExpired, subprocess.SubprocessError) as e:
        error_message = f"Exception: {type(e).__name__}: {e}"
        return False, error_message


def chunk_list(addresses, size):
    """
    Splits a list into chunks of a specified size.

    Args:
        addresses (list): List of addresses to split.
        size (int): Maximum size of each chunk.

    Yields:
        list: Sublist of addresses.
    """
    for i in range(0, len(addresses), size):
        yield addresses[i:i + size]


def load_module(module_name):
    """
    Loads a kernel module using modprobe.

    Args:
        module_name (str): Name of the module to load.
    Returns:
        tuple: (bool success/fail, str modprobe output or error message)
    """

    command = ["/usr/sbin/modprobe", module_name]
    res, message = execute_command(command)
    return res, message


def load_driver(driver):
    """
    Loads and configures the specified driver,
    including special handling for vfio-pci.

    Args:
        driver (str): Name of the driver to load.

    Returns:
        bool: True if successful, False otherwise.
    """
    if driver == DRIVER_NONE:
        print("Driver Not informed.")

    elif driver == DRIVER_VFIO:
        # Load the vfio-pci driver with parameters
        command = ["/usr/sbin/modprobe", "vfio-pci",
                    "enable_sriov=1", "disable_idle_d3=1"]
        res, message = execute_command(command)
        if not res:
            print(f'ERROR: modprobe vfio-pci: {message}')
            return res

        # enable_sriov
        res, message = execute_command([
            "/bin/sh", "-c",
            "echo 1 > /sys/module/vfio_pci/parameters/enable_sriov"])
        if not res:
            print(f'ERROR: vfio_pci enable_sriov: {message}')
            return res

        # disable_idle_d3
        res, message = execute_command([
            "/bin/sh", "-c",
            "echo 1 > /sys/module/vfio_pci/parameters/disable_idle_d3"])
        if not res:
            print(f'ERROR: vfio_pci disable_idle_d3: {message}')
            return res

        print(f"Driver bound: {driver}")
    else:
        # load the driver (i.e: iavf, ixgbevf )
        res, message = load_module(driver)
        if not res:
            print(f'ERROR: modprobe {driver}: {message}')
            return res
        print(f"Driver bound: {driver}")

    return True


def sriov_bind(driver, addresses):
    """
    Binds a list of SR-IOV VFs to a specified driver.

    Args:
        driver (str): Driver name to bind.
        addresses (list): List of PCI addresses of VFs.

    Returns:
        bool: True if all bindings were successful, False otherwise.
    """
    res = load_driver(driver)
    if not res:
        return res

    # No driver informed, ignore dpdk-devbind.py for these VFs
    if driver == DRIVER_NONE:
        for chunk in chunk_list(addresses, 15):
            addr_list = " ".join(chunk)
            print(f'IGNORE sriov_vf_bind for VFs:{addr_list}')
        return True

    # Bind the VF to the driver
    # dpdk-devbind.py accepts multiple ADDR at same time
    # dpdk-devbind.py --bind=vfio-pci 0000:07:02.3 0000:07:02.4 0000:07:02.5
    driver_param = "--bind=" + driver

    for chunk in chunk_list(addresses, 15):
        addr_list = " ".join(chunk)
        command = ["/usr/share/starlingx/scripts/dpdk-devbind.py",
                    driver_param] + chunk
        ret, message = execute_command(command)

        if ret is True:
            print(f'sriov_vf_bind driver: {driver} - VFs:{addr_list}')
        else:
            print(f'Error: sriov_vf_bind driver: {driver} - VFs:{addr_list} : {message}')
            res = False

    return res


def set_max_tx_rate(port, vfnumber, max_tx_rate):
    """
    Sets the maximum transmit rate for a specific VF on a port.

    Args:
        port (str): Network interface name.
        vfnumber (int): VF index.
        max_tx_rate (int): Maximum transmit rate in Mbps.
    """
    res = True
    message = ""
    for _ in range(5):
        command = ["ip", "link", "set", port,
                    "vf", str(vfnumber), "max_tx_rate", str(max_tx_rate)]
        res, message = execute_command(command)
        if res:
            print(f'sriov_vf_ratelimit: {max_tx_rate} port: {port} vf: {vfnumber}')
            break
        time.sleep(1)

    if not res:
        print(f'ERROR: sriov_vf_ratelimit: {max_tx_rate} port: {port}'
              f' vf: {vfnumber} msg: {message}')

    return res


def get_sriov_entries(sriov_configs):
    """
    Extracts VF addresses and max_tx_rate settings from SR-IOV config.
    the VF addresses are grouped by driver, so each driver is loaded just once.

    Args:
        sriov_configs (dict): Dictionary of SR-IOV interface configurations.
                              It is the SR-IOV config from hieradata.
                              i.e:
                              .../puppet/<REL>/hieradata/controller-0.yaml

    Returns:
        tuple: (bool success/fail,
                (dict driver_to_addresses, list rate_limit_settings))
    """
    try:
        sriov_entries = defaultdict(list)
        max_tx_rate_list = []

        if not isinstance(sriov_configs, dict):
            raise TypeError("sriov_configs must be a dictionary")

        for sriov_name, config_details in sriov_configs.items():
            if not isinstance(config_details, dict):
                raise TypeError(f"config_details for {sriov_name} must be a dictionary")

            # just get the necessary values
            sriov_if = {
                'num_vfs': config_details.get('num_vfs'),
                'port_name': config_details.get('port_name'),
                'vf_config': config_details.get('vf_config', {})
            }
            port_name = config_details.get('port_name')
            vf_config = sriov_if['vf_config']

            if not port_name:
                raise TypeError(f'port_name for {sriov_name} must not be empty')

            if vf_config:
                if not isinstance(vf_config, dict):
                    raise TypeError(f'vf_config for {sriov_name} must be a dictionary')

                for vf_addr, vf_details in vf_config.items():

                    if not vf_addr:
                        raise TypeError(f'vf_addr for {sriov_name} must not be empty')

                    if vf_details and not isinstance(vf_details, dict):
                        raise TypeError(f'vf_details for {sriov_name} must be a dictionary')

                    driver = vf_details.get('driver')
                    if not driver or driver == 'null' or driver == 'undef':
                        driver = DRIVER_NONE

                    sriov_entries[driver].append(vf_addr)

                    vfnumber = vf_details.get('vfnumber', None)
                    max_tx_rate = vf_details.get('max_tx_rate', None)

                    if vfnumber is not None and max_tx_rate is not None:
                        max_tx_rate_list.append({
                            'port': port_name,
                            'vfnumber': vfnumber,
                            'max_tx_rate': max_tx_rate})

        return True, (sriov_entries, max_tx_rate_list)

    except (TypeError, ValueError) as e:
        print(f"Error: get_sriov_entries: {e}")
        return False, ([], [])


def parse_and_process_sriov_config(data):
    """
    Parses and applies SR-IOV configuration from provided data.

    Args:
        data (dict): Parsed content from a JSON or YAML configuration file.
                     It is the SR-IOV config from hieradata.
                     i.e:
                     /opt/platform/puppet/<REL>/hieradata/controller-0.yaml

    Returns:
        tuple: (bool success/fail, dict sriov_entries configured)
    """
    try:
        # empty is valid
        if not data:
            return True, []

        if not isinstance(data, dict):
            print(f"Error: data is not a dictionary: {type(data).__name__}")
            return False, []

        sriov_configs = data.get('platform::network::interfaces::sriov::sriov_config', {})

        # empty is valid
        if not sriov_configs:
            return True, []

        ret, (sriov_entries, max_tx_rate_list) = get_sriov_entries(sriov_configs)
        if not ret:
            return False, []

        res = True
        for driver_name, addresses in sriov_entries.items():
            if sriov_bind(driver_name, addresses) is False:
                res = False

        for item in max_tx_rate_list:
            if set_max_tx_rate(item['port'],
                               item['vfnumber'],
                               item['max_tx_rate']) is False:
                res = False

        return res, sriov_entries

    except (KeyError, TypeError, ValueError) as e:
        print(f"Error: parsing SRIOV: {type(e).__name__}: {e}")
        return False, []


def main():
    """
    Entry point of the script. Loads a configuration file,
    parses its SR-IOV config and applies driver bindings and
    VF rate settings.
    """
    if os.geteuid() != 0:
        print("Error: This script must be run as root.")
        sys.exit(1)

    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <config-file.json|yaml>")
        sys.exit(1)

    config_file = sys.argv[1]
    if not os.path.isfile(config_file):
        print(f"Error: File not found: {config_file}")
        sys.exit(1)

    ext = os.path.splitext(config_file)[1].lower()

    try:
        with open(config_file, 'r') as f:
            if ext == '.json':
                data = json.load(f)
            elif ext == '.yaml':
                data = yaml.safe_load(f)
            else:
                print(f"Error: Unsupported file extension: {ext}. Use .json or .yaml")
                sys.exit(1)
    except (json.JSONDecodeError, yaml.YAMLError, OSError) as e:
        print(f"Error reading or parsing file: {type(e).__name__}: {e}")
        sys.exit(1)

    ret, all_sriov_entries = parse_and_process_sriov_config(data)

    if not ret:
        sys.exit(1)

    if not all_sriov_entries:
        print("No SRIOV entries found.")

    sys.exit(0)


if __name__ == "__main__":
    main()

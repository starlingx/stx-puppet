# Copyright (c) 2025 Wind River Systems, Inc.
#
# SPDX-License-Identifier: Apache-2.0

import argparse
import os
import sys
from pynetlink import NetlinkDPLL   # pylint: disable=import-error


def get_clock_id(interface_name):
    """Get interface's clock ID

    This function reads the interface's clock ID from sysfs. The ice driver
    provides the file phys_switch_id, which contains the phy's switch id,
    which is the same value of the clock id, but in hexadecimal format.

    This function reads the interface's phys_switch_id file, then converts
    its content to decimal format.

    Return: the interface's clock id
    """
    filepath = f'/sys/class/net/{interface_name}/phys_switch_id'
    if not os.path.exists(filepath):
        raise Exception(f'Invalid network interface: {interface_name}')

    with open(filepath, 'r', encoding='utf-8') as infile:
        data = infile.read().strip('\n')

    if not data:
        raise Exception(f'Invalid network interface: {interface_name}')

    data = '0x' + data
    return int(data, 16)


def main():
    """This script updates the network card PTP pin function via
    Netlink.

    For example, the SMA1 pin can be configured as input or output
    function.

    The script requires three positional arguments: interface, pin name, and
    function.

    Arguments:
    ----------
    - interface: the interface name assigned to the network card
    - pin name: the PTP pin name
    - function: the pin function

    Returns:
    - rc = 0, in case of success updating the configuration
    - rc = -1, in case of failure
    """

    # Args Parameters
    parser = argparse.ArgumentParser()
    parser.add_argument('interface', help='network interface name')
    parser.add_argument('pin_name', help='pin name')
    parser.add_argument('function', help='function')

    args = parser.parse_args()

    interface = args.interface
    pin_name = args.pin_name
    pin_function = args.function

    try:
        # Get interface's clock id
        clock_id = get_clock_id(interface)

        # Print argument list to puppet.log
        print(f'Change NIC pin configuration args. '
              f'interface name: {interface} '
              f'pin name: {pin_name} '
              f'function: {pin_function} '
              f'clock id: {clock_id}',
              file=sys.stdout)

        dpll = NetlinkDPLL()

        # Get the pin id from clock id and pin name
        pins = dpll.get_all_pins().\
            filter_by_device_clock_id(clock_id).\
            filter_by_pin_board_label(pin_name)
        if len(pins) == 0:
            raise Exception(f'Invalid pin name: {pin_name}')
        pin_id = list(pins)[0].pin_id

        # Set pin configuration
        dpll.set_pin_direction(pin_id, pin_function)

    except Exception as err:    # pylint: disable=W0703
        # Print the error message to puppet.log
        print(f'Change NIC pin configuration failed! Reason: {err}',
              file=sys.stdout)

        # Print to stderr to stop puppet
        print('failed!', file=sys.stderr)
        return -1

    return 0


if __name__ == "__main__":
    sys.exit(main())

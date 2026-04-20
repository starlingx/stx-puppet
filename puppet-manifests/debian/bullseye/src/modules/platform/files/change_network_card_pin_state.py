# Copyright (c) 2026 Wind River Systems, Inc.
#
# SPDX-License-Identifier: Apache-2.0

import argparse
import sys

from pynetlink import NetlinkDPLL   # pylint: disable=import-error


def main():
    """This script updates the network card PTP pin state via NetlinkDPLL.

    For example, change pps/eec state to disconnected/selectable
    The script requires 2 positional arguments: pin_package_label and state.

    Arguments:
    - pin_package_label: the pin_package_label assigned to the network card
    - state: the pin state to set

    Returns:
    - rc = 0, set pin state successfully
    - rc = 1, in case of failure
    """
    parser = argparse.ArgumentParser()
    parser.add_argument('--pin_package_label', help='pin package label')
    parser.add_argument('--state', help='pin state')

    args = parser.parse_args()
    pin_package_label = args.pin_package_label
    state = args.state

    print(f'Change NIC pin state args. '
          f'pin_package_label: {pin_package_label} '
          f'state: {state}',
          file=sys.stdout)

    try:
        dpll = NetlinkDPLL()

        # Get the pin id via pin_package_label
        pins = dpll.get_all_pins().\
            filter_by_pin_package_label(pin_package_label)
        if len(pins) == 0:
            # Ignore NICs e.g. westport channel that doesn't have REF4P
            print('Ignore non GNR-D NIC. Reason: no pin package label REF4P',
                  file=sys.stdout)
            return 0
        pin_id = list(pins)[0].pin_id

        # Set pin state
        dpll.set_pin_state(pin_id, state)

    except Exception as err:    # pylint: disable=W0703
        # Print the error message to puppet.log
        print(f'Change NIC pin state failed! Reason: {err}',
              file=sys.stdout)

        # Print to stderr to stop puppet
        print('failed!', file=sys.stderr)

        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())

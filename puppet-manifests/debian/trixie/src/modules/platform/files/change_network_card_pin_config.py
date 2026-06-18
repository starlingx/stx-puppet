# Copyright (c) 2026 Wind River Systems, Inc.
#
# SPDX-License-Identifier: Apache-2.0

"""Apply DPLL pin priority/state configuration via netlink.

This script reads a JSON config file and sets pin priorities/states on the
zl3073x DPLL hardware using pynetlink. It is invoked by puppet after
ptp-instance-apply.

Usage:
    python change_network_card_pin_config.py --config /tmp/dpll_pin_config.json

JSON format:
    [
        {"group": "gnss", "priority": 0},
        {"group": "synce", "priority": 5},
        {"group": "ptp", "priority": 10},
        {"group": "ext", "state": "disconnected"}
    ]

Exit codes:
    0 — success (or no matching pins found, i.e. non-GNR-D hardware)
    1 — netlink error on one or more pins
"""

import argparse
import json
import sys

from pynetlink import NetlinkDPLL  # pylint: disable=import-error
from pynetlink.dpll.constants import PinDirection  # pylint: disable=import-error
from pynetlink.dpll.constants import PinType  # pylint: disable=import-error

DPLL_MODULE_NAME = 'zl3073x'

# Pin group definitions. Each group is a filter function over pin attributes.
# This is the single place to update if board labels change on future hardware.
PIN_GROUPS = {
    'gnss': lambda p: (p.pin_type == PinType.GNSS and
                       p.pin_direction == PinDirection.INPUT),
    'synce': lambda p: (p.pin_type == PinType.SYNCE and
                        p.pin_direction == PinDirection.INPUT),
    'ptp': lambda p: (p.pin_type == PinType.EXT and
                      p.pin_direction == PinDirection.INPUT and
                      'SDP_TIMESYNC' in (p.pin_board_label or '')),
    'ext': lambda p: (p.pin_type == PinType.EXT and
                      p.pin_direction == PinDirection.INPUT and
                      'SDP_TIMESYNC' not in (p.pin_board_label or '') and
                      (p.pin_board_label or '') != ''),
}


def apply_config(config_entries):  # pylint: disable=too-many-branches
    """Apply pin priority/state configuration.

    Returns 0 on success, 1 if any netlink error occurred.
    """
    dpll = NetlinkDPLL()
    all_pins = dpll.get_all_pins()

    # Scope to GNR-D timing module only
    zl_pins = [p for p in all_pins if p.dev_module_name == DPLL_MODULE_NAME]

    if not zl_pins:
        print(f'No {DPLL_MODULE_NAME} pins found — not GNR-D hardware, '
              'skipping')
        return 0

    # Deduplicate pins (they appear once per DPLL device association)
    seen_ids = set()
    unique_pins = []
    for p in zl_pins:
        if p.pin_id not in seen_ids:
            seen_ids.add(p.pin_id)
            unique_pins.append(p)

    had_error = False

    for entry in config_entries:
        group = entry.get('group')
        priority = entry.get('priority')
        state = entry.get('state')

        if not group:
            print('Entry missing "group" field', file=sys.stderr)
            had_error = True
            continue

        if priority is None and state is None:
            print(f'No priority or state for group={group}', file=sys.stderr)
            had_error = True
            continue

        if group not in PIN_GROUPS:
            print(f'Unknown group: {group}', file=sys.stderr)
            had_error = True
            continue

        if priority is not None:
            try:
                priority = int(priority)
            except (ValueError, TypeError):
                print(f'Invalid priority value: {priority}', file=sys.stderr)
                had_error = True
                continue

        # Find matching pins for this group
        matched = [p for p in unique_pins if PIN_GROUPS[group](p)]

        if not matched:
            print(f'No matching pins for group={group} — skipping')
            continue

        for pin in matched:
            try:
                if priority is not None:
                    dpll.set_pin_priority(pin.pin_id, priority)
                    print(f'Set pin {pin.pin_id} '
                          f'({pin.pin_board_label or group}) '
                          f'priority={priority}')
                if state is not None:
                    dpll.set_pin_state(pin.pin_id, state)
                    print(f'Set pin {pin.pin_id} '
                          f'({pin.pin_board_label or group}) '
                          f'state={state}')
            except Exception as err:  # pylint: disable=broad-except
                print(f'Failed to set pin {pin.pin_id} '
                      f'({pin.pin_board_label or group}): {err}',
                      file=sys.stderr)
                had_error = True

    return 1 if had_error else 0


def main():
    parser = argparse.ArgumentParser(
        description='Apply DPLL pin priority configuration')
    parser.add_argument('--config', required=True,
                        help='Path to JSON config file')
    args = parser.parse_args()

    try:
        with open(args.config, 'r', encoding='utf-8') as f:
            config_entries = json.load(f)
    except (IOError, json.JSONDecodeError) as err:
        print(f'Failed to read config: {err}', file=sys.stderr)
        return 1

    if not isinstance(config_entries, list):
        print('Config must be a JSON array', file=sys.stderr)
        return 1

    if not config_entries:
        print('Empty config — nothing to do')
        return 0

    return apply_config(config_entries)


if __name__ == '__main__':
    sys.exit(main())

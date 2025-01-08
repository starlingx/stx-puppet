#!/usr/bin/python3
#
# Copyright (c) 2025 Wind River Systems, Inc.
#
# SPDX-License-Identifier: Apache-2.0
#

import argparse
from datetime import datetime
import errno
import fcntl
import logging as LOG
from netaddr import AddrFormatError
from netaddr import IPAddress
import os
import re
import signal
import shlex
import subprocess
import sys
import time

LOG_FILE = "/var/log/user.log"
PUPPET_DIR = "/var/run/network-scripts.puppet"
PUPPET_FILE = "/var/run/network-scripts.puppet/interfaces"
PUPPET_ROUTES_FILE = "/var/run/network-scripts.puppet/routes"
PUPPET_ROUTES6_FILE = "/var/run/network-scripts.puppet/routes6"
ETC_ROUTES_FILE = "/etc/network/routes"
ETC_DIR = "/etc/network/interfaces.d"
SYSINV_LOCK_FILE = "/var/run/apply_network_config.lock"
UPGRADE_FILE = "/var/run/.network_upgrade_bootstrap"
SUBCLOUD_ENROLLMENT_FILE = "/var/run/.enroll-init-reconfigure"
CLOUD_INIT_FILE = ETC_DIR + "/50-cloud-init"
IFSTATE_BASE_PATH = "/run/network/ifstate."
DEVLINK_BASE_PATH = "/sys/class/net/"
CFG_PREFIX = "ifcfg-"
TERM_WAIT_TIME = 10

# Interface types
ETH = "eth"
VLAN = "vlan"
BONDING = "bonding"
SLAVE = "slave"
LABEL = "label"
LO = "lo"

# Order for setting interfaces down
DOWN_ORDER = (LABEL, VLAN, BONDING, LO, ETH)
# Order for setting interfaces up
UP_ORDER = (ETH, LO, BONDING, VLAN, LABEL)
# Order for configuring interfaces without down/up operation
ONLINE_ORDER = (ETH, BONDING, VLAN, LABEL)

# Interface property sort positions
PROPERTY_SORT_POS = {
    "iface": 0,
    "vlan-raw-device": 1,
    "address": 2,
    "netmask": 3,
    "gateway": 4,
    "bond-master": 5,
    "bond-miimon": 6,
    "bond-mode": 7,
    "bond-primary": 8,
    "bond-slaves": 9,
    "hwaddress": 10,
    "mtu": 11,
    "pre-up": 12,
    "up": 13,
    "post-up": 14,
    "pre-down": 15,
    "down": 16,
    "post-down": 17,
    "allow-": 19,
    # Position DEFAULT_POS holds properties that are not in the list, allow- is put last to not
    # break ifupdown parsing, see https://review.opendev.org/c/starlingx/stx-puppet/+/839620
}

# Default sort position for properties
DEFAULT_POS = 18


class InvalidNetmaskError(BaseException):
    pass


class StanzaParser():

    @staticmethod
    def ParseLines(lines):
        parser = StanzaParser()
        parser.parse_lines(lines)
        return parser.get_auto_and_ifaces()

    def __init__(self):
        self.auto = []
        self.auto_set = set()
        self.ifaces = dict()
        self.iface = None
        self.state = "none"

    def _proc_state_auto(self, verbs):
        for iface in verbs[1:]:
            if iface not in self.auto_set:
                self.auto.append(iface)
                self.auto_set.add(iface)
        self.state = "none"

    def _proc_state_start_iface(self, verbs):
        self.iface = self.ifaces.setdefault(verbs[1], {verbs[0]: " ".join(verbs[1:])})
        self.state = "continue-iface"

    def _proc_state_continue_iface(self, verbs):
        # Special case for allow- property
        if "allow-" in verbs[0]:
            self.iface["allow-"] = " ".join(verbs)
        else:
            self.iface[verbs[0]] = " ".join(verbs[1:]) if len(verbs) > 1 else None

    STATES = {
        "none": lambda self, line: None,
        "start-auto": _proc_state_auto,
        "start-iface": _proc_state_start_iface,
        "continue-iface": _proc_state_continue_iface,
        "standby-iface": lambda self, line: None,
    }

    NEXT_STATES = {
        "none": {"new-auto": "start-auto",
                 "new-iface": "start-iface"},
        "continue-iface": {"new-auto": "start-auto",
                           "new-iface": "start-iface",
                           "empty": "standby-iface",
                           "reset": "none"},
        "standby-iface": {"new-auto": "start-auto",
                          "new-iface": "start-iface",
                          "continue": "continue-iface",
                          "reset": "none"}
    }

    def _proc_state(self, verbs):
        func = self.STATES[self.state]
        func(self, verbs)

    def _proc_event(self, event):
        self.state = self.NEXT_STATES[self.state].get(event, self.state)

    @staticmethod
    def _get_event(verbs):
        if len(verbs) == 0 or verbs[0].startswith("#"):
            return "empty"
        if verbs[0] == "auto":
            return "new-auto"
        if verbs[0] == "iface":
            if len(verbs) > 1:
                return "new-iface"
            return "reset"
        return "continue"

    def _parse_line(self, line):
        verbs = line.split()
        event = self._get_event(verbs)
        self._proc_event(event)
        self._proc_state(verbs)

    def parse_lines(self, lines):
        for line in lines:
            self._parse_line(line.strip())
        self.state = "none"

    def get_auto_and_ifaces(self):
        return self.auto, self.ifaces


def read_file_lines(path):
    with open(path, "r") as f:
        lines = f.readlines()
    return [line.strip() for line in lines]


def read_file_text(path):
    with open(path, "r") as f:
        return f.read()


def is_label(iface):
    return ":" in iface


def get_base_iface(iface):
    return iface.split(":")[0]


def execute_system_cmd(cmd, timeout=30):
    # When transitioning management network to a VLAN, ifup (for the mgmt interface) does its job
    # in configuring the link but blocks sub.communicate() for a long period of time, long enough
    # to cause the puppet task to end by timeout.
    # If the subprocess is ended via sub.terminate(), sub.communicate() still blocks for an
    # indefinite period of time. The only way that was found for the function to work as intended
    # was to add start_new_session=True to subprocess.Popen() and to terminate the process group via
    # os.killpg().

    sub = subprocess.Popen(shlex.split(cmd),
                           start_new_session=True,
                           stdout=subprocess.PIPE,
                           stderr=subprocess.STDOUT)
    try:
        stdout, _ = sub.communicate(timeout=timeout)
        decoded_stdout = stdout.decode('utf-8')
    except subprocess.TimeoutExpired:
        pgid = os.getpgid(sub.pid)
        LOG.warning(f"Execution time exceeded for command '{cmd}', "
                    f"sending SIGTERM to subprocess (pid={sub.pid}, pgid={pgid})")
        os.killpg(pgid, signal.SIGTERM)
        try:
            stdout, _ = sub.communicate(timeout=TERM_WAIT_TIME)
        except subprocess.TimeoutExpired:
            LOG.warning(f"Command '{cmd}' has not terminated after {TERM_WAIT_TIME} seconds, "
                        f"sending SIGKILL to subprocess (pid={sub.pid}, pgid={pgid})")
            os.killpg(pgid, signal.SIGKILL)
            stdout, _ = sub.communicate()
        decoded_stdout = stdout.decode('utf-8')
        if sub.returncode == 0:
            LOG.info(f"Command '{cmd}' output:{format_stdout(decoded_stdout)}")
    return sub.returncode, decoded_stdout


def apply_config(routes_only):
    if routes_only:
        LOG.info("Process Debian route config")
        update_routes()
    else:
        if not os.path.isdir(PUPPET_DIR):
            LOG.error("No puppet files? Nothing to do! Aborting...")
            sys.exit(1)
        LOG.info("Process Debian network config")
        log_network_info()
        updated_ifaces = update_interfaces()
        update_routes(updated_ifaces)
        check_enrollment_config()
        log_network_info()
    LOG.info("Finished")


def log_network_info():
    _, links = execute_system_cmd("/usr/sbin/ip addr show")
    _, routes_ipv4 = execute_system_cmd("/usr/sbin/ip route show")
    _, routes_ipv6 = execute_system_cmd("/usr/sbin/ip -6 route show")
    LOG.info("Network info:\n************ Links/addresses ************\n"
             f"{links}"
             "************ IPv4 routes ****************\n"
             f"{routes_ipv4}"
             "************ IPv6 routes ****************\n"
             f"{routes_ipv6}"
             "*****************************************")


def get_new_config():
    '''Gets new network config from puppet directory'''
    auto, ifaces = parse_interface_stanzas()
    return build_config(auto, ifaces, is_from_puppet=True)


def parse_interface_stanzas():
    lines = read_file_lines(PUPPET_FILE)
    return StanzaParser.ParseLines(lines)


def get_current_config():
    '''Gets current network config in etc directory'''
    auto = parse_auto_file()
    ifaces = parse_ifcfg_files(auto)
    return build_config(auto, ifaces, is_from_puppet=False)


def parse_auto_list(input_auto, ifaces, is_from_puppet):
    valid_auto = []
    invalid_auto = []
    for iface in input_auto:
        if iface in ifaces:
            valid_auto.append(iface)
        else:
            invalid_auto.append(iface)
    if invalid_auto:
        origin = "PUPPET" if is_from_puppet else "ETC DIR"
        LOG.error(f"Auto list from {origin} has interfaces that have no or invalid "
                  f"config: {', '.join(invalid_auto)}")
    return valid_auto


def build_config(auto, ifaces, is_from_puppet):
    valid_auto = parse_auto_list(auto, ifaces, is_from_puppet)
    ifaces_types, dependencies = get_types_and_dependencies(ifaces)
    return {"auto": set(valid_auto),
            "ifaces": ifaces,
            "ifaces_types": ifaces_types,
            "dependencies": dependencies}


def parse_auto_file():
    path = get_auto_path()
    if not os.path.isfile(path):
        LOG.info(f"Auto file not found: '{path}'")
        return []
    lines = read_file_lines(path)
    auto, _ = StanzaParser.ParseLines(lines)
    return auto


def get_auto_path():
    return os.path.join(ETC_DIR, "auto")


def get_ifcfg_path(iface):
    return os.path.join(ETC_DIR, CFG_PREFIX + iface)


def parse_ifcfg_files(ifaces):
    iface_configs = dict()
    for iface in ifaces:
        iface_configs[iface] = parse_ifcfg_file(iface)
    return iface_configs


def parse_ifcfg_file(iface):
    path = get_ifcfg_path(iface)
    if not os.path.isfile(path):
        LOG.warning(f"Interface config file not found: '{path}'")
        return dict()
    lines = read_file_lines(path)
    _, ifaces = StanzaParser.ParseLines(lines)
    if len(ifaces) == 0:
        LOG.warning(f"No interface config found in '{path}'")
        return dict()
    if (ifconfig := ifaces.get(iface, None)) is None:
        LOG.warning(f"Config for interface '{iface}' not found in '{path}'. Instead, file has "
                    f"config(s) for the following interface(s): {' '.join(sorted(ifaces.keys()))}")
        return dict()
    if len(ifaces) > 1:
        LOG.warning(f"Multiple interface configs found in '{path}': "
                    f"{' '.join(sorted(ifaces.keys()))}")
    return ifconfig


def get_types_and_dependencies(iface_configs):
    ifaces_types = dict()
    dependencies = dict()

    def set_type(iface, iftype):
        ifaces_types[iface] = iftype

    def add_dependent(iface, dependent):
        entry = dependencies.setdefault(iface, set())
        entry.add(dependent)

    for iface, config in iface_configs.items():
        if is_label(iface):
            set_type(iface, LABEL)
            parent = get_base_iface(iface)
            add_dependent(parent, iface)
        elif iface == "lo":
            set_type(iface, LO)
        elif vlan_attribs := get_vlan_attributes(iface, config):
            set_type(iface, VLAN)
            add_dependent(vlan_attribs[0], iface)
        elif slaves := config.get("bond-slaves", None):
            set_type(iface, BONDING)
            for slave in slaves.split():
                add_dependent(slave, iface)
        elif master := config.get("bond-master", None):
            set_type(iface, SLAVE)
            add_dependent(iface, master)
        else:
            set_type(iface, ETH)

    return ifaces_types, dependencies


def get_vlan_attributes(iface, config):
    '''Returns (vlan-raw-device, vlan-id) if iface is VLAN, else None'''
    if result := re.search(R"^vlan([0-9]+)$", iface):
        if raw_dev := config.get("vlan-raw-device", None):
            return raw_dev, int(result.group(1))
        LOG.warning("vlan-raw-device property is empty or not specified for "
                    f"interface {iface}, so it will not be considered as a valid VLAN")
        return None
    if result := re.search(R"^(.*)\.([0-9]+)$", iface):
        return result.group(1), int(result.group(2))
    if preup := config.get("pre-up", None):
        if result := re.search(R"ip\s+link\s+add\s+link\s+(\S+)\s+name\s+\S+\s+type"
                               R"\s+vlan\s+id\s+(\d+)", preup):
            return result.group(1), int(result.group(2))
    return None


def compare_configs(new_config, current_config):
    added = new_config["auto"].difference(current_config["auto"])
    if added:
        LOG.info(f"Added interfaces: {' '.join(sorted(added))}")
    removed = current_config["auto"].difference(new_config["auto"])
    if removed:
        LOG.info(f"Removed interfaces: {' '.join(sorted(removed))}")
    modified = get_modified_ifaces(new_config, current_config)
    if modified:
        LOG.info(f"Modified interfaces: {' '.join(sorted(modified))}")
    return {"added": added, "removed": removed, "modified": modified}


def get_modified_ifaces(new_config, current_config):
    modified = set()
    new_ifaces = new_config["ifaces"]
    current_ifaces = current_config["ifaces"]
    for iface, new_if_config in new_ifaces.items():
        current_if_config = current_ifaces.get(iface, None)
        if not current_if_config:
            continue
        if is_iface_modified(iface, new_if_config, current_if_config):
            modified.add(iface)
    return modified


def is_iface_modified(iface, new, current):
    filtered_new = {p for p in new.keys() if p in PROPERTY_SORT_POS}
    filtered_current = {p for p in current.keys() if p in PROPERTY_SORT_POS}
    removed_props = filtered_current.difference(filtered_new)
    added_props = filtered_new.difference(filtered_current)
    modified_props = [p for p in filtered_new.intersection(filtered_current)
                      if new[p] != current[p]]
    if not removed_props and not added_props and not modified_props:
        return False
    text = f"Differences found for interface {iface}:"
    if removed_props:
        text += "\n    Removed properties:"
        for prop in sort_properties(list(removed_props)):
            text += f"\n        {prop} {current[prop]}"
    if added_props:
        text += "\n    Added properties:"
        for prop in sort_properties(list(added_props)):
            text += f"\n        {prop} {new[prop]}"
    if modified_props:
        text += "\n    Modified properties:"
        for prop in sort_properties(list(modified_props)):
            text += f"\n        '{prop}' went from '{current[prop]}' to '{new[prop]}'"
    LOG.info(text)
    return True


def get_dependent_list(config, ifaces):
    auto = config["auto"]
    dep_map = config["dependencies"]
    covered = set()

    def add_dependent(iface):
        if iface in covered or iface not in auto:
            return
        covered.add(iface)
        dependents = dep_map.get(iface, None)
        if not dependents:
            return
        for dependent in dependents:
            add_dependent(dependent)

    for iface in ifaces:
        add_dependent(iface)

    return covered


def get_down_list(current_config, comparison):
    base_set = comparison["modified"].union(comparison["removed"])
    dependents = get_dependent_list(current_config, base_set)
    return base_set.union(dependents)


def get_up_list(new_config, comparison):
    base_set = comparison["modified"].union(comparison["added"])
    missing_set = get_missing_list(new_config, base_set)
    up_set = base_set.union(missing_set)
    dependents = get_dependent_list(new_config, up_set)
    return up_set.union(dependents)


def get_missing_list(config, base_set):
    ifaces_types = config["ifaces_types"]
    types = {ETH, BONDING, VLAN}
    ifaces = {i for i in config["auto"].difference(base_set) if ifaces_types[i] in types}
    out_set = set()
    for iface in ifaces:
        if is_iface_missing_or_down(iface):
            LOG.info(f"Interface {iface} is missing or down, adding to up list")
            out_set.add(iface)
    return out_set


def get_updated_ifaces(new_config, up_list):
    ifaces_types = new_config["ifaces_types"]
    types = {ETH, VLAN, BONDING, LO}
    updated = set()
    for iface in up_list:
        if ifaces_types[iface] == LABEL:
            updated.add(get_base_iface(iface))
        elif ifaces_types[iface] in types:
            updated.add(iface)
    return updated


def sort_ifaces_by_type(config, ifaces, type_order):
    ifaces_types = config["ifaces_types"]
    ifaces_by_type = dict()
    for iface in ifaces:
        iftype = ifaces_types[iface]
        iface_list = ifaces_by_type.setdefault(iftype, [])
        iface_list.append(iface)
    sorted_ifaces = []
    for iftype in type_order:
        if iface_list := ifaces_by_type.get(iftype, None):
            iface_list.sort()
            sorted_ifaces.extend(iface_list)
    return sorted_ifaces


def set_ifaces_down(config, ifaces):
    sorted_ifaces = sort_ifaces_by_type(config, ifaces, DOWN_ORDER)
    for iface in sorted_ifaces:
        set_iface_down(iface)


def format_stdout(stdout):
    cln_stdout = stdout.strip()
    return f"\n{cln_stdout}" if "\n" in cln_stdout else f" '{cln_stdout}'"


def set_iface_down(iface):
    LOG.info(f"Bringing {iface} down")

    ifstate_path = IFSTATE_BASE_PATH + iface
    if os.path.isfile(ifstate_path) and read_file_text(ifstate_path).strip() == iface:
        retcode, stdout = execute_system_cmd(f"/sbin/ifdown -v {iface}")
        if retcode != 0:
            LOG.error(f"Command 'ifdown' failed for interface {iface}:{format_stdout(stdout)}")

    if not is_label(iface):
        devlink_path = DEVLINK_BASE_PATH + iface
        if os.path.islink(devlink_path):
            retcode, stdout = execute_system_cmd(f"/usr/sbin/ip link set down dev {iface}")
            if retcode != 0:
                LOG.error(f"Command 'ip link set down' failed for "
                          f"interface {iface}:{format_stdout(stdout)}")
            retcode, stdout = execute_system_cmd(f"/usr/sbin/ip addr flush dev {iface}")
            if retcode != 0:
                LOG.error(f"Command 'ip addr flush' failed for interface {iface}:"
                          f"{format_stdout(stdout)}")


def set_ifaces_up(config, ifaces):
    sorted_ifaces = sort_ifaces_by_type(config, ifaces, UP_ORDER)
    for iface in sorted_ifaces:
        set_iface_up(iface)


def set_iface_up(iface):
    LOG.info(f"Bringing {iface} up")
    retcode, stdout = execute_system_cmd(f"/sbin/ifup -v {iface}")
    if retcode != 0:
        LOG.error(f"Command 'ifup' failed for interface {iface}: {format_stdout(stdout)}")
    return retcode


def update_files(new_config):
    for iface, iface_config in new_config["ifaces"].items():
        write_iface_config_file(iface, iface_config)
    write_auto_file(new_config["auto"])


def remove_iface_config_files(comparison):
    for to_remove in comparison["removed"]:
        remove_iface_config_file(to_remove)


def path_exists(path):
    return os.path.exists(path)


def remove_iface_config_file(iface):
    path = get_ifcfg_path(iface)
    if path_exists(path):
        LOG.info(f"Removing {path}")
        try:
            os.remove(path)
        except OSError as e:
            LOG.error(f"Failed to remove {path}: {e}")
    else:
        LOG.info(f"File {path} does not exist, no need to remove")


def write_iface_config_file(iface, iface_config):
    lines = get_ifcfg_lines(iface_config)
    path = get_ifcfg_path(iface)
    with open(path, "w") as f:
        f.write("\n".join(lines) + "\n")


def write_auto_file(auto):
    contents = get_header() + "\nauto " + " ".join(auto) + "\n"
    path = get_auto_path()
    with open(path, "w") as f:
        f.write(contents)


def sort_properties(props):
    # Key is position number (from PROPERTY_SORT_POS) with 2 digits followed by property name
    def get_sort_key(v):
        return f"{PROPERTY_SORT_POS.get(v, DEFAULT_POS):02d}{v}"
    props.sort(key=get_sort_key)
    return props


def get_ifcfg_lines(iface_config):
    props = list(iface_config.keys())
    sort_properties(props)
    lines = [get_header()]
    for prop in props:
        lines.append(iface_config[prop] if prop == "allow-" else prop + " " + iface_config[prop])
    return lines


def get_header():
    dt = datetime.now().astimezone()
    return dt.strftime("# HEADER: Last generated at: %Y-%m-%d %H:%M:%S %z")


def get_route_entries(files):
    entries = []
    for file in files:
        if os.path.isfile(file):
            lines = read_file_lines(file)
            entries.extend(get_route_entries_from_lines(lines, file))
    return entries


def get_route_entries_from_lines(lines, file):
    routes = []
    for line in lines:
        clean_line = line.strip()
        if len(clean_line) > 0 and not clean_line.startswith("#"):
            verbs = clean_line.split()
            if len(verbs) >= 4:
                routes.append(' '.join(verbs))
            else:
                LOG.warning(f"Invalid route in file '{file}', must have at least 4 "
                            f"parameters, {len(verbs)} found: '{clean_line}'")
    return routes


def get_route_iface(route):
    return route.split()[3]


def create_route_obj_from_entry(route_entry):
    verbs = route_entry.split()
    route_obj = {"network": verbs[0],
                 "netmask": verbs[1],
                 "nexthop": verbs[2],
                 "ifname": verbs[3]}
    if len(verbs) > 4:
        route_obj["metric"] = verbs[5]
    return route_obj


def get_prefix_length(netmask):
    try:
        addr = IPAddress(netmask)
        if addr.is_netmask():
            return addr.netmask_bits()
    except AddrFormatError:
        pass
    raise InvalidNetmaskError(f"Failed to get prefix length, invalid netmask: '{netmask}'")


def get_linux_network(route):
    network = route["network"]
    if network == "default":
        return "default"
    prefixlen = get_prefix_length(route["netmask"])
    return f"{network}/{prefixlen}"


def remove_route_entry_from_kernel(route_entry):
    route = create_route_obj_from_entry(route_entry)
    try:
        remove_route_from_kernel(route)
    except InvalidNetmaskError as e:
        LOG.error(f"Failed to remove route entry '{route_entry}' from the kernel: {e}")


def remove_route_from_kernel(route):
    description = get_route_description(route)
    LOG.info(f"Removing route: {description}")
    retcode, stdout = execute_system_cmd(f"/usr/sbin/ip route del {description}")
    if retcode != 0:
        LOG.error(f"Failed removing route {description}:{format_stdout(stdout)}")


def add_route_entry_to_kernel(route_entry):
    route = create_route_obj_from_entry(route_entry)
    try:
        add_route_to_kernel(route)
    except InvalidNetmaskError as e:
        LOG.error(f"Failed to add route entry '{route_entry}' to the kernel: {e}")


def get_route_description(route, full=True):
    linux_network = get_linux_network(route)
    gateway = f" via {route['nexthop']} dev {route['ifname']}" if full else ""
    descr = f"{linux_network}{gateway}"
    if metric := route.get("metric", None):
        descr += f" metric {metric}"
    return descr


def add_route_to_kernel(route):
    prot = "-6 " if ":" in route["nexthop"] else ""
    description = get_route_description(route)
    LOG.info(f"Adding route: {description}")
    retcode, stdout = execute_system_cmd(f"/usr/sbin/ip {prot}route show {description}")
    if retcode == 0 and route["network"] in stdout:
        LOG.info("Route already exists, skipping")
    else:
        short_descr = get_route_description(route, full=False)
        retcode, stdout = execute_system_cmd(f"/usr/sbin/ip {prot}route show {short_descr}")
        if retcode == 0 and route["network"] in stdout:
            LOG.info(f"Route to specified network already exists, replacing: {stdout.strip()}")
            retcode, stdout = execute_system_cmd(f"/usr/sbin/ip route replace {description}")
            if retcode != 0:
                LOG.error(f"Failed replacing route {description}:{format_stdout(stdout)}")
        else:
            retcode, stdout = execute_system_cmd(f"/usr/sbin/ip route add {description}")
            if retcode != 0:
                LOG.error(f"Failed adding route {description}:{format_stdout(stdout)}")


def acquire_sysinv_agent_lock():
    LOG.info("Acquiring lock to synchronize with sysinv-agent audit")
    lock_file_fd = os.open(SYSINV_LOCK_FILE, os.O_CREAT | os.O_RDONLY)
    return acquire_file_lock(lock_file_fd, fcntl.LOCK_EX | fcntl.LOCK_NB, 5, 5)


def release_sysinv_agent_lock(lockfd):
    if lockfd:
        LOG.info("Releasing lock")
        release_file_lock(lockfd)
        os.close(lockfd)


def acquire_file_lock(lockfd, operation, max_retry, wait_interval):
    count = 1
    while count <= max_retry:
        try:
            fcntl.flock(lockfd, operation)
            LOG.info("Successfully acquired lock (fd={})".format(lockfd))
            return lockfd
        except IOError as e:
            # raise on unrelated IOErrors
            if e.errno != errno.EAGAIN:
                raise
            LOG.info("Could not acquire lock({}): {} ({}/{}), will retry".format(
                lockfd, str(e), count, max_retry))
            time.sleep(wait_interval)
            count += 1
    LOG.error("Failed to acquire lock (fd={}). Stopped trying.".format(lockfd))
    sys.exit(1)


def release_file_lock(lockfd):
    if lockfd:
        fcntl.flock(lockfd, fcntl.LOCK_UN)


def is_upgrade():
    return os.path.isfile(UPGRADE_FILE)


def update_interfaces():
    new_config = get_new_config()

    auto = new_config["auto"]
    if len(auto) == 0 or (len(auto) == 1 and next(iter(auto)) == "lo"):
        LOG.info(f"Generated {PUPPET_FILE} with empty configuration: '{' '.join(auto)}', exiting")
        return None

    disable_pxeboot_interface()

    if is_upgrade():
        LOG.info("Upgrade bootstrap is in execution")
        return update_ifaces_online(new_config)

    return update_ifaces_ifupdown(new_config)


def disable_pxeboot_interface():
    path = get_ifcfg_path("pxeboot")
    if not os.path.isfile(path):
        return

    lines = read_file_lines(path)
    _, ifaces = StanzaParser.ParseLines(lines)
    if len(ifaces) == 0:
        LOG.info(f"Pxeboot install config file '{path}' has no valid interface config, skipping")
        return

    for iface in ifaces.keys():
        LOG.info(f"Turn off pxeboot install config for {iface}, will be turned on later")
        set_iface_down(iface)

    LOG.info("Remove ifcfg-pxeboot, left from kickstart install phase")
    remove_iface_config_file("pxeboot")


def update_ifaces_ifupdown(new_config):
    current_config = get_current_config()
    comparison = compare_configs(new_config, current_config)
    down_list = get_down_list(current_config, comparison)
    up_list = get_up_list(new_config, comparison)

    lock = acquire_sysinv_agent_lock() if down_list or up_list else None
    try:
        set_ifaces_down(current_config, down_list)
        remove_iface_config_files(comparison)
        update_files(new_config)
        set_ifaces_up(new_config, up_list)
    finally:
        release_sysinv_agent_lock(lock)

    return get_updated_ifaces(new_config, up_list)


def update_ifaces_online(config):
    sorted_ifaces = sort_ifaces_by_type(config, config["auto"], ONLINE_ORDER)
    if not sorted_ifaces:
        return set()
    update_files(config)
    for iface in sorted_ifaces:
        LOG.info(f"Configuring interface {iface}")
        ensure_iface_configured(iface, config["ifaces"][iface])
    return get_updated_ifaces(config, sorted_ifaces)


def is_iface_missing_or_down(iface):
    path = f"{DEVLINK_BASE_PATH}{iface}/operstate"
    if os.path.isfile(path):
        state = read_file_text(path)
        if state != "down":
            return False
    return True


def get_iface_address(iface, cfg):
    if address := cfg.get("address", None):
        if "/" not in address:
            if netmask := cfg.get("netmask", None):
                if ":" in address:
                    try:
                        prefixlen = int(netmask)
                    except ValueError:
                        LOG.error(f"Failed to get {iface} interface prefixlen, "
                                  f"invalid value: '{netmask}'")
                        return None
                else:
                    try:
                        prefixlen = get_prefix_length(netmask)
                    except InvalidNetmaskError as e:
                        LOG.error(f"Failed to get {iface} interface netmask: {e}")
                        return None
                return f"{address}/{prefixlen}"
            LOG.error(f"Interface {iface} has address but no netmask")
            return None
    return address


def ensure_iface_configured_label(iface, cfg):
    address = get_iface_address(iface, cfg)
    if not address:
        return
    base_iface = get_base_iface(iface)
    existing = get_link_addresses(base_iface)
    if address in existing:
        LOG.info(f"Link already has address '{address}', no need to set label up")
    else:
        if set_iface_up(iface) == 0:
            return
        add_ip_to_iface(base_iface, address)
    if gateway := cfg.get("gateway", None):
        add_default_route(base_iface, gateway)


def ensure_iface_configured_non_label(iface, cfg):
    if is_iface_missing_or_down(iface):
        LOG.info(f"Interface '{iface}' is missing or down, flushing IPs and bringing up")
        flush_ips(iface)
        if set_iface_up(iface) == 0:
            return
    address = get_iface_address(iface, cfg)
    if not address:
        return
    existing = get_link_addresses(iface)
    if address not in existing:
        add_ip_to_iface(iface, address)
    if gateway := cfg.get("gateway", None):
        add_default_route(iface, gateway)


def ensure_iface_configured(iface, cfg):
    if is_label(iface):
        ensure_iface_configured_label(iface, cfg)
    else:
        ensure_iface_configured_non_label(iface, cfg)


def get_link_addresses(name):
    retcode, stdout = execute_system_cmd(f"/usr/sbin/ip -br addr show dev {name}")
    if retcode == 0:
        verbs = stdout.split()
        return verbs[2:]
    LOG.error(f"Failed to get IP address list from {name}:{format_stdout(stdout)}")
    return None


def add_ip_to_iface(iface, ip):
    LOG.info(f"Adding IP {ip} to interface {iface}")
    existing = get_link_addresses(iface)
    if existing is None:
        return
    if ip in existing:
        LOG.info(f"Interface {iface} already has address {ip}, skipping")
        return
    retcode, stdout = execute_system_cmd(f"/usr/sbin/ip addr add {ip} dev {iface}")
    if retcode != 0:
        LOG.error(f"Failed to add IP address to interface {iface}:{format_stdout(stdout)}")


def add_default_route(iface, gateway):
    route = {"network": "default",
             "nexthop": gateway,
             "ifname": iface}
    add_route_to_kernel(route)


def flush_ips(iface):
    path = DEVLINK_BASE_PATH + iface
    if os.path.islink(path):
        retcode, stdout = execute_system_cmd(f"/usr/sbin/ip addr flush dev {iface}")
        if retcode != 0:
            LOG.error(f"Command 'ip addr flush' failed for interface {iface}:"
                      f"{format_stdout(stdout)}")


def write_routes_file(route_entries):
    lines = [get_header()] + route_entries
    with open(ETC_ROUTES_FILE, "w") as f:
        f.write("\n".join(lines) + "\n")


def update_routes(updated_ifaces=None):
    if updated_ifaces is None:
        updated_ifaces = set()

    new_routes = get_route_entries([PUPPET_ROUTES_FILE, PUPPET_ROUTES6_FILE])
    new_routes_set = set(new_routes)

    current_routes = get_route_entries([ETC_ROUTES_FILE])
    current_routes_set = set(current_routes)

    write_routes_file(new_routes)

    if new_routes_set != current_routes_set:
        LOG.info(f"Differences found between {PUPPET_ROUTES_FILE} and {ETC_ROUTES_FILE}")
        # Remove routes that are currently present and no longer needed, following the order in
        # which they appear in the file
        for route_entry in current_routes:
            if route_entry not in new_routes_set:
                remove_route_entry_from_kernel(route_entry)
    else:
        LOG.info(f"No differences found between {PUPPET_ROUTES_FILE} and {ETC_ROUTES_FILE}")
        if not updated_ifaces:
            return

    for route_entry in new_routes:
        if route_entry not in current_routes_set:
            LOG.info(f"Route not previously present in {ETC_ROUTES_FILE}, adding")
        elif get_route_iface(route_entry) in updated_ifaces:
            LOG.info("Route is associated with and updated interface, adding")
        else:
            continue
        add_route_entry_to_kernel(route_entry)


def check_enrollment_config():
    if not os.path.isfile(SUBCLOUD_ENROLLMENT_FILE) or not os.path.isfile(CLOUD_INIT_FILE):
        return
    LOG.info(f"Enrollment: Parsing file '{CLOUD_INIT_FILE}'")
    lines = read_file_lines(CLOUD_INIT_FILE)
    _, ifaces = StanzaParser.ParseLines(lines)
    ifaces.pop("lo", None)
    if len(ifaces) == 0:
        LOG.warning(f"Enrollment: Could not find any valid interface config in '{CLOUD_INIT_FILE}'")
        return
    ifaces_with_gateway = dict()
    for iface, cfg in ifaces.items():
        if gateway := cfg.get("gateway", None):
            try:
                gateway_ip = IPAddress(gateway)
            except AddrFormatError:
                LOG.warning(f"Enrollment: Invalid gateway address '{gateway}' "
                            f"for interface '{iface}'")
                continue
            ifaces_with_gateway.setdefault(gateway_ip.version, dict())[iface] = cfg
    if len(ifaces_with_gateway) == 0:
        LOG.warning("Enrollment: No interface with gateway address found, skipping")
        return
    for version, iface_cfgs in ifaces_with_gateway.items():
        if len(iface_cfgs) > 1:
            LOG.warning(f"Enrollment: Multiple interfaces with gateway for ipv{version} found: "
                        f"{', '.join(iface_cfgs.keys())}")
        for iface, cfg in iface_cfgs.items():
            LOG.info(f"Enrollment: Configuring interface {iface} with gateway {cfg['gateway']}")
            ensure_iface_configured(iface, cfg)


def main():
    log_format = ('%(asctime)s: [%(process)s]: %(filename)s(%(lineno)s): '
                  '%(levelname)s: %(message)s')
    LOG.basicConfig(filename=LOG_FILE, format=log_format, level=LOG.INFO, datefmt="%FT%T")

    parser = argparse.ArgumentParser(
        prog='Network Configuration Applier',
        description='Applies the network configuration generated by Puppet to the linux kernel'
    )
    parser.add_argument("--routes", action='store_true')
    args = parser.parse_args()

    apply_config(args.routes)
    return 0


if __name__ == "__main__":
    sys.exit(main())

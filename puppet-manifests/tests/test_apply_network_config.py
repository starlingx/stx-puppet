#
# Copyright (c) 2025 Wind River Systems, Inc.
#
# SPDX-License-Identifier: Apache-2.0
#

import mock
import os
import re
import testtools
from netaddr import IPAddress
from netaddr import IPNetwork
from netaddr import AddrFormatError

from tests.filesystem_mock import FilesystemMock
from tests.filesystem_mock import ReadOnlyFileContainer
import src.bin.apply_network_config as anc


class NetworkingMockError(BaseException):
    pass


class NetworkingMock():  # pylint: disable=too-many-instance-attributes,too-many-public-methods
    def __init__(self, fs: FilesystemMock, ifaces: list):
        self._stdout = ''
        self._history = []
        self._etc_changed = True
        self._fs = fs
        self._current_config = None
        self._links = dict()
        self._routes = dict()
        self._next_route_id = 0
        self._allow_multiple_default_gateways = False
        self._dhcp = dict()
        self._add_eth_ifaces(ifaces)
        self._fs.add_listener(anc.ETC_DIR, self._etc_dir_changed)

    def _etc_dir_changed(self):
        self._etc_changed = True

    def _add_eth_ifaces(self, ifaces):
        for iface in ifaces:
            self._add_eth_iface(iface)

    @staticmethod
    def _get_device_path(iface, is_virtual=False):
        if is_virtual:
            return f"/sys/devices/virtual/net/{iface}"
        return f"/sys/devices/pci0000:00/net/{iface}"

    def _add_eth_iface(self, iface):
        phys_path = self._get_device_path(iface)
        self._fs.set_file_contents(phys_path + "/operstate", "down\n")
        self._fs.set_link_contents(anc.DEVLINK_BASE_PATH + iface, phys_path)
        self._links[iface] = {"adm_state": False, "virtual": False,
                              "addresses": set(), "routes": set()}

    def _parse_etc_interfaces(self):
        file_list = self._fs.listdir(anc.ETC_DIR)
        parser = anc.StanzaParser()
        for file in file_list:
            file_contents = self._fs.get_file_contents(anc.ETC_DIR + "/" + file)
            parser.parse_lines(file_contents.split("\n"))
        return parser.get_auto_and_ifaces()

    @staticmethod
    def _decode_iface_config(name, config):
        if anc.is_label(name):
            parent = name.split(":")[0]
            props = {"type": anc.LABEL, "parent": parent}
        elif name == "lo":
            props = {"type": anc.LO}
        elif vlan_attribs := anc.get_vlan_attributes(name, config):
            preup = config.get("pre-up", None)
            add_link_cmd = preup and "ip link add" in preup
            props = {"type": anc.VLAN, "raw_dev": vlan_attribs[0], "vlan_id": vlan_attribs[1],
                     "add_link_cmd": add_link_cmd}
        elif slaves := config.get("bond-slaves", None):
            props = {"type": anc.BONDING, "slaves": slaves.split()}
        elif master := config.get("bond-master", None):
            props = {"type": anc.SLAVE, "master": master}
        else:
            props = {"type": anc.ETH}
        mode = config["iface"].split()[2]
        props["mode"] = mode
        if mode == "static":
            if not (address := config.get("address", None)):
                raise NetworkingMockError(
                    f"Interface '{name}' is set to STATIC but has no address specified")
            if "/" in address:
                props["address"] = IPNetwork(address)
            else:
                if not (netmask := config.get("netmask", None)):
                    raise NetworkingMockError(
                        f"Interface '{name}' is set to STATIC but has no netmask specified")
                props["address"] = IPNetwork(f"{address}/{netmask}")
            if gateway := config.get("gateway", None):
                props["gateway"] = IPAddress(gateway)
        return props

    def _decode_config(self):
        auto, etc_ifaces = self._parse_etc_interfaces()
        decoded_ifaces = dict()
        for iface, config in etc_ifaces.items():
            decoded_ifaces[iface] = self._decode_iface_config(iface, config)
        return auto, decoded_ifaces

    def _update_config(self):
        if not self._etc_changed:
            return
        self._etc_changed = False
        auto, ifaces = self._decode_config()
        self._current_config = {"auto": auto, "ifaces": ifaces}

    def _add_route_line(self, line):
        pieces = line.split()
        if len(pieces) < 4:
            raise NetworkingMockError(f"Invalid route in '{anc.ETC_ROUTES_FILE}' file: '{line}'")
        netmask_ip = IPAddress(pieces[1])
        prefixlen = netmask_ip.netmask_bits()
        network = f"{pieces[0]}/{prefixlen}"
        metric = pieces[5] if len(pieces) > 4 else None
        self._do_ip_route_add(network, pieces[2], pieces[3], metric)

    def _apply_etc_routes(self):
        if not self._fs.isfile(anc.ETC_ROUTES_FILE):
            return
        file_contents = self._fs.get_file_contents(anc.ETC_ROUTES_FILE)
        lines = [line.strip() for line in file_contents.split("\n")]
        for line in lines:
            clean_line = line.strip()
            if clean_line and not clean_line.startswith("#"):
                self._add_route_line(line)

    def apply_auto(self):
        self._reset_stdout()
        self._etc_changed = True
        self._update_config()
        auto = [iface for iface in self._current_config["auto"]
                if self._current_config["ifaces"][iface]["type"] != anc.SLAVE]
        for iface in auto:
            self._do_ifup(iface)
        self._apply_etc_routes()
        return self._stdout

    def reset_history(self):
        self._history = []

    def get_history(self):
        return self._history

    def enable_dhcp(self, iface_addresses):
        self._dhcp = iface_addresses

    def _add_history(self, command, *args):
        self._history.append((command, *args))

    def _reset_stdout(self):
        self._stdout = ''

    def _print_stdout(self, msg):
        self._stdout += msg + "\n"

    def _is_up(self, iface):
        state_file_path = anc.IFSTATE_BASE_PATH + iface
        if self._fs.isfile(state_file_path):
            data = self._fs.get_file_contents(state_file_path)
            return data == iface
        return False

    def _set_link_state(self, iface, link, state):
        if link["adm_state"] == state:
            return
        link["adm_state"] = state
        operstate_path = self._get_device_path(iface, link["virtual"]) + "/operstate"
        value = "up\n" if state else "down\n"
        self._fs.set_file_contents(operstate_path, value)

    def _create_virtual_link(self, name):
        if link := self._links.get(name, None):
            self._print_stdout("RTNETLINK answers: File exists")
            return link, 1
        phys_path = self._get_device_path(name, True)
        self._fs.set_file_contents(phys_path + "/operstate", "down\n")
        self._fs.set_link_contents(anc.DEVLINK_BASE_PATH + name, phys_path)
        link = {"adm_state": False, "virtual": True, "addresses": set(), "routes": set()}
        self._links[name] = link
        return link, 0

    def _remove_virtual_link(self, name):
        link, retcode = self._get_link(name)
        if retcode != 0:
            return 1
        for route_id in link["routes"]:
            self._routes.pop(route_id)
        if deps := link.get("deps", None):
            for dep in deps:
                self._remove_virtual_link(dep)
        del self._links[name]
        self._fs.delete(anc.DEVLINK_BASE_PATH + name)
        self._fs.delete(self._get_device_path(name, True))
        return 0

    def _get_link(self, name):
        link = self._links.get(name, None)
        if link:
            return link, 0
        self._print_stdout(f'Cannot find device "{name}"')
        return None, 1

    def _get_link_for_ip_cmd(self, name):
        link = self._links.get(name, None)
        if link:
            return link, 0
        self._print_stdout(f'Device "{name}" does not exist.')
        return None, 1

    def _enslave_iface(self, iface, master, master_failed):
        if master_failed or not (link := self._links.get(iface, None)):
            self._print_stdout(f"Failed to enslave {iface} to {master}. "
                               f"Is {master} ready and a bonding interface ?")
            return None, 1
        link["master"] = master
        self._set_link_state(iface, link, True)
        return link, 0

    def _unenslave_iface(self, iface):
        if not (link := self._links.get(iface, None)):
            return 1
        link.pop("master", None)
        self._set_link_state(iface, link, False)
        return 0

    def _add_address(self, iface, config, link):
        mode = config["mode"]
        if mode == "static":
            address = config["address"]
            if address in link["addresses"]:
                self._print_stdout(f"Error: ipv{address.version}: Address already assigned.")
                return 1
            link["addresses"].add(address)
            if gateway := config.get("gateway", None):
                self._add_default_gateway(iface, link, gateway)
        elif mode == "dhcp":
            if address := self._dhcp.get(iface, None):
                if address in link["addresses"]:
                    raise NetworkingMockError("DHCP lease address already assigned to link "
                                              f"{iface}: {address}")
                link["addresses"].add(address)
        return 0

    def _remove_routes_associated_to_address(self, link, address):
        to_remove = []
        for route_id in link["routes"]:
            route = self._routes[route_id]
            if route["via"] in address:
                to_remove.append(route_id)
        for route_id in to_remove:
            self._routes.pop(route_id)
            link["routes"].remove(route_id)

    def _remove_address(self, iface, config, link):
        mode = config["mode"]
        address = None
        if mode == "static":
            address = config["address"]
        elif mode == "dhcp":
            address = self._dhcp.get(iface, None)
        if address:
            if address not in link["addresses"]:
                self._print_stdout(f"Error: ipv{address.version}: Address not found.")
                return 1
            link["addresses"].remove(address)
            self._remove_routes_associated_to_address(link, address)
        return 0

    def _add_default_gateway(self, ifname, link, gateway):
        net = '0.0.0.0/0' if gateway.version == 4 else '::0/0'
        route_filter = self._get_route_filter(net, None, None, None)
        existing = self._find_routes(route_filter, True)
        if existing:
            if not self._allow_multiple_default_gateways:
                raise NetworkingMockError("Trying to create default route from ifup for "
                                          f"interface '{ifname}', default route already exists")
        route_obj = self._get_route_obj(net, gateway, ifname, None)
        retcode = self._check_can_add_route(route_obj, link)
        if retcode != 0:
            return retcode
        for route_id in existing.keys():
            self._remove_route(route_id)
        self._add_route(route_obj, link)
        return 0

    def _set_lo_up(self, iface, config):
        return self._set_eth_up(iface, config)

    def _set_lo_down(self, iface, config):
        return self._set_eth_down(iface, config)

    def _set_eth_up(self, iface, config):
        link, retcode = self._get_link(iface)
        if retcode != 0:
            return 1
        self._set_link_state(iface, link, True)
        return self._add_address(iface, config, link)

    def _set_eth_down(self, iface, config):
        link, retcode = self._get_link(iface)
        if retcode != 0:
            return 0
        self._set_link_state(iface, link, False)
        self._remove_address(iface, config, link)
        return 0

    def _set_slave_up(self, iface, config):  # pylint: disable=no-self-use,unused-argument
        raise NetworkingMockError(
            f"ifup is not supposed to be called for slave interfaces: {iface}")

    def _set_slave_down(self, iface, config):  # pylint: disable=no-self-use,unused-argument
        raise NetworkingMockError(
            f"ifdown is not supposed to be called for slave interfaces: {iface}")

    def _set_bonding_up(self, iface, config):
        link, retcode = self._create_virtual_link(iface)
        if retcode != 0:
            self._print_stdout("/etc/network/if-pre-up.d/ifenslave: line 39: /sys/class/net/"
                               f"{iface}/bonding/miimon: No such file or directory")
            self._print_stdout("/etc/network/if-pre-up.d/ifenslave: line 39: /sys/class/net/"
                               f"{iface}/bonding/mode: No such file or directory")
        link["slaves"] = config["slaves"]
        for slave in config["slaves"]:
            self._enslave_iface(slave, iface, retcode != 0)
        self._set_link_state(iface, link, True)
        return self._add_address(iface, config, link)

    def _set_bonding_down(self, iface, config):
        link, retcode = self._get_link(iface)
        if retcode != 0:
            return 0
        self._remove_address(iface, config, link)
        self._set_link_state(iface, link, False)
        for slave in config["slaves"]:
            self._unenslave_iface(slave)
        self._remove_virtual_link(iface)
        return 0

    def _set_vlan_up(self, iface, config):
        raw_dev = config["raw_dev"]
        if config["add_link_cmd"]:
            link, retcode = self._get_link(raw_dev)
            if retcode != 0:
                return retcode
        else:
            if raw_dev not in self._links:
                self._print_stdout(f'cat: /sys/class/net/{raw_dev}/mtu: No such file or directory')
                self._print_stdout(f'Device "{raw_dev}" does not exist.')
                self._print_stdout(f'{raw_dev} does not exist, unable to create {iface}')
                self._print_stdout('run-parts: /etc/network/if-pre-up.d/vlan exited with '
                                   'return code 1')
                return 1
        link, retcode = self._create_virtual_link(iface)
        if retcode != 0:
            return 1
        link["raw_dev"] = raw_dev
        link["vlan_id"] = config["vlan_id"]
        deps = self._links[raw_dev].setdefault("deps", list())
        deps.append(iface)
        self._set_link_state(iface, link, True)
        return self._add_address(iface, config, link)

    def _set_vlan_down(self, iface, config):
        link, retcode = self._get_link(iface)
        if retcode != 0:
            return 0
        self._remove_address(iface, config, link)
        self._set_link_state(iface, link, False)
        self._remove_virtual_link(iface)
        return 0

    def _set_label_up(self, iface, config):  # pylint: disable=unused-argument
        parent = config["parent"]
        link, retcode = self._get_link(parent)
        if retcode != 0:
            return retcode
        return self._add_address(parent, config, link)

    def _set_label_down(self, iface, config):  # pylint: disable=unused-argument
        parent = config["parent"]
        link, retcode = self._get_link(parent)
        if retcode == 0:
            self._remove_address(parent, config, link)
        return 0

    def _set_ifstate(self, iface, state):
        path = anc.IFSTATE_BASE_PATH + iface
        contents = iface if state else ''
        self._fs.set_file_contents(path, contents)

    _UP_FUNCTIONS = {anc.LO: _set_lo_up,
                     anc.ETH: _set_eth_up,
                     anc.SLAVE: _set_slave_up,
                     anc.BONDING: _set_bonding_up,
                     anc.VLAN: _set_vlan_up,
                     anc.LABEL: _set_label_up}

    _DOWN_FUNCTIONS = {anc.LO: _set_lo_down,
                       anc.ETH: _set_eth_down,
                       anc.SLAVE: _set_slave_down,
                       anc.BONDING: _set_bonding_down,
                       anc.VLAN: _set_vlan_down,
                       anc.LABEL: _set_label_down}

    def _get_iface_config(self, iface):
        self._update_config()
        if not (config := self._current_config["ifaces"].get(iface, None)):
            self._print_stdout(f"ifup: unknown interface {iface}")
            return None, 1
        return config, 0

    def _run_command(self, fxn, *args, **kwargs):
        self._reset_stdout()
        retcode = fxn(*args, **kwargs)
        return retcode, self._stdout

    def _do_ifup(self, iface):
        config, retcode = self._get_iface_config(iface)
        if retcode != 0:
            return 1
        if self._is_up(iface):
            self._print_stdout(f"ifup: interface {iface} already configured")
            return 0
        fxn = self._UP_FUNCTIONS[config["type"]]
        retcode = fxn(self, iface, config)
        if retcode == 0:
            self._set_ifstate(iface, True)
        else:
            self._print_stdout(f"ifup: failed to bring up {iface}")
        return retcode

    def ifup(self, iface):
        self._add_history("ifup", iface)
        return self._run_command(self._do_ifup, iface)

    def _do_ifdown(self, iface):
        config, retcode = self._get_iface_config(iface)
        if retcode != 0:
            return 1
        if not self._is_up(iface):
            self._print_stdout(f"ifdown: interface {iface} not configured")
            return 0
        fxn = self._DOWN_FUNCTIONS[config["type"]]
        retcode = fxn(self, iface, config)
        if retcode == 0:
            self._set_ifstate(iface, False)
        return retcode

    def ifdown(self, iface):
        self._add_history("ifdown", iface)
        return self._run_command(self._do_ifdown, iface)

    def ip_addr_show(self):
        self._add_history("ip_addr_show")
        return 0, "< 'ip addr show' output placeholder >\n"

    def _do_ip_addr_show_dev(self, iface):
        link, retcode = self._get_link_for_ip_cmd(iface)
        if retcode != 0:
            return retcode
        name = iface
        if raw_dev := link.get("raw_dev", None):
            name += "@" + raw_dev
        state = "UP" if link["adm_state"] else "DOWN"
        addresses = [str(addr) for addr in sorted(list(link["addresses"]))]
        text = f"{name:<16} {state:<14} {' '.join(addresses)}"
        self._print_stdout(text)
        return 0

    def ip_addr_show_dev(self, iface):
        self._add_history("ip_addr_show_dev", iface)
        return self._run_command(self._do_ip_addr_show_dev, iface)

    def _do_ip_addr_show_addr(self, addr):
        try:
            target = IPNetwork(addr)
        except AddrFormatError:
            self._print_stdout(f'Error: any valid prefix is expected rather than "{addr}".')
            return 1

        idx = 1
        for ifname, link in self._links.items():
            for link_addr in link["addresses"]:
                if link_addr == target:
                    family = "inet6" if target.version == 6 else "inet"
                    self._print_stdout(f"{idx}: {ifname}    {family} {addr}")
                    idx += 1
        return 0

    def ip_addr_show_addr(self, addr):
        self._add_history("ip_addr_show_addr", addr)
        return self._run_command(self._do_ip_addr_show_addr, addr)

    def ip_addr_show_ip(self, addr):
        self._add_history("ip_addr_show_ip", addr)
        return self.ip_addr_show_addr(addr)

    def _do_ip_addr_add(self, addr, iface):
        link, retcode = self._get_link_for_ip_cmd(iface)
        if retcode != 0:
            return retcode
        try:
            ip = IPNetwork(addr)
        except AddrFormatError:
            self._print_stdout(f'Error: any valid prefix is expected rather than "{addr}".')
            return 1
        if ip in link["addresses"]:
            self._print_stdout(f"Error: ipv{ip.version}: Address already assigned.")
            return 1
        link["addresses"].add(ip)
        return 0

    def ip_addr_add(self, addr, iface):
        self._add_history("ip_addr_add", addr, iface)
        return self._run_command(self._do_ip_addr_add, addr, iface)

    def _do_ip_addr_flush(self, iface):
        link, retcode = self._get_link_for_ip_cmd(iface)
        if retcode != 0:
            return retcode
        for address in link["addresses"]:
            self._remove_routes_associated_to_address(link, address)
        link["addresses"].clear()
        return 0

    def ip_addr_flush(self, iface):
        self._add_history("ip_addr_flush", iface)
        return self._run_command(self._do_ip_addr_flush, iface)

    def _do_ip_link_set_updown(self, iface, state):
        link, retcode = self._get_link_for_ip_cmd(iface)
        if retcode != 0:
            return retcode
        self._set_link_state(iface, link, state)
        return 0

    def ip_link_set_down(self, iface):
        self._add_history("ip_link_set_down", iface)
        return self._run_command(self._do_ip_link_set_updown, iface, False)

    def ip_link_set_up(self, iface):
        self._add_history("ip_link_set_up", iface)
        return self._run_command(self._do_ip_link_set_updown, iface, True)

    def ip_route_show_all(self, prot):
        self._add_history("ip_route_show_all", prot)
        return 0, "< 'ip route show all' output placeholder >\n"

    def ip_neigh_show_all(self, not_used):
        self._add_history("ip_neigh_show_all", not_used)
        return 0, "< 'ip neigh show all' output placeholder >\n"

    def get_hostname(self, not_used):
        self._add_history("get_hostname", not_used)
        return 0, "< 'hostname' output placeholder >\n"

    @staticmethod
    def _sort_routes(routes):
        return [routes[k] for k in sorted(routes.keys())]

    def _print_route(self, route, route_filter=None):
        net = route["net"]
        if net.value == 0 and net.prefixlen == 0:
            pieces = ["default"]
        else:
            pieces = [f"{net.ip}/{net.prefixlen}"]
        if not route_filter or not route_filter["via"]:
            pieces.append(f'via {route["via"]}')
        if not route_filter or not route_filter["dev"]:
            pieces.append(f'dev {route["dev"]}')
        if not route_filter or not route_filter["metric"]:
            if (metric := route["metric"]) != 0 or net.version != 4:
                pieces.append(f'metric {metric}')
        if net.version == 6:
            pieces.append("pref medium")
        self._print_stdout(" ".join(pieces))

    def _do_ip_route_show(self, prot, network, gateway, dev, metric):
        # pylint: disable=too-many-arguments
        ip_version = 6 if prot == "-6" else 4
        filter_filter = self._get_route_filter(network, gateway, dev, metric, ip_version)
        routes = self._find_routes(filter_filter)
        for route in self._sort_routes(routes):
            self._print_route(route, filter_filter)
        return 0

    def ip_route_show(self, prot, network, gateway, dev, metric):
        # pylint: disable=too-many-arguments
        self._add_history("ip_route_show", prot, network, gateway, dev, metric)
        return self._run_command(self._do_ip_route_show, prot, network, gateway, dev, metric)

    @staticmethod
    def _get_route_obj(network, gateway, dev, metric):
        gateway_ip = IPAddress(gateway)
        if network == "default":
            net = IPNetwork('0.0.0.0/0') if gateway_ip.version == 4 else IPNetwork('::0/0')
        else:
            net = IPNetwork(network)
        if metric:
            metric_val = int(metric)
            if gateway_ip.version == 6 and metric_val == 0:
                metric_val = 1024
        else:
            metric_val = 0 if gateway_ip.version == 4 else 1024
        return {"net": net, "via": gateway_ip, "dev": dev, "metric": metric_val}

    def _add_route(self, route_obj, link):
        route_id = self._next_route_id
        self._next_route_id += 1
        self._routes[route_id] = route_obj
        link["routes"].add(route_id)

    def _remove_route(self, route_id):
        route_obj = self._routes.pop(route_id)
        self._links[route_obj["dev"]]["routes"].remove(route_id)

    @staticmethod
    def _get_route_filter(network, gateway, dev, metric, version=None):
        gateway_ip = IPAddress(gateway) if gateway else None
        if network == "default":
            if (version and version == 6) or (gateway_ip and gateway_ip.version == 6):
                net = IPNetwork('::0/0')
            else:
                net = IPNetwork('0.0.0.0/0')
        else:
            net = IPNetwork(network) if network else None
        metric_val = int(metric) if metric else None
        return {"net": net, "via": gateway_ip, "dev": dev,
                "metric": metric_val, "version": version}

    @staticmethod
    def _route_matches(route_filter, route):
        filter_net = route_filter["net"]
        route_net = route["net"]
        version = route_filter["version"]
        if version and route_net.version != version:
            return False
        if route_net != filter_net:
            return False
        for prop in ["via", "dev", "metric"]:
            if not (val := route_filter[prop]):
                continue
            if route[prop] != val:
                return False
        return True

    def _find_routes(self, route_filter, single=False):
        routes = dict()
        for route_id, route in self._routes.items():
            if self._route_matches(route_filter, route):
                routes[route_id] = route
                if single:
                    break
        return routes

    def _route_exists(self, network, gateway, dev, metric):
        route_filter = self._get_route_filter(network, gateway, dev, metric)
        return bool(self._find_routes(route_filter, True))

    def _erase_routes_by_filter(self, route_filter):
        to_remove = []
        for route_id, route in self._routes.items():
            if self._route_matches(route_filter, route):
                to_remove.append(route_id)
        for route_id in to_remove:
            self._remove_route(route_id)

    def _check_can_add_route(self, route_obj, link):
        gateway = route_obj["via"]
        for addr in link["addresses"]:
            if gateway in addr:
                return 0
        self._print_stdout("RTNETLINK answers: No route to host")
        return 2

    def _do_ip_route_add(self, network, gateway, dev, metric):
        link, retcode = self._get_link(dev)
        if retcode != 0:
            return retcode
        if self._route_exists(network, gateway, dev, metric):
            self._print_stdout("RTNETLINK answers: File exists")
            return 2
        route_obj = self._get_route_obj(network, gateway, dev, metric)
        retcode = self._check_can_add_route(route_obj, link)
        if retcode != 0:
            return retcode
        self._add_route(route_obj, link)
        return 0

    def ip_route_add(self, network, gateway, dev, metric):
        self._add_history("ip_route_add", network, gateway, dev, metric)
        return self._run_command(self._do_ip_route_add, network, gateway, dev, metric)

    def _do_ip_route_replace(self, network, gateway, dev, metric):
        link, retcode = self._get_link(dev)
        if retcode != 0:
            return retcode
        ip_version = IPAddress(gateway).version
        route_obj = self._get_route_obj(network, gateway, dev, metric)
        retcode = self._check_can_add_route(route_obj, link)
        if retcode != 0:
            return retcode
        route_filter = self._get_route_filter(network, None, None, metric, ip_version)
        self._erase_routes_by_filter(route_filter)
        self._add_route(route_obj, link)
        return 0

    def ip_route_replace(self, network, gateway, dev, metric):
        self._add_history("ip_route_replace", network, gateway, dev, metric)
        return self._run_command(self._do_ip_route_replace, network, gateway, dev, metric)

    def _do_ip_route_del(self, network, gateway, dev, metric):
        route_filter = self._get_route_filter(network, gateway, dev, metric)
        routes = self._find_routes(route_filter)
        if len(routes) == 0:
            self._print_stdout("RTNETLINK answers: No such process")
            return 2
        for route_id in routes.keys():
            self._remove_route(route_id)
        return 0

    def ip_route_del(self, network, gateway, dev, metric):
        self._add_history("ip_route_del", network, gateway, dev, metric)
        return self._run_command(self._do_ip_route_del, network, gateway, dev, metric)

    @staticmethod
    def _get_link_text(link):
        pieces = ["UP" if link["adm_state"] else "DOWN"]
        if raw_dev := link.get("raw_dev", None):
            pieces.append(f"VLAN({raw_dev},{link['vlan_id']})")
        elif master := link.get("master", None):
            pieces.append(f"SLAVE({master})")
        elif slaves := link.get("slaves", None):
            pieces.append(f"BONDING({','.join(slaves)})")
        pieces.extend([str(ip) for ip in sorted(link["addresses"])])
        return " ".join(pieces)

    def get_link_status(self, name):
        if not (link := self._links.get(name, None)):
            raise NetworkingMockError(f"Link does not exist: '{name}'")
        return self._get_link_text(link)

    def get_links_status(self):
        return [name + " " + self._get_link_text(self._links[name])
                for name in sorted(self._links.keys())]

    @staticmethod
    def _get_route_text(route):
        net = route["net"]
        net_text = "default" if net.value == 0 and net.prefixlen == 0 else str(net)
        text = f"{net_text} via {route['via']} dev {route['dev']}"
        if metric := route["metric"]:
            text += f" metric {metric}"
        return text

    def get_routes(self):
        return [self._get_route_text(self._routes[id]) for id in sorted(self._routes.keys())]

    def set_allow_multiple_default_gateways(self, allow: bool):
        self._allow_multiple_default_gateways = allow


class SystemCommandMockError(BaseException):
    pass


class SystemCommandMock():  # pylint: disable=too-few-public-methods
    def __init__(self, nwmock: NetworkingMock):
        self._nwmock = nwmock

    def _ip_addr_show(self, _):
        return self._nwmock.ip_addr_show()

    def _ip_br_addr_show_dev(self, args):
        return self._nwmock.ip_addr_show_dev(args[0])

    def _ip_addr_add(self, args):
        return self._nwmock.ip_addr_add(args[0], args[1])

    def _ip_addr_flush(self, args):
        return self._nwmock.ip_addr_flush(args[0])

    def _ip_link_set_down(self, args):
        return self._nwmock.ip_link_set_down(args[0])

    def _ip_o_addr_show_to(self, args):
        return self._nwmock.ip_addr_show_addr(args[0])

    def _ip_route_show_all(self, args):
        return self._nwmock.ip_route_show_all(args[0])

    def _ip_neigh_show_all(self, args):
        return self._nwmock.ip_neigh_show_all(args)

    def _hostname(self, args):
        return self._nwmock.get_hostname(args)

    def _ip_route_show(self, args):
        return self._nwmock.ip_route_show(args[0], args[1], args[2], args[3], args[4])

    def _ip_route_add(self, args):
        return self._nwmock.ip_route_add(args[0], args[1], args[2], args[3])

    def _ip_route_replace(self, args):
        return self._nwmock.ip_route_replace(args[0], args[1], args[2], args[3])

    def _ip_route_del(self, args):
        return self._nwmock.ip_route_del(args[0], args[1], args[2], args[3])

    def _ifup(self, args):
        return self._nwmock.ifup(args[0])

    def _ifdown(self, args):
        return self._nwmock.ifdown(args[0])

    _MAPPINGS = (
        (re.compile(R"^/sbin/ifup (?:-v )?(\S+)$"), _ifup),
        (re.compile(R"^/sbin/ifdown (?:-v )?(\S+)$"), _ifdown),
        (re.compile(R"^/usr/sbin/ip addr show$"), _ip_addr_show),
        (re.compile(R"^/usr/sbin/ip -br addr show dev (\S+)$"), _ip_br_addr_show_dev),
        (re.compile(R"^/usr/sbin/ip addr add (\S+) dev (\S+)$"), _ip_addr_add),
        (re.compile(R"^/usr/sbin/ip addr flush dev (\S+)$"), _ip_addr_flush),
        (re.compile(R"^(?:/usr/sbin/)?ip -o addr show to (\S+)$"), _ip_o_addr_show_to),
        (re.compile(R"^/usr/sbin/ip link set down dev (\S+)$"), _ip_link_set_down),
        (re.compile(R"^/usr/sbin/ip (?:(-6) )?route show$"), _ip_route_show_all),
        (re.compile(R"^/usr/sbin/ip neigh show$"), _ip_neigh_show_all),
        (re.compile(R"^/usr/sbin/ip (?:(-6) )?route show (\S+)(?: via (\S+) "
                    R"dev (\S+))?(?: metric (\S+))?$"), _ip_route_show),
        (re.compile(R"^/usr/sbin/ip route add (\S+) via (\S+) "
                    R"dev (\S+)(?: metric (\S+))?$"), _ip_route_add),
        (re.compile(R"^/usr/sbin/ip route replace (\S+) via (\S+) "
                    R"dev (\S+)(?: metric (\S+))?$"), _ip_route_replace),
        (re.compile(R"^/usr/sbin/ip route del (\S+) via (\S+) "
                    R"dev (\S+)(?: metric (\S+))?$"), _ip_route_del),
        (re.compile(R"^/usr/bin/hostname$"), _hostname),)

    def execute_system_cmd(self, cmd):
        for mapping in self._MAPPINGS:
            if result := mapping[0].search(cmd):
                return mapping[1](self, result.groups())
        raise SystemCommandMockError(f"Unrecognized command: '{cmd}'")


class LoggerMock():
    DEBUG = "debug"
    INFO = "info"
    WARNING = "warning"
    ERROR = "error"
    FATAL = "fatal"

    def __init__(self):
        self._entries = list()

    def _log(self, log_type, msg):
        self._entries.append((log_type, msg))

    def get_history(self):
        return self._entries

    def reset_history(self):
        self._entries.clear()

    def basicConfig(self):
        pass

    def debug(self, msg):
        self._log(self.DEBUG, msg)

    def info(self, msg):
        self._log(self.INFO, msg)

    def warning(self, msg):
        self._log(self.WARNING, msg)

    def error(self, msg):
        self._log(self.ERROR, msg)

    def fatal(self, msg):
        self._log(self.FATAL, msg)


class ConfigFileGenerator():
    _SHORT_HEADER = ["# HEADER: Last generated at: 2025-01-01 00:00:00 +0000"]

    _LONG_HEADER = ["# HEADER: This file is being managed by puppet. Changes to",
                    "# HEADER: interfaces that are not being managed by puppet will persist;",
                    "# HEADER: however changes to interfaces that are being managed by puppet will",
                    "# HEADER: be overwritten. In addition, file order is NOT guaranteed.",
                    "# HEADER: Last generated at: 2025-01-01 00:00:00 +0000", "", ""]

    _AUTOCFG = ("echo 0 > /proc/sys/net/ipv6/conf/{ifname}/autoconf; "
                "echo 0 > /proc/sys/net/ipv6/conf/{ifname}/accept_ra; "
                "echo 0 > /proc/sys/net/ipv6/conf/{ifname}/accept_redirects")

    _TEMPLATE = {
        "iface": "iface {ifname} {inet} {mode}",
        "vlan-raw-device": "vlan-raw-device {raw_dev}",
        "address": "address {address}",
        "netmask": "netmask {netmask}",
        "gateway": "{indent}gateway {gateway}",
        "bond-master": "{indent}bond-master {master}",
        "bond-miimon": "{indent}bond-miimon 100",
        "bond-mode": "{indent}bond-mode active-backup",
        "bond-primary": "{indent}bond-primary {primary}",
        "bond-slaves": "{indent}bond-slaves {slaves}",
        "hwaddress": "{indent}hwaddress {hwaddress}",
        "mtu": "{indent}mtu {mtu}",
        "pre-up-slave": "{indent}pre-up /usr/sbin/ip link set dev {device} promisc on; " + _AUTOCFG,
        "pre-up-vlan-ifupdown": "{indent}pre-up /sbin/modprobe -q 8021q",
        "pre-up-vlan-manual": "{indent}pre-up /sbin/modprobe -q 8021q; "
                              "ip link add link {raw_dev} name {device} type vlan id {vlan_id}",
        "up": "{indent}up sleep 10",
        "post-up": "{indent}post-up " + _AUTOCFG,
        "post-up-lo": "{indent}post-up /usr/local/bin/tc_setup.sh "
                      "lo mgmt 10000 > /dev/null; " + _AUTOCFG,
        "post-up-vlan": "{indent}post-up /usr/sbin/ip link set dev {device} mtu {mtu}; " + _AUTOCFG,
        "post-down": "{indent}post-down ip link del {device}",
        "scope": "{indent}scope host",
        "stx-description": "{indent}stx-description ifname:{device},net:None",
        "allow-": "{indent}allow-{master} {device}",
    }

    _PROPERTY_MAP = {
        "lo": ["mtu", "post-up-lo", "scope", "stx-description"],
        "eth": ["mtu", "post-up", "stx-description"],
        "slave": ["bond-master", "mtu", "pre-up-slave", "stx-description", "allow-"],
        "bonding": ["bond-miimon", "bond-mode", "bond-primary", "bond-slaves", "hwaddress",
                    "mtu", "post-up", "stx-description", "up"],
        "vlan-NNN": ["vlan-raw-device", "mtu", "post-up-vlan", "pre-up-vlan-ifupdown",
                     "stx-description"],
        "vlan-dot": ["mtu", "post-up-vlan", "pre-up-vlan-ifupdown", "stx-description"],
        "vlan-manual": ["mtu", "post-down", "post-up-vlan", "pre-up-vlan-manual",
                        "stx-description"],
    }

    def __init__(self):
        self._hwaddr_seq = 1

    @staticmethod
    def _get_basic_props(config):
        props = ["iface"]
        if config.get("address", None):
            props.append("address")
            props.append("netmask")
            if config.get("gateway", None):
                props.append("gateway")
        return props

    def _get_props(self, config):
        return self._get_basic_props(config) + self._PROPERTY_MAP[config["type"]]

    def _gen_cfg_lines(self, config):
        props = self._get_props(config)
        lines = list()
        for prop in props:
            lines.append(self._TEMPLATE[prop].format(**config))
        return lines

    def _get_new_hw_address(self):
        hwaddr = f"08:00:27:f2:66:{self._hwaddr_seq:02d}"
        self._hwaddr_seq += 1
        return hwaddr

    def _parse_cfg(self, ifname, input_config, indent=False):
        config = input_config.copy()
        if ifname == "lo":
            iftype = "lo"
        elif res := re.search(R"^(\S+)\.(\d+)(?:\:\S+)?$", ifname):
            iftype = "vlan-dot"
            config["raw_dev"] = res.groups()[0]
            config["vlan_id"] = res.groups()[1]
        elif res := re.search(R"^vlan(\d+)(?:\:\S+)?$", ifname):
            iftype = "vlan-NNN"
            config["vlan_id"] = res.groups()[0]
        elif "vlan_id" in input_config:
            iftype = "vlan-manual"
        elif "master" in input_config:
            iftype = "slave"
        elif slaves := input_config.get("slaves", None):
            iftype = "bonding"
            config["slaves"] = " ".join(slaves)
            config["primary"] = slaves[0]
            if "hwaddress" not in input_config:
                config["hwaddress"] = self._get_new_hw_address()
        else:
            iftype = "eth"
        config["type"] = iftype
        config["ifname"] = ifname
        config["device"] = ifname.split(":")[0] if ":" in ifname else ifname
        config["mtu"] = input_config.get("mtu", 1500)
        config["indent"] = "    " if indent else ""

        if address := input_config.get("address", None):
            net = IPNetwork(address)
            config["address"] = str(net.ip)
            config["netmask"] = str(net.netmask) if net.version == 4 else net.prefixlen
            config["inet"] = "inet6" if net.version == 6 else "inet"
            config["mode"] = "static"
        else:
            config["inet"] = input_config.get("inet", "inet")
            config["mode"] = input_config.get("mode", "manual")

        return config

    @staticmethod
    def _gen_auto_lines(auto):
        return ["auto " + " ".join(auto)]

    @staticmethod
    def _gen_route_line(route):
        net = IPNetwork(route["net"])
        line = f"{net.ip} {net.netmask} {route['via']} {route['dev']}"
        if metric := route.get("metric", None):
            line += f" metric {metric}"
        return line

    def _gen_routes_lines(self, routes):
        return [self._gen_route_line(route) for route in routes]

    def generate_auto_file(self, auto):
        lines = self._gen_auto_lines(auto)
        return '\n'.join(lines) + '\n'

    def generate_ifcfg_file(self, ifname, config):
        config = self._parse_cfg(ifname, config)
        lines = self._SHORT_HEADER + self._gen_cfg_lines(config)
        return '\n'.join(lines) + '\n'

    def generate_interfaces_file(self, config):
        lines = self._LONG_HEADER.copy()
        for ifname, input_cfg in config.items():
            if ifname == "auto":
                lines.extend(self._gen_auto_lines(input_cfg))
            else:
                output_cfg = self._parse_cfg(ifname, input_cfg, True)
                lines.extend(self._gen_cfg_lines(output_cfg))
            lines.append('')
        return '\n'.join(lines) + '\n'

    def generate_routes_file(self, routes):
        lines = self._LONG_HEADER + self._gen_routes_lines(routes)
        return '\n'.join(lines) + '\n'

    def _generate_ifcfg_files(self, tree, contents):
        for name, config in contents.items():
            if name == "auto":
                tree[anc.ETC_DIR + "/auto"] = self.generate_auto_file(config)
            else:
                tree[anc.ETC_DIR + "/ifcfg-" + name] = self.generate_ifcfg_file(name, config)

    def generate_file_tree(self, puppet_files=None, etc_files=None):
        tree = dict()

        if puppet_files:
            if interfaces := puppet_files.get("interfaces", None):
                tree[anc.PUPPET_FILE] = self.generate_interfaces_file(interfaces)
            if routes := puppet_files.get("routes", None):
                tree[anc.PUPPET_ROUTES_FILE] = self.generate_routes_file(routes)
            if routes6 := puppet_files.get("routes6", None):
                tree[anc.PUPPET_ROUTES6_FILE] = self.generate_routes_file(routes6)

        if etc_files:
            if interfaces := etc_files.get("interfaces", None):
                self._generate_ifcfg_files(tree, interfaces)
            routes = etc_files.get("routes", [])
            routes6 = etc_files.get("routes6", [])
            if routes or routes6:
                tree[anc.ETC_ROUTES_FILE] = self.generate_routes_file(routes + routes6)

        return tree


FILE_GEN = ConfigFileGenerator()


class BaseTestCase(testtools.TestCase):
    def tearDown(self):
        self._log = None
        self._scmdmock = None
        self._nwmock = None
        self._fs = None
        return super().tearDown()

    def _add_fs_mock(self, contents=None):
        self._fs = FilesystemMock(contents)

    def _add_logger_mock(self):
        self._log = LoggerMock()

    def _add_nw_mock(self, static_links, dhcp_config=None):
        self._nwmock = NetworkingMock(self._fs, static_links)
        if dhcp_config:
            self._nwmock.enable_dhcp(dhcp_config)

    def _add_scmd_mock(self):
        self._scmdmock = SystemCommandMock(self._nwmock)

    def _mock_fs(self, mocks, fxn, *args, **kwargs):
        with (
            mock.patch("src.bin.apply_network_config.path_exists", self._fs.exists),
            mock.patch("os.remove", self._fs.delete),
            mock.patch("os.listdir", self._fs.listdir),
            mock.patch("builtins.open", self._fs.open),
            mock.patch.multiple("os.path",
                                isfile=self._fs.isfile,
                                isdir=self._fs.isdir,
                                islink=self._fs.islink)
        ):
            return self._mocked_call(mocks, fxn, *args, **kwargs)

    def _mock_logger(self, mocks, fxn, *args, **kwargs):
        with mock.patch.multiple("logging",
                                 basicConfig=self._log.basicConfig,
                                 debug=self._log.debug,
                                 info=self._log.info,
                                 warning=self._log.warning,
                                 error=self._log.error,
                                 fatal=self._log.fatal):
            return self._mocked_call(mocks, fxn, *args, **kwargs)

    def _mock_syscmd(self, mocks, fxn, *args, **kwargs):
        with mock.patch("src.bin.apply_network_config.execute_system_cmd",
                        self._scmdmock.execute_system_cmd):
            return self._mocked_call(mocks, fxn, *args, **kwargs)

    def _mock_sysinv_lock(self, mocks, fxn, *args, **kwargs):
        with mock.patch.multiple("src.bin.apply_network_config",
                                 acquire_sysinv_agent_lock=mock.DEFAULT,
                                 release_sysinv_agent_lock=mock.DEFAULT):
            return self._mocked_call(mocks, fxn, *args, **kwargs)

    @staticmethod
    def _mocked_call(mocks, fxn, *args, **kwargs):
        if len(mocks) == 0:
            return fxn(*args, **kwargs)
        return mocks[0](mocks[1:], fxn, *args, **kwargs)


class GeneralTests(BaseTestCase):  # pylint: disable=too-many-public-methods
    def test_stanza_parser(self):
        parser = anc.StanzaParser()
        parser.parse_lines([
            "# HEADER: Last generated at: 2024-11-06 00:54:24 +0000",
            "iface   enp0s3\tinet manual   ",
            "# Comment",
            "    \t  # Comment",
            "",
            "mtu      1500",
            "\tpost-up echo 0 > /proc/sys/net/ipv6/conf/enp0s3/autoconf       ",
            "    stx-description ifname:oam0,net:None",
            ""])
        parser.parse_lines([
            "# HEADER: Last generated at: 2024-11-06 00:54:24 +0000",
            "auto\tlo\tenp0s3       vlan200      ",
            "iface vlan200 inet manual",
            "vlan-raw-device enp0s3",
            "    mtu 1500",
            "    post-up /usr/sbin/ip link set dev vlan200 mtu 1500",
            "    pre-up /sbin/modprobe -q 8021q",
            "    stx-description ifname:vlan200,net:None",
            "iface   ",
            "    address 10.23.44.11",
            "    netmask 255.255.255.0",
            "    mtu 1500",
            "iface enp0s8 inet manual",
            "    mtu 1500",
            "    post-up echo 0 > /proc/sys/net/ipv6/conf/enp0s8/autoconf",
            "    stx-description ifname:etc0,net:None",
            ""])
        parser.parse_lines(["    auto   "])
        parser.parse_lines(["    auto lo enp0s3 enp0s8"])
        parser.parse_lines(["\tauto  \t  lo \t enp0s8 enp0s9"])

        auto, ifaces = parser.get_auto_and_ifaces()
        self.assertEqual(["lo", "enp0s3", "vlan200", "enp0s8", "enp0s9"], auto)
        self.assertEqual({
            'enp0s3': {
                'iface': 'enp0s3 inet manual',
                'mtu': '1500',
                'post-up': 'echo 0 > /proc/sys/net/ipv6/conf/enp0s3/autoconf',
                'stx-description': 'ifname:oam0,net:None'},
            'vlan200': {
                'iface': 'vlan200 inet manual',
                'mtu': '1500',
                'post-up': '/usr/sbin/ip link set dev vlan200 mtu 1500',
                'pre-up': '/sbin/modprobe -q 8021q',
                'stx-description': 'ifname:vlan200,net:None',
                'vlan-raw-device': 'enp0s3'},
            'enp0s8': {
                'iface': 'enp0s8 inet manual',
                'mtu': '1500',
                'post-up': 'echo 0 > /proc/sys/net/ipv6/conf/enp0s8/autoconf',
                'stx-description': 'ifname:etc0,net:None'}},
            ifaces)

    def test_is_label(self):
        self.assertEqual(True, anc.is_label("enp0s8:2-7"))
        self.assertEqual(False, anc.is_label("enp0s8"))

    def test_get_base_iface(self):
        self.assertEqual("enp0s8", anc.get_base_iface("enp0s8:2-7"))
        self.assertEqual("vlan-200", anc.get_base_iface("vlan-200:11"))

    def test_read_file_lines(self):
        self._add_fs_mock({"/test-dir/test-file": "0\n1\n2\n"})
        lines = self._mocked_call([self._mock_fs], anc.read_file_lines, "/test-dir/test-file")
        self.assertEqual(3, len(lines))
        self.assertEqual("0", lines[0])
        self.assertEqual("1", lines[1])
        self.assertEqual("2", lines[2])

    _HEADER = "# HEADER: Last generated at: 2025-01-01 00:00:00 +0000"

    _IFACE_CONFIG = {"iface": "enp0s8 inet static",
                     "mtu": "9000",
                     "address": "12.12.1.55",
                     "netmask": "255.255.255.0",
                     "post-up": "echo # > /proc/sys/net/ipv6/conf/enp0s8/autoconf",
                     "stx-description": "ifname:etc0,net:None"}

    _IFACE_FILE = (f"{_HEADER}\n"
                    "iface enp0s8 inet static\n"
                    "address 12.12.1.55\n"
                    "netmask 255.255.255.0\n"
                    "mtu 9000\n"
                    "post-up echo # > /proc/sys/net/ipv6/conf/enp0s8/autoconf\n"
                    "stx-description ifname:etc0,net:None\n")

    def test_parse_auto_file(self):
        self._add_fs_mock({anc.ETC_DIR + "/auto":
                           "auto  lo   enp0s3\tenp0s3:1-17 enp0s8 vlan100"})
        auto = self._mocked_call([self._mock_fs], anc.parse_auto_file)
        self.assertEqual(["lo", "enp0s3", "enp0s3:1-17", "enp0s8", "vlan100"], auto)

    def test_parse_missing_auto_file(self):
        self._add_fs_mock()
        self._add_logger_mock()
        auto = self._mocked_call([self._mock_fs, self._mock_logger], anc.parse_auto_file)
        self.assertEqual(0, len(auto))
        self.assertEqual(LoggerMock.INFO, self._log.get_history()[-1][0])
        self.assertEqual(f"Auto file not found: '{anc.ETC_DIR + '/auto'}'",
                         self._log.get_history()[-1][1])

    def test_parse_etc_dir(self):
        contents = dict()
        contents[anc.ETC_DIR + "/auto"] = (
            "auto lo enp0s3 vlan20\n")
        contents[anc.ETC_DIR + "/oam-config"] = (
            "iface enp0s3 inet manual\n"
            "iface vlan20 inet static\n"
            "address 177.122.10.34\n"
            "netmask 255.255.255.0\n"
            "gateway 177.122.10.1\n"
            "vlan-raw-device enp0s3\n")
        contents[anc.ETC_DIR + "/ifcfg-lo"] = (
            "auto lo\n"
            "iface lo inet loopback\n")
        contents[anc.ETC_DIR + "/ifcfg-enp0s8"] = (
            "auto enp0s8\n"
            "iface enp0s8 inet manual\n"
            "post-up  echo 0 > /proc/sys/net/ipv6/conf/enp0s8/autoconf; "
                     "echo 0 > /proc/sys/net/ipv6/conf/enp0s8/accept_ra; "  # noqa: E131
                     "echo 0 > /proc/sys/net/ipv6/conf/enp0s8/accept_redirects\n")
        contents[anc.ETC_DIR + "/ifcfg-pxeboot"] = (
            "auto enp0s8:2\n"
            "iface enp0s8:2 inet dhcp\n")
        contents[anc.ETC_DIR + "/ifcfg-vlan10"] = (
            "auto vlan10\n"
            "iface vlan10 inet static\n"
            "address 192.168.204.75\n"
            "netmask 255.255.255.0\n"
            "vlan-raw-device enp0s8\n")

        self._add_fs_mock(contents)
        self._add_logger_mock()

        iface_configs = self._mocked_call([self._mock_fs, self._mock_logger], anc.parse_etc_dir)

        sorted_contents = [(ifname, sorted(iface_configs[ifname].items()))
                           for ifname in sorted(iface_configs.keys())]
        self.assertEqual([
            ('enp0s3', [('iface', 'enp0s3 inet manual')]),
            ('enp0s8', [('iface', 'enp0s8 inet manual'),
                        ('post-up', 'echo 0 > /proc/sys/net/ipv6/conf/enp0s8/autoconf; echo 0 > '
                                    '/proc/sys/net/ipv6/conf/enp0s8/accept_ra; echo 0 > '
                                    '/proc/sys/net/ipv6/conf/enp0s8/accept_redirects')]),
            ('enp0s8:2', [('iface', 'enp0s8:2 inet dhcp')]),
            ('lo', [('iface', 'lo inet loopback')]),
            ('vlan10', [('address', '192.168.204.75'),
                        ('iface', 'vlan10 inet static'),
                        ('netmask', '255.255.255.0'),
                        ('vlan-raw-device', 'enp0s8')]),
            ('vlan20', [('address', '177.122.10.34'),
                        ('gateway', '177.122.10.1'),
                        ('iface', 'vlan20 inet static'),
                        ('netmask', '255.255.255.0'),
                        ('vlan-raw-device', 'enp0s3')])],
            sorted_contents)

        self.assertEqual([
            ('info', 'Parsing file /etc/network/interfaces.d/auto'),
            ('info', 'Parsing file /etc/network/interfaces.d/ifcfg-enp0s8'),
            ('info', 'Parsing file /etc/network/interfaces.d/ifcfg-lo'),
            ('info', 'Parsing file /etc/network/interfaces.d/ifcfg-pxeboot'),
            ('info', 'Parsing file /etc/network/interfaces.d/ifcfg-vlan10'),
            ('info', 'Parsing file /etc/network/interfaces.d/oam-config')],
            self._log.get_history())

    def test_get_current_config_empty(self):
        self._add_fs_mock({anc.ETC_DIR: None})
        self._add_logger_mock()

        config = self._mocked_call([self._mock_fs, self._mock_logger], anc.get_current_config)

        self.assertEqual({"auto": set(), "dependencies": {}, "ifaces": {}, "ifaces_types": {}},
                         config)

        self.assertEqual([
            ('info', 'Parsing contents of the /etc/network/interfaces.d directory to gather '
                     'current network configuration'),
            ('info', "Auto file not found: '/etc/network/interfaces.d/auto'"),
            ('warning', 'No interface config found in /etc/network/interfaces.d')],
            self._log.get_history())

    def test_get_vlan_attributes_vlanNNN(self):
        dev, vlan_id = anc.get_vlan_attributes("vlan123", {"vlan-raw-device": "enp0s8"})
        self.assertEqual("enp0s8", dev)
        self.assertEqual(123, vlan_id)

    def test_get_vlan_attributes_vlanNNN_no_dev(self):
        self._add_logger_mock()
        attribs = self._mocked_call([self._mock_logger], anc.get_vlan_attributes,
                                    "vlan123", {"iface": "vlan123 inet static"})
        self.assertIsNone(attribs)
        self.assertEqual(LoggerMock.WARNING, self._log.get_history()[-1][0])
        self.assertEqual("vlan-raw-device property is empty or not specified for "
                         "interface vlan123, so it will not be considered as a valid VLAN",
                         self._log.get_history()[-1][1])

    def test_get_vlan_attributes_vlan_dot(self):
        dev, vlan_id = anc.get_vlan_attributes("enp0s8.123", {"iface": "enp0s8.123 inet static"})
        self.assertEqual("enp0s8", dev)
        self.assertEqual(123, vlan_id)

    def test_get_vlan_attributes_vlan_manual(self):
        dev, vlan_id = anc.get_vlan_attributes(
            "data0",
            {"pre-up": "/sbin/modprobe -q 8021q; "
                       "/usr/sbin/ip  link   add link\tenp0s8 name data0 type vlan id 123"})
        self.assertEqual("enp0s8", dev)
        self.assertEqual(123, vlan_id)

    def test_get_vlan_attributes_not_vlan(self):
        attribs = anc.get_vlan_attributes("enp0s8", {"iface": "enp0s8 inet static"})
        self.assertIsNone(attribs)

    def test_get_types_and_dependencies(self):
        iface_configs = {"bond0": {"bond-slaves": "enp0s9 enp0s10"},
                         "bond0:0-16": {},
                         "enp0s10": {"bond-master": "bond0"},
                         "enp0s3": {},
                         "enp0s3:3-7": {},
                         "enp0s4": {},
                         "enp0s4:5-17": {},
                         "enp0s9": {"bond-master": "bond0"},
                         "lo": {},
                         "lo:1-2": {},
                         "lo:5-14": {},
                         "vlan200": {"vlan-raw-device": "bond0"},
                         "vlan200:0-17": {}}

        ifaces_types, dependencies = anc.get_types_and_dependencies(iface_configs)

        self.assertEqual({
            "bond0": "bonding",
            "bond0:0-16": "label",
            "enp0s10": "slave",
            "enp0s3": "eth",
            "enp0s3:3-7": "label",
            "enp0s4": "eth",
            "enp0s4:5-17": "label",
            "enp0s9": "slave",
            "lo": "lo",
            "lo:1-2": "label",
            "lo:5-14": "label",
            "vlan200": "vlan",
            "vlan200:0-17": "label"
        }, ifaces_types)

        self.assertEqual({
            "bond0": {"vlan200", "bond0:0-16"},
            "enp0s10": {"bond0"},
            "enp0s3": {"enp0s3:3-7"},
            "enp0s4": {"enp0s4:5-17"},
            "enp0s9": {"bond0"},
            "lo": {"lo:1-2", "lo:5-14"},
            "vlan200": {"vlan200:0-17"}}, dependencies)

    def test_is_iface_modified_true(self):
        self._add_logger_mock()

        current = {"iface": "enp0s8 inet manual",
                   "mtu": "1500",
                   "post-up": "echo 0 > /proc/sys/net/ipv6/conf/enp0s8/autoconf",
                   "down": "ip addr flush dev enp0s8",
                   "stx-description": "ifname:etc0,net:None"}

        new = {"iface": "enp0s8 inet static",
               "mtu": "9000",
               "address": "12.12.1.55",
               "netmask": "255.255.255.0",
               "post-up": "echo 0 > /proc/sys/net/ipv6/conf/enp0s8/autoconf",
               "stx-description": "ifname:data0,net:None"}

        modified = self._mocked_call([self._mock_logger],
                                     anc.is_iface_modified, "enp0s8", new, current)

        self.assertEqual(True, modified)
        self.assertEqual(LoggerMock.INFO, self._log.get_history()[-1][0])
        self.assertEqual("Differences found for interface enp0s8:\n"
                         "    Removed properties:\n"
                         "        down ip addr flush dev enp0s8\n"
                         "    Added properties:\n"
                         "        address 12.12.1.55\n"
                         "        netmask 255.255.255.0\n"
                         "    Modified properties:\n"
                         "        'iface' went from 'enp0s8 inet manual' to 'enp0s8 inet static'\n"
                         "        'mtu' went from '1500' to '9000'",
                         self._log.get_history()[-1][1])

    def test_is_iface_modified_false(self):
        current = {"iface": "enp0s8 inet manual",
                   "mtu": "1500",
                   "post-up": "echo 0 > /proc/sys/net/ipv6/conf/enp0s8/autoconf",
                   "down": "ip addr flush dev enp0s8",
                   "stx-description": "ifname:etc0,net:None",
                   "random-property": "potato"}

        new = {"iface": "enp0s8 inet manual",
               "mtu": "1500",
               "post-up": "echo 0 > /proc/sys/net/ipv6/conf/enp0s8/autoconf",
               "down": "ip addr flush dev enp0s8",
               "stx-description": "ifname:data0,net:None",
               "random-property": "banana"}

        modified = anc.is_iface_modified("enp0s8", new, current)

        self.assertEqual(False, modified)

    def test_get_dependent_list(self):
        config = {"auto": {"lo", "lo:1-2", "lo:5-14", "enp0s3", "enp0s3:3-7", "enp0s4",
                           "enp0s4:5-17", "enp0s9", "enp0s10", "bond0", "bond0:0-16",
                           "vlan200", "vlan200:0-17"},
                  "dependencies": {"bond0": {"vlan200", "bond0:0-16"},
                                   "enp0s10": {"bond0"},
                                   "enp0s3": {"enp0s3:3-7"},
                                   "enp0s4": {"enp0s4:5-17"},
                                   "enp0s9": {"bond0"},
                                   "lo": {"lo:1-2", "lo:5-14"},
                                   "vlan200": {"vlan200:0-17"}}}

        dep1 = anc.get_dependent_list(config, {"vlan200"})
        self.assertEqual({"vlan200", "vlan200:0-17"}, dep1)

        dep2 = anc.get_dependent_list(config, {"bond0"})
        self.assertEqual({"bond0", "bond0:0-16", "vlan200", "vlan200:0-17"}, dep2)

        dep3 = anc.get_dependent_list(config, {"enp0s9"})
        self.assertEqual({"enp0s9", "bond0", "bond0:0-16", "vlan200", "vlan200:0-17"}, dep3)

        dep4 = anc.get_dependent_list(config, {"vlan200", "enp0s3"})
        self.assertEqual({"vlan200", "enp0s3", "vlan200:0-17", "enp0s3:3-7"}, dep4)

        dep5 = anc.get_dependent_list(config, {"enp0s4:5-17"})
        self.assertEqual({"enp0s4:5-17"}, dep5)

    def test_is_iface_missing_or_down(self):
        dev_path = "/sys/devices/pci0000:00/net/enp0s8"
        self._add_fs_mock({dev_path + "/operstate": "up\n",
                           anc.DEVLINK_BASE_PATH + "enp0s8": (dev_path, )})

        def check_result(value):
            result = self._mocked_call([self._mock_fs], anc.is_iface_missing_or_down, "enp0s8")
            self.assertEqual(value, result)

        check_result(False)

        self._fs.set_file_contents(anc.DEVLINK_BASE_PATH + "enp0s8/operstate", "down\n")
        check_result(True)

        self._fs.delete(anc.DEVLINK_BASE_PATH + "enp0s8")
        check_result(True)

    def test_get_updated_ifaces(self):
        new_config = {"ifaces_types": {"enp0s3": anc.ETH,
                                       "enp0s8": anc.ETH,
                                       "enp0s9": anc.SLAVE,
                                       "enp0s10": anc.SLAVE,
                                       "bond0": anc.BONDING,
                                       "bond1": anc.BONDING,
                                       "vlan100": anc.VLAN,
                                       "vlan200": anc.VLAN,
                                       "enp0s3:1-1": anc.LABEL,
                                       "enp0s8:2-4": anc.LABEL,
                                       "bond0:5-14": anc.LABEL,
                                       "bond1:6-16": anc.LABEL,
                                       "vlan100:3-9": anc.LABEL,
                                       "vlan200:4-11": anc.LABEL}}
        up_list = ["enp0s3", "enp0s9", "enp0s10", "bond0", "vlan100",
                   "enp0s8:2-4", "bond1:6-16", "vlan200:4-11"]
        updated = anc.get_updated_ifaces(new_config, up_list)
        self.assertEqual({"enp0s3", "enp0s8", "bond0", "bond1", "vlan100", "vlan200"}, updated)

    def test_sort_ifaces_by_type(self):
        config = {"ifaces_types": {"lo": anc.ETH,
                                   "enp0s3": anc.ETH,
                                   "enp0s8": anc.ETH,
                                   "enp0s9": anc.SLAVE,
                                   "enp0s10": anc.SLAVE,
                                   "bond0": anc.BONDING,
                                   "bond1": anc.BONDING,
                                   "vlan100": anc.VLAN,
                                   "vlan200": anc.VLAN,
                                   "enp0s3:1-1": anc.LABEL,
                                   "bond0:5-14": anc.LABEL,
                                   "vlan100:3-9": anc.LABEL}}
        ifaces = {"vlan100:3-9", "vlan200", "bond1", "bond0:5-14", "enp0s9",
                  "enp0s8", "enp0s3", "enp0s3:1-1", "vlan100", "bond0", "enp0s10", "lo"}
        sorted_ifaces = anc.sort_ifaces_by_type(config, ifaces, anc.UP_ORDER)
        self.assertEqual(["enp0s3", "enp0s8", "lo", "bond0", "bond1", "vlan100",
                          "vlan200", "bond0:5-14", "enp0s3:1-1", "vlan100:3-9"], sorted_ifaces)

    def _test_set_iface_down(self, delete_ifstate):
        etc_files = {
            "interfaces": {
                "auto": ["enp0s8", "enp0s8:2-3", "enp0s8:2-4"],
                "enp0s8": {"address": "169.254.202.2/24"},
                "enp0s8:2-3": {"address": "192.168.204.2/24"},
                "enp0s8:2-4": {"address": "fd01::2/64"}},
            "routes": [
                {"net": "14.15.1.0/24", "via": "169.254.202.111", "dev": "enp0s8", "metric": 1},
                {"net": "14.14.2.0/24", "via": "192.168.204.111", "dev": "enp0s8", "metric": 1}],
            "routes6": [
                {"net": "fa01:2::/64", "via": "fd01::111", "dev": "enp0s8", "metric": 1}],
        }

        self._add_fs_mock(FILE_GEN.generate_file_tree(etc_files=etc_files))
        self._add_nw_mock(["enp0s8"])
        self._add_scmd_mock()
        self._add_logger_mock()
        self._nwmock.apply_auto()

        if delete_ifstate:
            self._fs.delete(anc.IFSTATE_BASE_PATH + "enp0s8")

        self.assertEqual(['enp0s8 UP 169.254.202.2/24 192.168.204.2/24 fd01::2/64'],
                          self._nwmock.get_links_status())

        self.assertEqual(['14.15.1.0/24 via 169.254.202.111 dev enp0s8 metric 1',
                          '14.14.2.0/24 via 192.168.204.111 dev enp0s8 metric 1',
                          'fa01:2::/64 via fd01::111 dev enp0s8 metric 1'],
                          self._nwmock.get_routes())

        self._mocked_call([self._mock_fs, self._mock_syscmd, self._mock_logger],
                          anc.set_iface_down, "enp0s8")

        self.assertEqual(['enp0s8 DOWN'], self._nwmock.get_links_status())
        self.assertEqual([], self._nwmock.get_routes())

    def test_set_iface_down_ifstate_up(self):
        self._test_set_iface_down(delete_ifstate=False)
        self.assertEqual([('ifdown', 'enp0s8'),
                          ('ip_link_set_down', 'enp0s8'),
                          ('ip_addr_flush', 'enp0s8')],
                          self._nwmock.get_history())

    def test_set_iface_down_ifstate_down(self):
        self._test_set_iface_down(delete_ifstate=True)
        self.assertEqual([('ip_link_set_down', 'enp0s8'),
                          ('ip_addr_flush', 'enp0s8')],
                          self._nwmock.get_history())

    def test_set_iface_down_error_messages(self):
        def exec_sys_cmd(cmd):
            if cmd.startswith("/sbin/ifdown"):
                return 1, "< IFDOWN ERROR MESSAGE >\n"
            if cmd.startswith("/usr/sbin/ip link set down"):
                return 1, "< IP LINK SET DOWN ERROR MESSAGE >\n"
            if cmd.startswith("/usr/sbin/ip addr flush"):
                return 1, ("\n< IP ADDR FLUSH ERROR MESSAGE LINE 1 >\n"
                           "< IP ADDR FLUSH ERROR MESSAGE LINE 2 >\n\n\n")
            raise Exception(f"Unexpected system command: '{cmd}'")

        dev_path = "/sys/devices/pci0000:00/net/enp0s8"
        self._add_fs_mock({dev_path + "/operstate": "up\n",
                           anc.DEVLINK_BASE_PATH + "enp0s8": (dev_path, ),
                           anc.IFSTATE_BASE_PATH + "enp0s8": "enp0s8"})
        self._add_logger_mock()

        with mock.patch('src.bin.apply_network_config.execute_system_cmd', exec_sys_cmd):
            self._mocked_call([self._mock_fs, self._mock_logger], anc.set_iface_down, "enp0s8")

        self.assertEqual([
            ('info', 'Bringing enp0s8 down'),
            ('error', "Command 'ifdown' failed for interface enp0s8: '< IFDOWN ERROR MESSAGE >'"),
            ('error', "Command 'ip link set down' failed for interface enp0s8: "
                      "'< IP LINK SET DOWN ERROR MESSAGE >'"),
            ('error', "Command 'ip addr flush' failed for interface enp0s8:\n"
                      "< IP ADDR FLUSH ERROR MESSAGE LINE 1 >\n"
                      "< IP ADDR FLUSH ERROR MESSAGE LINE 2 >")],
            self._log.get_history())

    def test_remove_iface_config_file(self):
        self._add_logger_mock()

        def run_function(path_exists: bool):
            with (mock.patch('src.bin.apply_network_config.path_exists', return_value=path_exists),
                 mock.patch('os.remove', side_effect=OSError("< OS ERROR >"))):
                self._mocked_call([self._mock_logger], anc.remove_iface_config_file, "enp0s8")

        run_function(False)
        self.assertEqual([('info', 'File /etc/network/interfaces.d/ifcfg-enp0s8 does not exist, '
                                   'no need to remove')], self._log.get_history())

        self._log.reset_history()
        run_function(True)
        self.assertEqual([
            ('info', 'Removing /etc/network/interfaces.d/ifcfg-enp0s8'),
            ('error', 'Failed to remove /etc/network/interfaces.d/ifcfg-enp0s8: < OS ERROR >')],
            self._log.get_history())

    def _test_write_iface_config_file(self, has_existing_file):
        path = anc.ETC_DIR + "/ifcfg-enp0s8"
        contents = {path: "EXISTING CONTENTS\n"} if has_existing_file else None
        self._add_fs_mock(contents)
        with mock.patch('src.bin.apply_network_config.get_header', return_value=self._HEADER):
            self._mocked_call([self._mock_fs],
                              anc.write_iface_config_file, "enp0s8", self._IFACE_CONFIG)
        contents = self._fs.get_file_contents(path)
        self.assertEqual(self._IFACE_FILE, contents)

    def test_write_iface_config_file_new(self):
        self._test_write_iface_config_file(False)  # pylint: disable=no-value-for-parameter

    def test_write_iface_config_file_existing(self):
        self._test_write_iface_config_file(True)  # pylint: disable=no-value-for-parameter

    _AUTO_SAMPLE_CFG = {
        "auto": {"enp0s8", "enp0s3:1-3", "lo:3-7", "vlan10", "vlan11:4-8", "lo", "bond0:2-5",
                 "vlan11", "bond0", "enp0s3", "vlan10:5-11", "enp0s9"},
        "ifaces_types": {"enp0s8": anc.SLAVE,
                         "enp0s3:1-3": anc.LABEL,
                         "lo:3-7": anc.LABEL,
                         "vlan10": anc.VLAN,
                         "vlan11:4-8": anc.LABEL,
                         "lo": anc.LO,
                         "bond0:2-5": anc.LABEL,
                         "vlan11": anc.VLAN,
                         "bond0": anc.BONDING,
                         "enp0s3": anc.ETH,
                         "vlan10:5-11": anc.LABEL,
                         "enp0s9": anc.SLAVE}
    }

    _AUTO_FILE = (f"{_HEADER}\n"
                  "auto lo enp0s3 bond0 enp0s8 enp0s9 vlan10 vlan11 bond0:2-5 enp0s3:1-3 lo:3-7 "
                  "vlan10:5-11 vlan11:4-8\n")

    def _test_write_auto_file(self, has_existing_file):
        path = anc.ETC_DIR + "/auto"
        contents = {path: "EXISTING CONTENTS\n"} if has_existing_file else None
        self._add_fs_mock(contents)
        with mock.patch('src.bin.apply_network_config.get_header', return_value=self._HEADER):
            self._mocked_call([self._mock_fs], anc.write_auto_file, self._AUTO_SAMPLE_CFG)
        contents = self._fs.get_file_contents(path)
        self.assertEqual(self._AUTO_FILE, contents)

    def test_write_auto_file_new(self):
        self._test_write_auto_file(False)  # pylint: disable=no-value-for-parameter

    def test_write_auto_file_existing(self):
        self._test_write_auto_file(True)  # pylint: disable=no-value-for-parameter

    def test_sort_properties(self):
        props = ["other3", "allow-", "gateway", "other1", "mtu", "bond-miimon", "other2", "iface"]
        sorted_props = anc.sort_properties(props)
        self.assertEqual(["iface", "gateway", "bond-miimon", "mtu",
                          "other1", "other2", "other3", "allow-"], sorted_props)

    def test_get_route_entries(self):
        self._add_fs_mock(
            {anc.PUPPET_ROUTES_FILE:
                "13.13.1.0 255.255.255.0 12.12.1.65 bond0 metric 1\n"
                "13.13.2.0 255.255.255.0 12.12.3.37 enp0s8\n",
             anc.PUPPET_ROUTES6_FILE:
                "dead:beef:55:: ffff:ffff:ffff:ffff:: dead:beef::aa:1:453 bond0 metric 1\n"
                "dead:beef:78:: ffff:ffff:ffff:ffff:: dead:beef:bb::bb:1:172 vlan200"})
        self._add_logger_mock()

        entries = self._mocked_call([self._mock_fs, self._mock_logger], anc.get_route_entries,
                                    [anc.PUPPET_ROUTES_FILE, anc.PUPPET_ROUTES6_FILE])

        self.assertEqual(['13.13.1.0 255.255.255.0 12.12.1.65 bond0 metric 1',
                          '13.13.2.0 255.255.255.0 12.12.3.37 enp0s8',
                          'dead:beef:55:: ffff:ffff:ffff:ffff:: dead:beef::aa:1:453 bond0 metric 1',
                          'dead:beef:78:: ffff:ffff:ffff:ffff:: dead:beef:bb::bb:1:172 vlan200'],
                          entries)
        self.assertEqual([], self._log.get_history())

    def test_get_route_entries_from_lines(self):
        self._add_logger_mock()

        contents = [
            "# Comment 1",
            "",
            "        # Comment 2",
            "\t   # Comment 3",
            "13.13.1.0 255.255.255.0 12.12.1.65 bond0 metric 1",
            "\t13.13.2.0\t255.255.255.0\t12.12.3.37\tenp0s8\t\t\t",
            "    13.13.3.0 255.255.255.0 12.12.3.113 vlan200 metric 1    ",
            "    13.13.4.0 255.255.255.0 12.12.4.16   ",
            "  \t  dead:beef:55:: ffff:ffff:ffff:ffff:: dead:beef::aa:1:453 bond0 metric 1   ",
            "    dead:beef:78:: ffff:ffff:ffff:ffff:: dead:beef:bb::bb:1:172 vlan200 metric 1\t"]

        entries = self._mocked_call([self._mock_logger],
                                    anc.get_route_entries_from_lines, contents, anc.ETC_ROUTES_FILE)

        self.assertEqual([
            '13.13.1.0 255.255.255.0 12.12.1.65 bond0 metric 1',
            '13.13.2.0 255.255.255.0 12.12.3.37 enp0s8',
            '13.13.3.0 255.255.255.0 12.12.3.113 vlan200 metric 1',
            'dead:beef:55:: ffff:ffff:ffff:ffff:: dead:beef::aa:1:453 bond0 metric 1',
            'dead:beef:78:: ffff:ffff:ffff:ffff:: dead:beef:bb::bb:1:172 vlan200 metric 1'],
            entries)

        self.assertEqual([(
            'warning',
            "Invalid route in file '/etc/network/routes', must have at least 4 "
            "parameters, 3 found: '13.13.4.0 255.255.255.0 12.12.4.16'")],
            self._log.get_history())

    def test_get_route_iface(self):
        self.assertEqual("vlan200", anc.get_route_iface("13.13.3.0 255.255.255.0 12.12.3.113 "
                                                        "vlan200 metric 1"))

    def test_create_route_obj_from_entry(self):
        self.assertEqual({'ifname': 'enp0s8',
                          'network': '13.13.2.0',
                          'netmask': '255.255.255.0',
                          'nexthop': '12.12.3.37'},
                          anc.create_route_obj_from_entry(
                              "13.13.2.0 255.255.255.0 12.12.3.37 enp0s8"))
        self.assertEqual({'ifname': 'bond0',
                          'network': '13.13.1.0',
                          'netmask': '255.255.255.0',
                          'nexthop': '12.12.1.65',
                          'metric': '1'},
                          anc.create_route_obj_from_entry(
                              "13.13.1.0 255.255.255.0 12.12.1.65 bond0 metric 1"))

    def test_get_prefix_length(self):
        self.assertEqual(0, anc.get_prefix_length('0.0.0.0'))
        self.assertEqual(1, anc.get_prefix_length('128.0.0.0'))
        self.assertEqual(8, anc.get_prefix_length('255.0.0.0'))
        self.assertEqual(31, anc.get_prefix_length('255.255.255.254'))

        self.assertEqual(0, anc.get_prefix_length('0::'))
        self.assertEqual(1, anc.get_prefix_length('8000::'))
        self.assertEqual(16, anc.get_prefix_length('ffff::'))
        self.assertEqual(127, anc.get_prefix_length('ffff:ffff:ffff:ffff:ffff:ffff:ffff:fffe'))

        def assert_fails(netmask):
            exc = self.assertRaises(anc.InvalidNetmaskError, anc.get_prefix_length, netmask)
            self.assertEqual(f"Failed to get prefix length, invalid netmask: '{netmask}'", str(exc))

        assert_fails("2555.0.0.0")
        assert_fails("255.0.255.0")
        assert_fails("0.255.0.0")

        assert_fails("fffff:ffff::")
        assert_fails("ffff::ffff")
        assert_fails("::ffff")

    def test_get_linux_network(self):
        self.assertEqual("192.168.1.0/24", anc.get_linux_network({"network": "192.168.1.0",
                                                                  "netmask": "255.255.255.0"}))
        self.assertEqual("default", anc.get_linux_network({"network": "default"}))

    def _test_remove_route_entry_from_kernel(self, entry, return_code=0, stdout=""):
        received_cmd = None

        def exec_sys_cmd(cmd):
            nonlocal received_cmd
            received_cmd = cmd
            return return_code, stdout

        with mock.patch('src.bin.apply_network_config.execute_system_cmd', exec_sys_cmd):
            self._mocked_call([self._mock_logger], anc.remove_route_entry_from_kernel, entry)

        return received_cmd

    def test_remove_route_entry_from_kernel_invalid_netmask(self):
        self._add_logger_mock()
        self._test_remove_route_entry_from_kernel("13.13.3.0 2555.255.255.0 12.12.3.113 "
                                                  "vlan200 metric 1")
        self.assertEqual([(
            'error',
            "Failed to remove route entry '13.13.3.0 2555.255.255.0 12.12.3.113 vlan200 "
            "metric 1' from the kernel: Failed to get prefix length, invalid netmask: "
            "'2555.255.255.0'")],
            self._log.get_history())

    def test_remove_route_entry_from_kernel_fail(self):
        self._add_logger_mock()
        self._test_remove_route_entry_from_kernel("13.13.3.0 255.255.255.0 12.12.3.113 "
                                                  "vlan200 metric 1", 1, "< ERROR >")
        self.assertEqual(
            [('info', 'Removing route: 13.13.3.0/24 via 12.12.3.113 dev vlan200 metric 1'),
             ('error', "Failed removing route 13.13.3.0/24 via 12.12.3.113 dev vlan200 "
                       "metric 1: '< ERROR >'")],
            self._log.get_history())

    def test_remove_route_entry_from_kernel_succeed(self):
        self._add_logger_mock()
        cmd = self._test_remove_route_entry_from_kernel("13.13.3.0 255.255.255.0 12.12.3.113 "
                                                        "vlan200 metric 1")
        self.assertEqual(
            [('info', 'Removing route: 13.13.3.0/24 via 12.12.3.113 dev vlan200 metric 1')],
            self._log.get_history())
        self.assertEqual(
            "/usr/sbin/ip route del 13.13.3.0/24 via 12.12.3.113 dev vlan200 metric 1", cmd)

    def test_get_route_description(self):
        route_1 = {"network": "13.13.3.0", "netmask": "255.255.255.0",
                   "nexthop": "12.12.3.113", "ifname": "vlan200"}
        self.assertEqual("13.13.3.0/24 via 12.12.3.113 dev vlan200",
                         anc.get_route_description(route_1))
        self.assertEqual("13.13.3.0/24", anc.get_route_description(route_1, False))
        route_1["metric"] = 1
        self.assertEqual("13.13.3.0/24 via 12.12.3.113 dev vlan200 metric 1",
                         anc.get_route_description(route_1))
        self.assertEqual("13.13.3.0/24 metric 1", anc.get_route_description(route_1, False))

        route_2 = {"network": "default", "nexthop": "12.12.3.113", "ifname": "vlan200"}
        self.assertEqual("default via 12.12.3.113 dev vlan200", anc.get_route_description(route_2))
        self.assertEqual("default", anc.get_route_description(route_2, False))
        route_2["metric"] = 1
        self.assertEqual("default via 12.12.3.113 dev vlan200 metric 1",
                         anc.get_route_description(route_2))
        self.assertEqual("default metric 1", anc.get_route_description(route_2, False))

        route_3 = {"network": "aabb::", "netmask": "ffff:ffff:ffff:ffff::",
                   "nexthop": "fe88::1", "ifname": "enp0s9"}
        self.assertEqual("aabb::/64 via fe88::1 dev enp0s9", anc.get_route_description(route_3))
        self.assertEqual("aabb::/64", anc.get_route_description(route_3, False))
        route_3["metric"] = 1
        self.assertEqual("aabb::/64 via fe88::1 dev enp0s9 metric 1",
                         anc.get_route_description(route_3))
        self.assertEqual("aabb::/64 metric 1", anc.get_route_description(route_3, False))

        route_4 = {"network": "default", "nexthop": "fe88::1", "ifname": "enp0s9"}
        self.assertEqual("default via fe88::1 dev enp0s9", anc.get_route_description(route_4))
        self.assertEqual("default", anc.get_route_description(route_4, False))
        route_4["metric"] = 1
        self.assertEqual("default via fe88::1 dev enp0s9 metric 1",
                         anc.get_route_description(route_4))
        self.assertEqual("default metric 1", anc.get_route_description(route_4, False))

    def _test_add_route_entry_to_kernel(self, entry, cmd_responses):
        position = 0
        self._add_logger_mock()

        def exec_sys_cmd(cmd):
            nonlocal position
            pos = position
            position += 1
            self.assertEqual(cmd_responses[pos][0], cmd)
            return cmd_responses[pos][1], cmd_responses[pos][2]

        with mock.patch('src.bin.apply_network_config.execute_system_cmd', exec_sys_cmd):
            self._mocked_call([self._mock_logger], anc.add_route_entry_to_kernel, entry)

    def test_add_route_entry_to_kernel_existing(self):
        self._test_add_route_entry_to_kernel(
            "13.13.3.0 255.255.255.0 12.12.3.113 vlan200 metric 1",
            (("/usr/sbin/ip route show 13.13.3.0/24 via 12.12.3.113 dev vlan200 metric 1", 0,
              "13.13.3.0/24"), ))
        self.assertEqual(
            [('info', 'Adding route: 13.13.3.0/24 via 12.12.3.113 dev vlan200 metric 1'),
             ('info', 'Route already exists, skipping')],
            self._log.get_history())

    def test_add_route_entry_to_kernel_show_fail(self):
        self._test_add_route_entry_to_kernel(
            "13.13.3.0 255.255.255.0 12.12.3.113 vlan200 metric 1",
            (("/usr/sbin/ip route show 13.13.3.0/24 via 12.12.3.113 dev vlan200 metric 1", 1,
              "< ERROR 1 >"),
             ("/usr/sbin/ip route show 13.13.3.0/24 metric 1", 1, "< ERROR 2 >"),
             ("/usr/sbin/ip route add 13.13.3.0/24 via 12.12.3.113 dev vlan200 metric 1", 0, "")))
        self.assertEqual(
            [('info', 'Adding route: 13.13.3.0/24 via 12.12.3.113 dev vlan200 metric 1')],
            self._log.get_history())

    def test_add_route_entry_to_kernel_add_fail(self):
        self._test_add_route_entry_to_kernel(
            "13.13.3.0 255.255.255.0 12.12.3.113 vlan200 metric 1",
            (("/usr/sbin/ip route show 13.13.3.0/24 via 12.12.3.113 dev vlan200 metric 1", 0, ""),
             ("/usr/sbin/ip route show 13.13.3.0/24 metric 1", 0, ""),
             ("/usr/sbin/ip route add 13.13.3.0/24 via 12.12.3.113 dev vlan200 metric 1", 1,
              "< ERROR >")))
        self.assertEqual(
            [('info', 'Adding route: 13.13.3.0/24 via 12.12.3.113 dev vlan200 metric 1'),
             ('error', "Failed adding route 13.13.3.0/24 via 12.12.3.113 dev "
                       "vlan200 metric 1: '< ERROR >'")],
            self._log.get_history())

    def test_add_route_entry_to_kernel_replace_fail(self):
        self._test_add_route_entry_to_kernel(
            "13.13.3.0 255.255.255.0 12.12.3.113 vlan200 metric 1",
            (("/usr/sbin/ip route show 13.13.3.0/24 via 12.12.3.113 dev vlan200 metric 1", 0, ""),
             ("/usr/sbin/ip route show 13.13.3.0/24 metric 1", 0,
              "13.13.3.0/24 via 12.12.3.1 dev vlan200"),
             ("/usr/sbin/ip route replace 13.13.3.0/24 via 12.12.3.113 dev vlan200 metric 1", 1,
              "< ERROR >")))
        self.assertEqual(
            [('info', 'Adding route: 13.13.3.0/24 via 12.12.3.113 dev vlan200 metric 1'),
             ('info', 'Route to specified network already exists, replacing: 13.13.3.0/24 via '
                      '12.12.3.1 dev vlan200'),
             ('error', "Failed replacing route 13.13.3.0/24 via 12.12.3.113 dev "
                       "vlan200 metric 1: '< ERROR >'")],
            self._log.get_history())

    def test_add_route_entry_to_kernel_add_succeed(self):
        self._test_add_route_entry_to_kernel(
            "13.13.3.0 255.255.255.0 12.12.3.113 vlan200 metric 1",
            (("/usr/sbin/ip route show 13.13.3.0/24 via 12.12.3.113 dev vlan200 metric 1", 0, ""),
             ("/usr/sbin/ip route show 13.13.3.0/24 metric 1", 0, ""),
             ("/usr/sbin/ip route add 13.13.3.0/24 via 12.12.3.113 dev vlan200 metric 1", 0, "")))
        self.assertEqual(
            [('info', 'Adding route: 13.13.3.0/24 via 12.12.3.113 dev vlan200 metric 1')],
            self._log.get_history())

    def test_add_route_entry_to_kernel_replace_succeed(self):
        self._test_add_route_entry_to_kernel(
            "13.13.3.0 255.255.255.0 12.12.3.113 vlan200 metric 1",
            (("/usr/sbin/ip route show 13.13.3.0/24 via 12.12.3.113 dev vlan200 metric 1", 0, ""),
             ("/usr/sbin/ip route show 13.13.3.0/24 metric 1", 0,
              "13.13.3.0/24 via 12.12.3.1 dev vlan200"),
             ("/usr/sbin/ip route replace 13.13.3.0/24 via 12.12.3.113 dev vlan200 metric 1", 0,
              "")))
        self.assertEqual(
            [('info', 'Adding route: 13.13.3.0/24 via 12.12.3.113 dev vlan200 metric 1'),
             ('info', 'Route to specified network already exists, replacing: 13.13.3.0/24 via '
                      '12.12.3.1 dev vlan200')],
            self._log.get_history())

    def _test_update_routes(self, etc_routes, puppet_routes, updated_ifaces=None):
        links = ["enc10", "enc11", "enc12", "enc13"]
        self._add_fs_mock(FILE_GEN.generate_file_tree(
            puppet_files={
                "routes": [route for route in puppet_routes if ":" not in route["net"]],
                "routes6": [route for route in puppet_routes if ":" in route["net"]]
            },
            etc_files={
                "interfaces": {
                    "auto": links,
                    "enc10": {"address": "10.10.10.3/24"},
                    "enc11": {"address": "10.10.11.3/24"},
                    "enc12": {"address": "fd12::3/64"},
                    "enc13": {"address": "fd13::3/64"},
                },
                "routes": etc_routes,
            }
        ))
        self._add_nw_mock(links)
        self._add_scmd_mock()
        self._add_logger_mock()
        self._nwmock.apply_auto()

        if updated_ifaces:
            for iface in updated_ifaces:
                self._nwmock.ifdown(iface)
                self._nwmock.ifup(iface)

        with mock.patch('src.bin.apply_network_config.get_header', return_value=self._HEADER):
            self._mocked_call([self._mock_fs, self._mock_syscmd, self._mock_sysinv_lock,
                               self._mock_logger], anc.update_routes, updated_ifaces)

    def test_update_routes(self):
        self._test_update_routes(
            etc_routes=[
                {"net": "10.33.1.0/24", "via": "10.10.10.101", "dev": "enc10", "metric": 1},
                {"net": "10.33.2.0/24", "via": "10.10.10.101", "dev": "enc10", "metric": 1},
                {"net": "10.33.3.0/24", "via": "10.10.10.101", "dev": "enc10", "metric": 1},
                {"net": "fd33:1::/64", "via": "fd12::101", "dev": "enc12", "metric": 1},
                {"net": "fd33:2::/64", "via": "fd12::101", "dev": "enc12", "metric": 1},
                {"net": "fd33:3::/64", "via": "fd12::101", "dev": "enc12", "metric": 1}],
            puppet_routes=[
                {"net": "10.33.1.0/24", "via": "10.10.10.101", "dev": "enc10", "metric": 1},
                {"net": "10.33.2.0/24", "via": "10.10.10.202", "dev": "enc10", "metric": 1},
                {"net": "10.33.4.0/24", "via": "10.10.10.101", "dev": "enc10", "metric": 1},
                {"net": "fd33:1::/64", "via": "fd12::101", "dev": "enc12", "metric": 1},
                {"net": "fd33:2::/64", "via": "fd12::202", "dev": "enc12", "metric": 1},
                {"net": "fd33:4::/64", "via": "fd12::101", "dev": "enc12", "metric": 1}])

        self.assertEqual([
            '10.33.1.0/24 via 10.10.10.101 dev enc10 metric 1',
            'fd33:1::/64 via fd12::101 dev enc12 metric 1',
            '10.33.2.0/24 via 10.10.10.202 dev enc10 metric 1',
            '10.33.4.0/24 via 10.10.10.101 dev enc10 metric 1',
            'fd33:2::/64 via fd12::202 dev enc12 metric 1',
            'fd33:4::/64 via fd12::101 dev enc12 metric 1'],
            self._nwmock.get_routes())

        self.assertEqual([
            ('info', 'Differences found between /var/run/network-scripts.puppet/routes and '
                     '/etc/network/routes'),
            ('info', 'Removing route: 10.33.2.0/24 via 10.10.10.101 dev enc10 metric 1'),
            ('info', 'Removing route: 10.33.3.0/24 via 10.10.10.101 dev enc10 metric 1'),
            ('info', 'Removing route: fd33:2::/64 via fd12::101 dev enc12 metric 1'),
            ('info', 'Removing route: fd33:3::/64 via fd12::101 dev enc12 metric 1'),
            ('info', 'Route not previously present in /etc/network/routes, adding'),
            ('info', 'Adding route: 10.33.2.0/24 via 10.10.10.202 dev enc10 metric 1'),
            ('info', 'Route not previously present in /etc/network/routes, adding'),
            ('info', 'Adding route: 10.33.4.0/24 via 10.10.10.101 dev enc10 metric 1'),
            ('info', 'Route not previously present in /etc/network/routes, adding'),
            ('info', 'Adding route: fd33:2::/64 via fd12::202 dev enc12 metric 1'),
            ('info', 'Route not previously present in /etc/network/routes, adding'),
            ('info', 'Adding route: fd33:4::/64 via fd12::101 dev enc12 metric 1')],
            self._log.get_history())

        self.assertEqual(
            self._HEADER + "\n"
            "10.33.1.0 255.255.255.0 10.10.10.101 enc10 metric 1\n"
            "10.33.2.0 255.255.255.0 10.10.10.202 enc10 metric 1\n"
            "10.33.4.0 255.255.255.0 10.10.10.101 enc10 metric 1\n"
            "fd33:1:: ffff:ffff:ffff:ffff:: fd12::101 enc12 metric 1\n"
            "fd33:2:: ffff:ffff:ffff:ffff:: fd12::202 enc12 metric 1\n"
            "fd33:4:: ffff:ffff:ffff:ffff:: fd12::101 enc12 metric 1\n",
            self._fs.get_file_contents(anc.ETC_ROUTES_FILE))

    def test_update_routes_updated_interfaces(self):
        routes = [
            {"net": "10.33.1.0/24", "via": "10.10.10.101", "dev": "enc10", "metric": 1},
            {"net": "10.33.2.0/24", "via": "10.10.10.101", "dev": "enc10", "metric": 1},
            {"net": "10.33.3.0/24", "via": "10.10.11.101", "dev": "enc11", "metric": 1},
            {"net": "10.33.4.0/24", "via": "10.10.11.101", "dev": "enc11", "metric": 1},
            {"net": "fd33:1::/64", "via": "fd12::101", "dev": "enc12", "metric": 1},
            {"net": "fd33:2::/64", "via": "fd12::101", "dev": "enc12", "metric": 1},
            {"net": "fd33:3::/64", "via": "fd13::101", "dev": "enc13", "metric": 1},
            {"net": "fd33:4::/64", "via": "fd13::101", "dev": "enc13", "metric": 1}]
        self._test_update_routes(routes, routes, ["enc11", "enc13"])

        self.assertEqual([
            '10.33.1.0/24 via 10.10.10.101 dev enc10 metric 1',
            '10.33.2.0/24 via 10.10.10.101 dev enc10 metric 1',
            'fd33:1::/64 via fd12::101 dev enc12 metric 1',
            'fd33:2::/64 via fd12::101 dev enc12 metric 1',
            '10.33.3.0/24 via 10.10.11.101 dev enc11 metric 1',
            '10.33.4.0/24 via 10.10.11.101 dev enc11 metric 1',
            'fd33:3::/64 via fd13::101 dev enc13 metric 1',
            'fd33:4::/64 via fd13::101 dev enc13 metric 1'],
            self._nwmock.get_routes())

        self.assertEqual([
            ('info', 'No differences found between /var/run/network-scripts.puppet/routes and '
                     '/etc/network/routes'),
            ('info', 'Route is associated with and updated interface, adding'),
            ('info', 'Adding route: 10.33.3.0/24 via 10.10.11.101 dev enc11 metric 1'),
            ('info', 'Route is associated with and updated interface, adding'),
            ('info', 'Adding route: 10.33.4.0/24 via 10.10.11.101 dev enc11 metric 1'),
            ('info', 'Route is associated with and updated interface, adding'),
            ('info', 'Adding route: fd33:3::/64 via fd13::101 dev enc13 metric 1'),
            ('info', 'Route is associated with and updated interface, adding'),
            ('info', 'Adding route: fd33:4::/64 via fd13::101 dev enc13 metric 1')],
            self._log.get_history())

        self.assertEqual(
            self._HEADER + "\n"
            "10.33.1.0 255.255.255.0 10.10.10.101 enc10 metric 1\n"
            "10.33.2.0 255.255.255.0 10.10.10.101 enc10 metric 1\n"
            "10.33.3.0 255.255.255.0 10.10.11.101 enc11 metric 1\n"
            "10.33.4.0 255.255.255.0 10.10.11.101 enc11 metric 1\n"
            "fd33:1:: ffff:ffff:ffff:ffff:: fd12::101 enc12 metric 1\n"
            "fd33:2:: ffff:ffff:ffff:ffff:: fd12::101 enc12 metric 1\n"
            "fd33:3:: ffff:ffff:ffff:ffff:: fd13::101 enc13 metric 1\n"
            "fd33:4:: ffff:ffff:ffff:ffff:: fd13::101 enc13 metric 1\n",
            self._fs.get_file_contents(anc.ETC_ROUTES_FILE))

    def test_check_cloud_init_valid(self):
        static_links = ["lo", "ens1f0"]
        self._add_fs_mock({
            anc.ETC_DIR + "/auto": FILE_GEN.generate_auto_file(static_links),
            anc.ETC_DIR + "/ifcfg-ens1f0":
                FILE_GEN.generate_ifcfg_file("ens1f0", {"address": "fd05::2/64",
                                                        "gateway": "fd05::111"}),
            anc.SUBCLOUD_ENROLLMENT_FILE: '',
            anc.CLOUD_INIT_FILE:
                "# This file is generated from information provided by the datasource.  Changes\n"
                "# to it will not persist across an instance reboot.  To disable cloud-init's\n"
                "# network configuration capabilities, write a file\n"
                "# /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg with the following:\n"
                "# network: {config: disabled}\n"
                "auto lo\n"
                "iface lo inet loopbackauto vlan401\n"
                "iface vlan401 inet6 static\n"
                "    address 2620:10a:a001:d41::163/64\n"
                "    gateway 2620:10a:a001:d41::1\n"
                "    vlan-raw-device ens1f0\n"
                "    vlan_id 401\n"})

        self._add_nw_mock(static_links)
        self._add_scmd_mock()
        self._add_logger_mock()
        self._nwmock.set_allow_multiple_default_gateways(True)
        self._nwmock.apply_auto()
        self._nwmock.ifup("vlan401")
        self._nwmock.ifdown("ens1f0")
        self._nwmock.ifup("ens1f0")

        self._mocked_call([self._mock_fs, self._mock_syscmd, self._mock_logger],
                          anc.check_enrollment_config)

        self.assertEqual(['default via 2620:10a:a001:d41::1 dev vlan401 metric 1024'],
                          self._nwmock.get_routes())

        self.assertEqual([
            ('info', "Enrollment: Parsing file '/etc/network/interfaces.d/50-cloud-init'"),
            ('info', 'Enrollment: Configuring interface vlan401 with gateway '
                     '2620:10a:a001:d41::1'),
            ('info', 'Adding route: default via 2620:10a:a001:d41::1 dev vlan401'),
            ('info', 'Route to specified network already exists, replacing: default via fd05::111 '
                     'dev ens1f0 metric 1024 pref medium'),
            ('info', "Enrollment: Removed '/etc/network/interfaces.d/50-cloud-init' to prevent "
                     'config conflicts')],
            self._log.get_history())

    def test_check_cloud_init_multiple_ifaces(self):
        static_links = ["lo", "ens1f0"]
        self._add_fs_mock({
            anc.ETC_DIR + "/auto": FILE_GEN.generate_auto_file(static_links),
            anc.ETC_DIR + "/ifcfg-ens1f0":
                FILE_GEN.generate_ifcfg_file("ens1f0", {"address": "fd05::2/64",
                                                        "gateway": "fd05::111"}),
            anc.SUBCLOUD_ENROLLMENT_FILE: '',
            anc.CLOUD_INIT_FILE:
                "auto lo\n"
                "iface lo inet loopbackauto vlan401\n"
                "iface vlan401 inet6 static\n"
                "    address 2620:10a:a001:d41::163/64\n"
                "    gateway 2620:10a:a001:d41::1\n"
                "    vlan-raw-device ens1f0\n"
                "    vlan_id 401\n"
                "iface vlan402 inet6 static\n"
                "    address eb22:303::55:2/64\n"
                "    gateway eb22:303::1\n"
                "    vlan-raw-device ens1f0\n"
                "    vlan_id 402\n"})

        self._add_nw_mock(static_links)
        self._add_scmd_mock()
        self._add_logger_mock()
        self._nwmock.set_allow_multiple_default_gateways(True)
        self._nwmock.apply_auto()
        self._nwmock.ifup("vlan401")
        self._nwmock.ifup("vlan402")
        self._nwmock.ifdown("ens1f0")
        self._nwmock.ifup("ens1f0")

        self._mocked_call([self._mock_fs, self._mock_syscmd, self._mock_logger],
                          anc.check_enrollment_config)

        self.assertEqual(['default via eb22:303::1 dev vlan402 metric 1024'],
                          self._nwmock.get_routes())

        self.assertEqual([
            ('info', "Enrollment: Parsing file '/etc/network/interfaces.d/50-cloud-init'"),
            ('warning', 'Enrollment: Multiple interfaces with gateway for ipv6 found: vlan401, '
                        'vlan402'),
            ('info', 'Enrollment: Configuring interface vlan401 with gateway '
                     '2620:10a:a001:d41::1'),
            ('info', 'Adding route: default via 2620:10a:a001:d41::1 dev vlan401'),
            ('info', 'Route to specified network already exists, replacing: default via fd05::111 '
                     'dev ens1f0 metric 1024 pref medium'),
            ('info', 'Enrollment: Configuring interface vlan402 with gateway eb22:303::1'),
            ('info', 'Adding route: default via eb22:303::1 dev vlan402'),
            ('info', 'Route to specified network already exists, replacing: default via '
                     '2620:10a:a001:d41::1 dev vlan401 metric 1024 pref medium'),
            ('info', "Enrollment: Removed '/etc/network/interfaces.d/50-cloud-init' to prevent "
                     'config conflicts')],
            self._log.get_history())

    def test_check_cloud_init_empty(self):
        self._add_fs_mock({
            anc.SUBCLOUD_ENROLLMENT_FILE: '',
            anc.CLOUD_INIT_FILE: ''})

        self._add_logger_mock()

        self._mocked_call([self._mock_fs, self._mock_logger], anc.check_enrollment_config)

        self.assertEqual([
            ('info', "Enrollment: Parsing file '/etc/network/interfaces.d/50-cloud-init'"),
            ('warning', 'Enrollment: Could not find any valid interface config in '
                        "'/etc/network/interfaces.d/50-cloud-init'")],
            self._log.get_history())

    def test_check_cloud_init_invalid_gateway(self):
        self._add_fs_mock({
            anc.SUBCLOUD_ENROLLMENT_FILE: '',
            anc.CLOUD_INIT_FILE:
                "auto lo\n"
                "iface lo inet loopbackauto vlan401\n"
                "iface vlan401 inet6 static\n"
                "    address 2620:10a:a001:d41::163/64\n"
                "    gateway h620::1\n"
                "    vlan-raw-device ens1f0\n"
                "    vlan_id 401\n"})

        self._add_logger_mock()

        self._mocked_call([self._mock_fs, self._mock_logger], anc.check_enrollment_config)

        self.assertEqual([
            ('info', "Enrollment: Parsing file '/etc/network/interfaces.d/50-cloud-init'"),
            ('warning', "Enrollment: Invalid gateway address 'h620::1' for interface 'vlan401'"),
            ('warning', 'Enrollment: No interface with gateway address found, skipping')],
            self._log.get_history())

    def test_disable_kickstart_pxeboot(self):
        puppet_cfg = {
            "interfaces": {
                "auto": ["lo", "enp0s8", "vlan10", "vlan10:1-5"],
                "lo": {},
                "enp0s8": {"mode": "dhcp"},
                "vlan10": {"raw_dev": "enp0s8"},
                "vlan10:1-5": {"raw_dev": "enp0s8", "address": "192.168.204.75/24",
                               "gateway": "192.168.204.2"}},
        }

        contents = FILE_GEN.generate_file_tree(puppet_files=puppet_cfg)
        contents[anc.ETC_DIR + "/ifcfg-lo"] = (
            "auto lo\n"
            "iface lo inet loopback\n")
        contents[anc.ETC_DIR + "/ifcfg-enp0s8"] = (
            "auto enp0s8\n"
            "iface enp0s8 inet manual\n"
            "post-up  echo 0 > /proc/sys/net/ipv6/conf/enp0s8/autoconf; "
                     "echo 0 > /proc/sys/net/ipv6/conf/enp0s8/accept_ra; "  # noqa: E131
                     "echo 0 > /proc/sys/net/ipv6/conf/enp0s8/accept_redirects\n")
        contents[anc.ETC_DIR + "/ifcfg-pxeboot"] = (
            "auto enp0s8:2\n"
            "iface enp0s8:2 inet dhcp\n"
            "post-up  echo 0 > /proc/sys/net/ipv6/conf/enp0s8/autoconf; "
                     "echo 0 > /proc/sys/net/ipv6/conf/enp0s8/accept_ra; "  # noqa: E131
                     "echo 0 > /proc/sys/net/ipv6/conf/enp0s8/accept_redirects\n")
        contents[anc.ETC_DIR + "/ifcfg-vlan10"] = (
            "auto vlan10\n"
            "iface vlan10 inet static\n"
            "address 192.168.204.75\n"
            "netmask 255.255.255.0\n"
            "gateway 192.168.204.2\n"
            "vlan-raw-device enp0s8\n"
            "post-up  echo 0 > /proc/sys/net/ipv6/conf/vlan10/autoconf; "
                     "echo 0 > /proc/sys/net/ipv6/conf/vlan10/accept_ra; "  # noqa: E131
                     "echo 0 > /proc/sys/net/ipv6/conf/vlan10/accept_redirects\n")

        self._add_fs_mock(contents)
        self._add_nw_mock(["lo", "enp0s8"], {"enp0s8": IPNetwork("169.254.202.131/24")})
        self._add_scmd_mock()
        self._add_logger_mock()
        self._nwmock.apply_auto()

        self._mocked_call([self._mock_fs,
                           self._mock_syscmd,
                           self._mock_sysinv_lock,
                           self._mock_logger],
                          anc.update_interfaces)

        self.assertEqual([
            'enp0s8 UP 169.254.202.131/24',
            'lo UP',
            'vlan10 UP VLAN(enp0s8,10) 192.168.204.75/24'],
            self._nwmock.get_links_status())

        self.assertEqual([
            ('info', 'Turn off pxeboot install config for enp0s8:2, will be turned on later'),
            ('info', 'Bringing enp0s8:2 down'),
            ('info', 'Remove ifcfg-pxeboot, left from kickstart install phase'),
            ('info', 'Removing /etc/network/interfaces.d/ifcfg-pxeboot'),
            ('info', 'Parsing contents of the /etc/network/interfaces.d directory to gather '
                     'current network configuration'),
            ('info', "Auto file not found: '/etc/network/interfaces.d/auto'"),
            ('info', 'Parsing file /etc/network/interfaces.d/ifcfg-enp0s8'),
            ('info', 'Parsing file /etc/network/interfaces.d/ifcfg-lo'),
            ('info', 'Parsing file /etc/network/interfaces.d/ifcfg-vlan10'),
            ('info', 'Added interfaces: enp0s8 lo vlan10 vlan10:1-5'),
            ('info', 'Interface enp0s8 not in /etc/network/interfaces.d/auto but currently up, '
                     'adding to DOWN list'),
            ('info', 'Interface lo not in /etc/network/interfaces.d/auto but currently up, '
                     'adding to DOWN list'),
            ('info', 'Interface vlan10 not in /etc/network/interfaces.d/auto but currently up, '
                     'adding to DOWN list'),
            ('info', 'Bringing vlan10 down'),
            ('info', 'Bringing enp0s8 down'),
            ('info', 'Bringing lo down'),
            ('info', 'Bringing lo up'),
            ('info', 'Bringing enp0s8 up'),
            ('info', 'Bringing vlan10 up'),
            ('info', 'Bringing vlan10:1-5 up')],
            self._log.get_history())

    def test_add_interface_link_up(self):
        etc_cfg = {
            "interfaces": {
                "auto": ["lo"],
                "lo": {}},
        }

        puppet_cfg = {
            "interfaces": {
                "auto": ["lo", "enp0s9", "enp0s9:4-17"],
                "lo": {},
                "enp0s9": {},
                "enp0s9:4-17": {"address": "188.177.12.44/24"}},
        }

        contents = FILE_GEN.generate_file_tree(puppet_files=puppet_cfg, etc_files=etc_cfg)
        self._add_fs_mock(contents)
        self._add_nw_mock(["lo", "enp0s9"])
        self._add_scmd_mock()
        self._add_logger_mock()
        self._nwmock.apply_auto()
        self._nwmock.ip_link_set_up("enp0s9")
        self._nwmock.ip_addr_add("12.12.12.77/24", "enp0s9")

        self.assertEqual([
            'enp0s9 UP 12.12.12.77/24',
            'lo UP'],
            self._nwmock.get_links_status())

        self._mocked_call([self._mock_fs, self._mock_syscmd,
                           self._mock_sysinv_lock, self._mock_logger], anc.update_interfaces)

        self.assertEqual([
            'enp0s9 UP 188.177.12.44/24',
            'lo UP'],
            self._nwmock.get_links_status())

        self.assertEqual([
            ('info', 'Parsing contents of the /etc/network/interfaces.d directory to gather '
                     'current network configuration'),
            ('info', 'Parsing file /etc/network/interfaces.d/auto'),
            ('info', 'Parsing file /etc/network/interfaces.d/ifcfg-lo'),
            ('info', 'Added interfaces: enp0s9 enp0s9:4-17'),
            ('info', 'Interface enp0s9 not in /etc/network/interfaces.d/auto but currently up, '
                     'adding to DOWN list'),
            ('info', 'Bringing enp0s9 down'),
            ('info', 'Bringing enp0s9 up'),
            ('info', 'Bringing enp0s9:4-17 up')],
            self._log.get_history())

    def test_add_interface_currently_up(self):
        etc_cfg = {
            "interfaces": {
                "auto": ["lo"],
                "lo": {},
                "enp0s9": {"address": "192.168.12.45/24"}},
        }

        puppet_cfg = {
            "interfaces": {
                "auto": ["lo", "enp0s9", "enp0s9:4-17"],
                "lo": {},
                "enp0s9": {},
                "enp0s9:4-17": {"address": "188.177.12.44/24"}},
        }

        contents = FILE_GEN.generate_file_tree(puppet_files=puppet_cfg, etc_files=etc_cfg)
        self._add_fs_mock(contents)
        self._add_nw_mock(["lo", "enp0s9"])
        self._add_scmd_mock()
        self._add_logger_mock()
        self._nwmock.apply_auto()
        self._nwmock.ifup("enp0s9")

        self.assertEqual([
            'enp0s9 UP 192.168.12.45/24',
            'lo UP'],
            self._nwmock.get_links_status())

        self._mocked_call([self._mock_fs, self._mock_syscmd,
                           self._mock_sysinv_lock, self._mock_logger], anc.update_interfaces)

        self.assertEqual([
            'enp0s9 UP 188.177.12.44/24',
            'lo UP'],
            self._nwmock.get_links_status())

        self.assertEqual([
            ('info', 'Parsing contents of the /etc/network/interfaces.d directory to gather '
                     'current network configuration'),
            ('info', 'Parsing file /etc/network/interfaces.d/auto'),
            ('info', 'Parsing file /etc/network/interfaces.d/ifcfg-enp0s9'),
            ('info', 'Parsing file /etc/network/interfaces.d/ifcfg-lo'),
            ('info', 'Added interfaces: enp0s9 enp0s9:4-17'),
            ('info', 'Interface enp0s9 not in /etc/network/interfaces.d/auto but currently up, '
                     'adding to DOWN list'),
            ('info', 'Bringing enp0s9 down'),
            ('info', 'Bringing enp0s9 up'),
            ('info', 'Bringing enp0s9:4-17 up')],
            self._log.get_history())

    def test_execute_system_cmd(self):
        retcode, stdout = anc.execute_system_cmd('echo "test_execute_system_cmd"')
        self.assertEqual(0, retcode)
        self.assertEqual("test_execute_system_cmd\n", stdout)

    _OS_GETPGID = os.getpgid

    def test_execute_system_cmd_timeout_retcode_15(self):
        subproc_pid = None
        subproc_pgid = None

        def getpgid(pid):
            nonlocal subproc_pid
            nonlocal subproc_pgid
            subproc_pid = pid
            subproc_pgid = self._OS_GETPGID(pid)
            return subproc_pgid

        self._add_logger_mock()

        with mock.patch("os.getpgid", getpgid):
            retcode, stdout = self._mocked_call([self._mock_logger], anc.execute_system_cmd,
                                                "tests/system_cmd_test_script.sh 15", 1)

        self.assertEqual(15, retcode)
        self.assertEqual("< BEFORE SLEEP >\nTerminated\n< SIGTERM RECEIVED >\n", stdout)
        self.assertEqual([
            (LoggerMock.WARNING,
             "Execution time exceeded for command 'tests/system_cmd_test_script.sh 15', sending "
             f"SIGTERM to subprocess (pid={subproc_pid}, pgid={subproc_pgid})")],
             self._log.get_history())

    def test_execute_system_cmd_timeout_retcode_0(self):
        subproc_pid = None
        subproc_pgid = None

        def getpgid(pid):
            nonlocal subproc_pid
            nonlocal subproc_pgid
            subproc_pid = pid
            subproc_pgid = self._OS_GETPGID(pid)
            return subproc_pgid

        self._add_logger_mock()

        with mock.patch("os.getpgid", getpgid):
            retcode, stdout = self._mocked_call([self._mock_logger], anc.execute_system_cmd,
                                                "tests/system_cmd_test_script.sh 0", 1)

        self.assertEqual(0, retcode)
        self.assertEqual("< BEFORE SLEEP >\nTerminated\n< SIGTERM RECEIVED >\n", stdout)
        self.assertEqual([
            (LoggerMock.WARNING,
             "Execution time exceeded for command 'tests/system_cmd_test_script.sh 0', sending "
             f"SIGTERM to subprocess (pid={subproc_pid}, pgid={subproc_pgid})"),
            (LoggerMock.INFO,
             "Command 'tests/system_cmd_test_script.sh 0' output:\n"
             '< BEFORE SLEEP >\n'
             'Terminated\n'
             '< SIGTERM RECEIVED >')],
             self._log.get_history())

    def test_execute_system_cmd_timeout_kill(self):
        subproc_pid = None
        subproc_pgid = None

        def getpgid(pid):
            nonlocal subproc_pid
            nonlocal subproc_pgid
            subproc_pid = pid
            subproc_pgid = self._OS_GETPGID(pid)
            return subproc_pgid

        self._add_logger_mock()

        with (mock.patch("os.getpgid", getpgid),
              mock.patch("src.bin.apply_network_config.TERM_WAIT_TIME", 1)):
            retcode, stdout = self._mocked_call([self._mock_logger], anc.execute_system_cmd,
                                                "tests/system_cmd_test_script.sh 0 -e", 1)

        self.assertEqual(-9, retcode)
        self.assertEqual("< BEFORE SLEEP >\nTerminated\n< SIGTERM RECEIVED >\n", stdout)
        self.assertEqual([
            (LoggerMock.WARNING,
             "Execution time exceeded for command 'tests/system_cmd_test_script.sh 0 -e', sending "
             f"SIGTERM to subprocess (pid={subproc_pid}, pgid={subproc_pgid})"),
            (LoggerMock.WARNING,
             "Command 'tests/system_cmd_test_script.sh 0 -e' has not terminated after "
             f"1 seconds, sending SIGKILL to subprocess "
             f"(pid={subproc_pid}, pgid={subproc_pgid})")],
             self._log.get_history())


class TestInterfaceDependencies(BaseTestCase):

    _AUTO = ["enp0s3", "enp0s3:1-9", "enp0s8", "enp0s8:2-13", "enp0s8:3-15",
             "datavlan300", "datavlan300:6-22", "enp0s9", "enp0s10", "bond0",
             "bond0:4-12", "vlan200", "vlan200:5-19"]

    _BASE_CFG = {
        "interfaces": {
            "auto": _AUTO,
            "enp0s3": {},
            "enp0s3:1-9": {"address": "12.12.15.67/24", "gateway": "12.12.15.1"},
            "enp0s8": {},
            "enp0s8:2-13": {"address": "192.168.204.2/24"},
            "enp0s8:3-15": {"address": "192.168.206.2/24"},
            "datavlan300": {"raw_dev": "enp0s8", "vlan_id": 300},
            "datavlan300:6-22": {"address": "adad:efef::44:55:66/64",
                                 "raw_dev": "enp0s8", "vlan_id": 300},
            "enp0s9": {"master": "bond0"},
            "enp0s10": {"master": "bond0"},
            "bond0": {"slaves": ["enp0s9", "enp0s10"], "hwaddress": "08:00:27:f2:66:72"},
            "bond0:4-12": {"address": "11.22.3.15/24", "slaves": ["enp0s9", "enp0s10"],
                           "hwaddress": "08:00:27:f2:66:72"},
            "vlan200": {"raw_dev": "bond0"},
            "vlan200:5-19": {"address": "dead:beef::1:2:3/64", "raw_dev": "bond0"}}
    }

    _MODIFIED_CFG = {
        "auto": _AUTO,
        "enp0s3": {"mtu": 9000},
        "enp0s3:1-9": {"mtu": 9000, "address": "12.12.15.67/24", "gateway": "12.12.15.1"},
        "enp0s8": {"mtu": 9000},
        "enp0s8:2-13": {"mtu": 9000, "address": "192.168.204.2/24"},
        "enp0s8:3-15": {"mtu": 9000, "address": "192.168.206.2/24"},
        "datavlan300": {"mtu": 9000, "raw_dev": "enp0s8", "vlan_id": 300},
        "datavlan300:6-22": {"mtu": 9000, "address": "adad:efef::44:55:66/64",
                             "raw_dev": "enp0s8", "vlan_id": 300},
        "enp0s9": {"mtu": 9000, "master": "bond0"},
        "enp0s10": {"mtu": 9000, "master": "bond0"},
        "bond0": {"mtu": 9000, "slaves": ["enp0s9", "enp0s10"], "hwaddress": "08:00:27:f2:66:72"},
        "bond0:4-12": {"mtu": 9000, "address": "11.22.3.15/24", "slaves": ["enp0s9", "enp0s10"],
                       "hwaddress": "08:00:27:f2:66:72"},
        "vlan200": {"mtu": 9000, "raw_dev": "bond0"},
        "vlan200:5-19": {"mtu": 9000, "address": "dead:beef::1:2:3/64", "raw_dev": "bond0"}
    }

    _STATIC_LINKS = ["lo", "enp0s3", "enp0s8", "enp0s9", "enp0s10"]

    _FS = ReadOnlyFileContainer(FILE_GEN.generate_file_tree(_BASE_CFG, _BASE_CFG))

    _MODIFIED_FILES = {k: FILE_GEN.generate_ifcfg_file(k, v)
                       for k, v in _MODIFIED_CFG.items() if k != "auto"}

    def _setup_scenario(self, modified_ifaces):
        contents = dict()
        for iface in modified_ifaces:
            path = anc.ETC_DIR + "/ifcfg-" + iface
            contents[path] = self._MODIFIED_FILES[iface]
        self._fs = FilesystemMock(fs=self._FS, contents=contents)
        self._add_nw_mock(self._STATIC_LINKS)
        self._add_scmd_mock()
        self._add_logger_mock()
        self._nwmock.apply_auto()

    def _run_update_interfaces(self):
        self._mocked_call([self._mock_fs, self._mock_syscmd,
                           self._mock_sysinv_lock, self._mock_logger], anc.update_interfaces)

    def test_modify_label(self):
        self._setup_scenario(["enp0s3:1-9"])
        self._run_update_interfaces()
        self.assertEqual([("ifdown", "enp0s3:1-9"),
                          ("ifup", "enp0s3:1-9")],
                          self._nwmock.get_history())

    def test_modify_eth_with_label(self):
        self._setup_scenario(["enp0s3"])
        self._run_update_interfaces()
        self.assertEqual([('ifdown', 'enp0s3:1-9'),
                          ('ifdown', 'enp0s3'),
                          ('ip_link_set_down', 'enp0s3'),
                          ('ip_addr_flush', 'enp0s3'),
                          ('ifup', 'enp0s3'),
                          ('ifup', 'enp0s3:1-9')],
                          self._nwmock.get_history())

    def test_modify_vlan_over_eth(self):
        self._setup_scenario(["datavlan300"])
        self._run_update_interfaces()
        self.assertEqual([("ifdown", "datavlan300:6-22"),
                          ("ifdown", "datavlan300"),
                          ("ifup", "datavlan300"),
                          ("ifup", "datavlan300:6-22")],
                          self._nwmock.get_history())

    def test_modify_vlan_over_bonding(self):
        self._setup_scenario(["vlan200"])
        self._run_update_interfaces()
        self.assertEqual([("ifdown", "vlan200:5-19"),
                          ("ifdown", "vlan200"),
                          ("ifup", "vlan200"),
                          ("ifup", "vlan200:5-19")],
                          self._nwmock.get_history())

    def test_modify_eth_with_vlan(self):
        self._setup_scenario(["enp0s8"])
        self._run_update_interfaces()
        self.assertEqual([('ifdown', 'datavlan300:6-22'),
                          ('ifdown', 'enp0s8:2-13'),
                          ('ifdown', 'enp0s8:3-15'),
                          ('ifdown', 'datavlan300'),
                          ('ifdown', 'enp0s8'),
                          ('ip_link_set_down', 'enp0s8'),
                          ('ip_addr_flush', 'enp0s8'),
                          ('ifup', 'enp0s8'),
                          ('ifup', 'datavlan300'),
                          ('ifup', 'datavlan300:6-22'),
                          ('ifup', 'enp0s8:2-13'),
                          ('ifup', 'enp0s8:3-15')],
                          self._nwmock.get_history())

    def test_modify_bonding(self):
        self._setup_scenario(["bond0"])
        self._run_update_interfaces()
        self.assertEqual([('ifdown', 'bond0:4-12'),
                          ('ifdown', 'vlan200:5-19'),
                          ('ifdown', 'vlan200'),
                          ('ifdown', 'bond0'),
                          ('ifup', 'bond0'),
                          ('ifup', 'vlan200'),
                          ('ifup', 'bond0:4-12'),
                          ('ifup', 'vlan200:5-19')],
                          self._nwmock.get_history())

    def test_modify_slave(self):
        self._setup_scenario(["enp0s9"])
        self._run_update_interfaces()
        self.assertEqual([('ifdown', 'bond0:4-12'),
                          ('ifdown', 'vlan200:5-19'),
                          ('ifdown', 'vlan200'),
                          ('ifdown', 'bond0'),
                          ('ifup', 'bond0'),
                          ('ifup', 'vlan200'),
                          ('ifup', 'bond0:4-12'),
                          ('ifup', 'vlan200:5-19')],
                          self._nwmock.get_history())


class MigrationBaseTestCase(BaseTestCase):
    def _setup_scenario(self, from_cfg, to_cfg, static_links):
        self._add_fs_mock(FILE_GEN.generate_file_tree(to_cfg, from_cfg))
        self._add_nw_mock(static_links)
        self._add_scmd_mock()
        self._add_logger_mock()
        stdout = self._nwmock.apply_auto()
        self.assertEqual("", stdout)

    def _run_apply_config(self):
        self._mocked_call([self._mock_fs, self._mock_syscmd,
                           self._mock_sysinv_lock, self._mock_logger], anc.apply_config, False)

    def _check_etc_file_list(self, to_cfg):
        files = self._fs.listdir(anc.ETC_DIR)
        etc_ifaces = []
        has_auto = False
        for file in files:
            if file.startswith("ifcfg-"):
                etc_ifaces.append(file.split("-", 1)[1])
            elif file == "auto":
                has_auto = True
            else:
                raise Exception(f"Unexpected file in ETC dir: '{file}'")
        self.assertEqual(True, has_auto, "'auto' file not present in ETC dir")
        self.assertEqual(sorted(to_cfg["interfaces"]["auto"]), etc_ifaces)


class TestEthAndLoMigration(MigrationBaseTestCase):

    _LEFT = {
        "interfaces": {
            "auto": ["enp0s3", "enp0s3:1-1", "enp0s3:1-2", "lo", "lo:2-3", "lo:2-4",
                     "lo:3-5", "lo:3-6", "enp0s9", "enp0s9:7-11", "enp0s9:7-12"],
            "enp0s3": {},
            "enp0s3:1-1": {"address": "10.20.1.2/24", "gateway": "10.20.1.1"},
            "enp0s3:1-2": {"address": "fd00::1:2/64", "gateway": "fd00::1"},
            "lo": {},
            "lo:2-3": {"address": "192.168.204.2/24"},
            "lo:2-4": {"address": "fd01::2/64"},
            "lo:3-5": {"address": "192.168.206.2/24"},
            "lo:3-6": {"address": "fd02::2/64"},
            "enp0s9": {},
            "enp0s9:7-11": {"address": "112.44.202.26/24"},
            "enp0s9:7-12": {"address": "ad60:b00::202:26/64"},
            },
        "routes": [
            {"net": "14.14.1.0/24", "via": "10.20.1.111", "dev": "enp0s3", "metric": 1},
            {"net": "14.14.2.0/24", "via": "192.168.204.111", "dev": "lo", "metric": 1},
            {"net": "14.14.3.0/24", "via": "192.168.206.111", "dev": "lo", "metric": 1},
            {"net": "14.14.4.0/24", "via": "112.44.202.111", "dev": "enp0s9", "metric": 1}],
        "routes6": [
            {"net": "fa01:1::/64", "via": "fd00::111", "dev": "enp0s3", "metric": 1},
            {"net": "fa01:2::/64", "via": "fd01::111", "dev": "lo", "metric": 1},
            {"net": "fa01:3::/64", "via": "fd02::111", "dev": "lo", "metric": 1},
            {"net": "fa01:4::/64", "via": "ad60:b00::111", "dev": "enp0s9", "metric": 1}],
    }

    _RIGHT = {
        "interfaces": {
            "auto": ["enp0s9", "enp0s9:1-1", "enp0s9:1-2", "lo", "enp0s8", "enp0s8:2-3",
                     "enp0s8:2-4", "enp0s8:3-5", "enp0s8:3-6", "enp0s3", "enp0s3:7-11",
                     "enp0s3:7-12"],
            "enp0s9": {},
            "enp0s9:1-1": {"address": "10.20.1.2/24", "gateway": "10.20.1.1"},
            "enp0s9:1-2": {"address": "fd00::1:2/64", "gateway": "fd00::1"},
            "lo": {},
            "enp0s8": {"address": "169.254.202.2/24"},
            "enp0s8:2-3": {"address": "192.168.204.2/24"},
            "enp0s8:2-4": {"address": "fd01::2/64"},
            "enp0s8:3-5": {"address": "192.168.206.2/24"},
            "enp0s8:3-6": {"address": "fd02::2/64"},
            "enp0s3": {},
            "enp0s3:7-11": {"address": "112.44.202.26/24"},
            "enp0s3:7-12": {"address": "ad60:b00::202:26/64"},
            },
        "routes": [
            {"net": "14.14.1.0/24", "via": "10.20.1.111", "dev": "enp0s9", "metric": 1},
            {"net": "14.15.1.0/24", "via": "169.254.202.111", "dev": "enp0s8", "metric": 1},
            {"net": "14.14.2.0/24", "via": "192.168.204.111", "dev": "enp0s8", "metric": 1},
            {"net": "14.14.3.0/24", "via": "192.168.206.111", "dev": "enp0s8", "metric": 1},
            {"net": "14.14.4.0/24", "via": "112.44.202.111", "dev": "enp0s3", "metric": 1}],
        "routes6": [
            {"net": "fa01:1::/64", "via": "fd00::111", "dev": "enp0s9", "metric": 1},
            {"net": "fa01:2::/64", "via": "fd01::111", "dev": "enp0s8", "metric": 1},
            {"net": "fa01:3::/64", "via": "fd02::111", "dev": "enp0s8", "metric": 1},
            {"net": "fa01:4::/64", "via": "ad60:b00::111", "dev": "enp0s3", "metric": 1}],
    }

    _STATIC_LINKS = ["lo", "enp0s3", "enp0s8", "enp0s9"]

    def test_eth_to_eth_migration_a(self):
        self._setup_scenario(self._LEFT, self._RIGHT, self._STATIC_LINKS)

        self._run_apply_config()

        self.assertEqual([
            'enp0s3 UP 112.44.202.26/24 ad60:b00::202:26/64',
            'enp0s8 UP 169.254.202.2/24 192.168.204.2/24 192.168.206.2/24 fd01::2/64 fd02::2/64',
            'enp0s9 UP 10.20.1.2/24 fd00::1:2/64',
            'lo UP'],
            self._nwmock.get_links_status())

        self.assertEqual(['default via 10.20.1.1 dev enp0s9',
                          'default via fd00::1 dev enp0s9 metric 1024',
                          '14.14.1.0/24 via 10.20.1.111 dev enp0s9 metric 1',
                          '14.15.1.0/24 via 169.254.202.111 dev enp0s8 metric 1',
                          '14.14.2.0/24 via 192.168.204.111 dev enp0s8 metric 1',
                          '14.14.3.0/24 via 192.168.206.111 dev enp0s8 metric 1',
                          '14.14.4.0/24 via 112.44.202.111 dev enp0s3 metric 1',
                          'fa01:1::/64 via fd00::111 dev enp0s9 metric 1',
                          'fa01:2::/64 via fd01::111 dev enp0s8 metric 1',
                          'fa01:3::/64 via fd02::111 dev enp0s8 metric 1',
                          'fa01:4::/64 via ad60:b00::111 dev enp0s3 metric 1'],
                          self._nwmock.get_routes())

        self._check_etc_file_list(self._RIGHT)

    def test_eth_to_eth_migration_b(self):
        self._setup_scenario(self._RIGHT, self._LEFT, self._STATIC_LINKS)

        self._run_apply_config()

        self.assertEqual([
            'enp0s3 UP 10.20.1.2/24 fd00::1:2/64',
            'enp0s8 DOWN',
            'enp0s9 UP 112.44.202.26/24 ad60:b00::202:26/64',
            'lo UP 192.168.204.2/24 192.168.206.2/24 fd01::2/64 fd02::2/64'],
            self._nwmock.get_links_status())

        self.assertEqual(['default via 10.20.1.1 dev enp0s3',
                          'default via fd00::1 dev enp0s3 metric 1024',
                          '14.14.1.0/24 via 10.20.1.111 dev enp0s3 metric 1',
                          '14.14.2.0/24 via 192.168.204.111 dev lo metric 1',
                          '14.14.3.0/24 via 192.168.206.111 dev lo metric 1',
                          '14.14.4.0/24 via 112.44.202.111 dev enp0s9 metric 1',
                          'fa01:1::/64 via fd00::111 dev enp0s3 metric 1',
                          'fa01:2::/64 via fd01::111 dev lo metric 1',
                          'fa01:3::/64 via fd02::111 dev lo metric 1',
                          'fa01:4::/64 via ad60:b00::111 dev enp0s9 metric 1'],
                          self._nwmock.get_routes())

        self._check_etc_file_list(self._LEFT)


class TestEthToVLANMigration(MigrationBaseTestCase):

    _LEFT = {
        "interfaces": {
            "auto": ["enp0s3", "enp0s3:1-1", "enp0s3:1-2", "enp0s8",
                     "enp0s8:2-3", "enp0s8:2-4", "enp0s8:3-5", "enp0s8:3-6"],
            "enp0s3": {},
            "enp0s3:1-1": {"address": "10.20.1.2/24", "gateway": "10.20.1.1"},
            "enp0s3:1-2": {"address": "fd00::1:2/64", "gateway": "fd00::1"},
            "enp0s8": {"address": "169.254.202.2/24"},
            "enp0s8:2-3": {"address": "192.168.204.2/24"},
            "enp0s8:2-4": {"address": "fd01::2/64"},
            "enp0s8:3-5": {"address": "192.168.206.2/24"},
            "enp0s8:3-6": {"address": "fd02::2/64"}},
        "routes": [
            {"net": "14.14.1.0/24", "via": "10.20.1.111", "dev": "enp0s3", "metric": 1},
            {"net": "14.15.1.0/24", "via": "169.254.202.111", "dev": "enp0s8", "metric": 1},
            {"net": "14.14.2.0/24", "via": "192.168.204.111", "dev": "enp0s8", "metric": 1},
            {"net": "14.14.3.0/24", "via": "192.168.206.111", "dev": "enp0s8", "metric": 1}],
        "routes6": [
            {"net": "fa01:1::/64", "via": "fd00::111", "dev": "enp0s3", "metric": 1},
            {"net": "fa01:2::/64", "via": "fd01::111", "dev": "enp0s8", "metric": 1},
            {"net": "fa01:3::/64", "via": "fd02::111", "dev": "enp0s8", "metric": 1}],
    }

    _RIGHT = {
        "interfaces": {
            "auto": ["enp0s3", "enp0s3:1-1", "enp0s3:1-2", "enp0s8", "vlan100", "vlan200",
                     "vlan100:2-3", "vlan100:2-4", "vlan200:3-5", "vlan200:3-6"],
            "enp0s3": {},
            "enp0s3:1-1": {"address": "10.20.1.2/24", "gateway": "10.20.1.1"},
            "enp0s3:1-2": {"address": "fd00::1:2/64", "gateway": "fd00::1"},
            "enp0s8": {"address": "169.254.202.2/24"},
            "vlan100": {"raw_dev": "enp0s8"},
            "vlan100:2-3": {"address": "192.168.204.2/24", "raw_dev": "enp0s8"},
            "vlan100:2-4": {"address": "fd01::2/64", "raw_dev": "enp0s8"},
            "vlan200": {"raw_dev": "enp0s8"},
            "vlan200:3-5": {"address": "192.168.206.2/24", "raw_dev": "enp0s8"},
            "vlan200:3-6": {"address": "fd02::2/64", "raw_dev": "enp0s8"}},
        "routes": [
            {"net": "14.14.1.0/24", "via": "10.20.1.111", "dev": "enp0s3", "metric": 1},
            {"net": "14.15.1.0/24", "via": "169.254.202.111", "dev": "enp0s8", "metric": 1},
            {"net": "14.14.2.0/24", "via": "192.168.204.111", "dev": "vlan100", "metric": 1},
            {"net": "14.14.3.0/24", "via": "192.168.206.111", "dev": "vlan200", "metric": 1}],
        "routes6": [
            {"net": "fa01:1::/64", "via": "fd00::111", "dev": "enp0s3", "metric": 1},
            {"net": "fa01:2::/64", "via": "fd01::111", "dev": "vlan100", "metric": 1},
            {"net": "fa01:3::/64", "via": "fd02::111", "dev": "vlan200", "metric": 1}],
    }

    _STATIC_LINKS = ["enp0s3", "enp0s8"]

    def test_eth_to_vlan_migration(self):
        self._setup_scenario(self._LEFT, self._RIGHT, self._STATIC_LINKS)

        self._run_apply_config()

        self.assertEqual(['enp0s3 UP 10.20.1.2/24 fd00::1:2/64',
                          'enp0s8 UP 169.254.202.2/24',
                          'vlan100 UP VLAN(enp0s8,100) 192.168.204.2/24 fd01::2/64',
                          'vlan200 UP VLAN(enp0s8,200) 192.168.206.2/24 fd02::2/64'],
                          self._nwmock.get_links_status())

        self.assertEqual(['default via 10.20.1.1 dev enp0s3',
                          'default via fd00::1 dev enp0s3 metric 1024',
                          '14.14.1.0/24 via 10.20.1.111 dev enp0s3 metric 1',
                          '14.15.1.0/24 via 169.254.202.111 dev enp0s8 metric 1',
                          'fa01:1::/64 via fd00::111 dev enp0s3 metric 1',
                          '14.14.2.0/24 via 192.168.204.111 dev vlan100 metric 1',
                          '14.14.3.0/24 via 192.168.206.111 dev vlan200 metric 1',
                          'fa01:2::/64 via fd01::111 dev vlan100 metric 1',
                          'fa01:3::/64 via fd02::111 dev vlan200 metric 1'],
                          self._nwmock.get_routes())

        self._check_etc_file_list(self._RIGHT)

    def test_vlan_to_eth_migration(self):
        self._setup_scenario(self._RIGHT, self._LEFT, self._STATIC_LINKS)

        self._run_apply_config()

        self.assertEqual(['enp0s3 UP 10.20.1.2/24 fd00::1:2/64',
                          'enp0s8 UP 169.254.202.2/24 192.168.204.2/24 192.168.206.2/24 fd01::2/64 '
                          'fd02::2/64'],
                          self._nwmock.get_links_status())

        self.assertEqual(['default via 10.20.1.1 dev enp0s3',
                          'default via fd00::1 dev enp0s3 metric 1024',
                          '14.14.1.0/24 via 10.20.1.111 dev enp0s3 metric 1',
                          '14.15.1.0/24 via 169.254.202.111 dev enp0s8 metric 1',
                          'fa01:1::/64 via fd00::111 dev enp0s3 metric 1',
                          '14.14.2.0/24 via 192.168.204.111 dev enp0s8 metric 1',
                          '14.14.3.0/24 via 192.168.206.111 dev enp0s8 metric 1',
                          'fa01:2::/64 via fd01::111 dev enp0s8 metric 1',
                          'fa01:3::/64 via fd02::111 dev enp0s8 metric 1'],
                          self._nwmock.get_routes())

        self._check_etc_file_list(self._LEFT)


class TestEthToBondingMigration(MigrationBaseTestCase):

    _LEFT = {
        "interfaces": {
            "auto": ["enp0s3", "enp0s3:1-1", "enp0s3:1-2", "enp0s8",
                     "enp0s8:2-3", "enp0s8:2-4", "enp0s8:3-5", "enp0s8:3-6"],
            "enp0s3": {},
            "enp0s3:1-1": {"address": "10.20.1.2/24", "gateway": "10.20.1.1"},
            "enp0s3:1-2": {"address": "fd00::1:2/64", "gateway": "fd00::1"},
            "enp0s8": {"address": "169.254.202.2/24"},
            "enp0s8:2-3": {"address": "192.168.204.2/24"},
            "enp0s8:2-4": {"address": "fd01::2/64"},
            "enp0s8:3-5": {"address": "192.168.206.2/24"},
            "enp0s8:3-6": {"address": "fd02::2/64"}},
        "routes": [
            {"net": "14.14.1.0/24", "via": "10.20.1.111", "dev": "enp0s3", "metric": 1},
            {"net": "14.15.1.0/24", "via": "169.254.202.111", "dev": "enp0s8", "metric": 1},
            {"net": "14.14.2.0/24", "via": "192.168.204.111", "dev": "enp0s8", "metric": 1},
            {"net": "14.14.3.0/24", "via": "192.168.206.111", "dev": "enp0s8", "metric": 1}],
        "routes6": [
            {"net": "fa01:1::/64", "via": "fd00::111", "dev": "enp0s3", "metric": 1},
            {"net": "fa01:2::/64", "via": "fd01::111", "dev": "enp0s8", "metric": 1},
            {"net": "fa01:3::/64", "via": "fd02::111", "dev": "enp0s8", "metric": 1}],
    }

    _RIGHT = {
        "interfaces": {
            "auto": ["enp0s3", "enp0s8", "oam0", "oam0:1-1", "oam0:1-2",
                     "enp0s9", "enp0s10", "pxeboot0", "vlan100", "vlan100:2-3",
                     "vlan100:2-4", "vlan200", "vlan200:3-5", "vlan200:3-6"],
            "enp0s3": {"master": "oam0"},
            "enp0s8": {"master": "oam0"},
            "oam0": {"slaves": ["enp0s3", "enp0s8"], "hwaddress": "08:00:27:f2:66:72"},
            "oam0:1-1": {"address": "10.20.1.2/24", "gateway": "10.20.1.1",
                         "slaves": ["enp0s3", "enp0s8"], "hwaddress": "08:00:27:f2:66:72"},
            "oam0:1-2": {"address": "fd00::1:2/64", "gateway": "fd00::1",
                         "slaves": ["enp0s3", "enp0s8"], "hwaddress": "08:00:27:f2:66:72"},
            "enp0s9": {"master": "pxeboot0"},
            "enp0s10": {"master": "pxeboot0"},
            "pxeboot0": {"address": "169.254.202.2/24", "slaves": ["enp0s9", "enp0s10"],
                         "hwaddress": "08:00:27:f2:67:11"},
            "vlan100": {"raw_dev": "pxeboot0"},
            "vlan100:2-3": {"address": "192.168.204.2/24", "raw_dev": "pxeboot0"},
            "vlan100:2-4": {"address": "fd01::2/64", "raw_dev": "pxeboot0"},
            "vlan200": {"raw_dev": "pxeboot0"},
            "vlan200:3-5": {"address": "192.168.206.2/24", "raw_dev": "pxeboot0"},
            "vlan200:3-6": {"address": "fd02::2/64", "raw_dev": "pxeboot0"}},
        "routes": [
            {"net": "14.14.1.0/24", "via": "10.20.1.111", "dev": "oam0", "metric": 1},
            {"net": "14.15.1.0/24", "via": "169.254.202.111", "dev": "pxeboot0", "metric": 1},
            {"net": "14.14.2.0/24", "via": "192.168.204.111", "dev": "vlan100", "metric": 1},
            {"net": "14.14.3.0/24", "via": "192.168.206.111", "dev": "vlan200", "metric": 1}],
        "routes6": [
            {"net": "fa01:1::/64", "via": "fd00::111", "dev": "oam0", "metric": 1},
            {"net": "fa01:2::/64", "via": "fd01::111", "dev": "vlan100", "metric": 1},
            {"net": "fa01:3::/64", "via": "fd02::111", "dev": "vlan200", "metric": 1}],
    }

    _STATIC_LINKS = ["enp0s3", "enp0s8", "enp0s9", "enp0s10"]

    def test_eth_to_bonding_migration(self):
        self._setup_scenario(self._LEFT, self._RIGHT, self._STATIC_LINKS)

        self._run_apply_config()

        self.assertEqual(['enp0s10 UP SLAVE(pxeboot0)',
                          'enp0s3 UP SLAVE(oam0)',
                          'enp0s8 UP SLAVE(oam0)',
                          'enp0s9 UP SLAVE(pxeboot0)',
                          'oam0 UP BONDING(enp0s3,enp0s8) 10.20.1.2/24 fd00::1:2/64',
                          'pxeboot0 UP BONDING(enp0s9,enp0s10) 169.254.202.2/24',
                          'vlan100 UP VLAN(pxeboot0,100) 192.168.204.2/24 fd01::2/64',
                          'vlan200 UP VLAN(pxeboot0,200) 192.168.206.2/24 fd02::2/64'],
                          self._nwmock.get_links_status())

        self.assertEqual(['default via 10.20.1.1 dev oam0',
                          'default via fd00::1 dev oam0 metric 1024',
                          '14.14.1.0/24 via 10.20.1.111 dev oam0 metric 1',
                          '14.15.1.0/24 via 169.254.202.111 dev pxeboot0 metric 1',
                          '14.14.2.0/24 via 192.168.204.111 dev vlan100 metric 1',
                          '14.14.3.0/24 via 192.168.206.111 dev vlan200 metric 1',
                          'fa01:1::/64 via fd00::111 dev oam0 metric 1',
                          'fa01:2::/64 via fd01::111 dev vlan100 metric 1',
                          'fa01:3::/64 via fd02::111 dev vlan200 metric 1'],
                          self._nwmock.get_routes())

        self._check_etc_file_list(self._RIGHT)

    def test_bonding_to_eth_migration(self):
        self._setup_scenario(self._RIGHT, self._LEFT, self._STATIC_LINKS)

        self._run_apply_config()

        self.assertEqual(['enp0s10 DOWN',
                          'enp0s3 UP 10.20.1.2/24 fd00::1:2/64',
                          'enp0s8 UP 169.254.202.2/24 192.168.204.2/24 192.168.206.2/24 '
                                    'fd01::2/64 fd02::2/64',
                          'enp0s9 DOWN'],
                          self._nwmock.get_links_status())

        self.assertEqual(['default via 10.20.1.1 dev enp0s3',
                          'default via fd00::1 dev enp0s3 metric 1024',
                          '14.14.1.0/24 via 10.20.1.111 dev enp0s3 metric 1',
                          '14.15.1.0/24 via 169.254.202.111 dev enp0s8 metric 1',
                          '14.14.2.0/24 via 192.168.204.111 dev enp0s8 metric 1',
                          '14.14.3.0/24 via 192.168.206.111 dev enp0s8 metric 1',
                          'fa01:1::/64 via fd00::111 dev enp0s3 metric 1',
                          'fa01:2::/64 via fd01::111 dev enp0s8 metric 1',
                          'fa01:3::/64 via fd02::111 dev enp0s8 metric 1'],
                          self._nwmock.get_routes())

        self._check_etc_file_list(self._LEFT)


class TestBondingMigration(MigrationBaseTestCase):
    _LEFT = {
        "interfaces": {
            "auto": ["enp0s3", "enp0s3:1-1", "enp0s3:1-2", "enp0s8", "enp0s8:2-3", "enp0s8:2-4",
                     "enp0s8:3-5", "enp0s8:3-6", "enp0s9", "enp0s10", "data0", "data0:4-7",
                     "data0:4-8", "data1", "data1:5-9", "data1:5-10"],
            "enp0s3": {},
            "enp0s3:1-1": {"address": "10.20.1.2/24", "gateway": "10.20.1.1"},
            "enp0s3:1-2": {"address": "fd00::1:2/64", "gateway": "fd00::1"},
            "enp0s8": {"address": "169.254.202.2/24"},
            "enp0s8:2-3": {"address": "192.168.204.2/24"},
            "enp0s8:2-4": {"address": "fd01::2/64"},
            "enp0s8:3-5": {"address": "192.168.206.2/24"},
            "enp0s8:3-6": {"address": "fd02::2/64"},
            "enp0s9": {"master": "data0"},
            "enp0s10": {"master": "data0"},
            "data0": {"slaves": ["enp0s9", "enp0s10"], "hwaddress": "08:00:27:f2:66:72"},
            "data0:4-7": {"address": "112.154.1.2/24", "slaves": ["enp0s9", "enp0s10"],
                          "hwaddress": "08:00:27:f2:66:72"},
            "data0:4-8": {"address": "fc01:154:1::2/64", "slaves": ["enp0s9", "enp0s10"],
                          "hwaddress": "08:00:27:f2:66:72"},
            "data1": {"raw_dev": "data0", "vlan_id": 50},
            "data1:5-9": {"address": "112.155.1.2/24", "raw_dev": "data0", "vlan_id": 50},
            "data1:5-10": {"address": "fc01:155:1::2/64", "raw_dev": "data0", "vlan_id": 50}},
        "routes": [
            {"net": "14.14.1.0/24", "via": "10.20.1.111", "dev": "enp0s3", "metric": 1},
            {"net": "14.15.1.0/24", "via": "169.254.202.111", "dev": "enp0s8", "metric": 1},
            {"net": "14.14.2.0/24", "via": "192.168.204.111", "dev": "enp0s8", "metric": 1},
            {"net": "14.14.3.0/24", "via": "192.168.206.111", "dev": "enp0s8", "metric": 1},
            {"net": "14.14.4.0/24", "via": "112.154.1.111", "dev": "data0", "metric": 1},
            {"net": "14.14.5.0/24", "via": "112.155.1.111", "dev": "data1", "metric": 1},
        ],
        "routes6": [
            {"net": "fa01:1::/64", "via": "fd00::111", "dev": "enp0s3", "metric": 1},
            {"net": "fa01:2::/64", "via": "fd01::111", "dev": "enp0s8", "metric": 1},
            {"net": "fa01:3::/64", "via": "fd02::111", "dev": "enp0s8", "metric": 1},
            {"net": "fa01:4::/64", "via": "fc01:154:1::111", "dev": "data0", "metric": 1},
            {"net": "fa01:5::/64", "via": "fc01:155:1::111", "dev": "data1", "metric": 1},
        ],
    }

    _RIGHT = {
        "interfaces": {
            "auto": ["enp0s3", "enp0s3:1-1", "enp0s3:1-2", "enp0s8", "enp0s10:2-3", "enp0s10:2-4",
                     "enp0s10:3-5", "enp0s10:3-6", "enp0s9", "enp0s10", "data0", "data0:4-7",
                     "data0:4-8", "data1", "data1:5-9", "data1:5-10"],
            "enp0s3": {},
            "enp0s3:1-1": {"address": "10.20.1.2/24", "gateway": "10.20.1.1"},
            "enp0s3:1-2": {"address": "fd00::1:2/64", "gateway": "fd00::1"},
            "enp0s8": {"master": "data0"},
            "enp0s9": {"master": "data0"},
            "enp0s10": {"address": "169.254.202.2/24"},
            "enp0s10:2-3": {"address": "192.168.204.2/24"},
            "enp0s10:2-4": {"address": "fd01::2/64"},
            "enp0s10:3-5": {"address": "192.168.206.2/24"},
            "enp0s10:3-6": {"address": "fd02::2/64"},
            "data0": {"slaves": ["enp0s8", "enp0s9"], "hwaddress": "08:00:27:f2:66:72"},
            "data0:4-7": {"address": "112.154.1.2/24", "slaves": ["enp0s8", "enp0s9"],
                          "hwaddress": "08:00:27:f2:66:72"},
            "data0:4-8": {"address": "fc01:154:1::2/64", "slaves": ["enp0s8", "enp0s9"],
                          "hwaddress": "08:00:27:f2:66:72"},
            "data1": {"raw_dev": "data0", "vlan_id": 50},
            "data1:5-9": {"address": "112.155.1.2/24", "raw_dev": "data0", "vlan_id": 50},
            "data1:5-10": {"address": "fc01:155:1::2/64", "raw_dev": "data0", "vlan_id": 50}},
        "routes": [
            {"net": "14.14.1.0/24", "via": "10.20.1.111", "dev": "enp0s3", "metric": 1},
            {"net": "14.15.1.0/24", "via": "169.254.202.111", "dev": "enp0s10", "metric": 1},
            {"net": "14.14.2.0/24", "via": "192.168.204.111", "dev": "enp0s10", "metric": 1},
            {"net": "14.14.3.0/24", "via": "192.168.206.111", "dev": "enp0s10", "metric": 1},
            {"net": "14.14.4.0/24", "via": "112.154.1.111", "dev": "data0", "metric": 1},
            {"net": "14.14.5.0/24", "via": "112.155.1.111", "dev": "data1", "metric": 1},
        ],
        "routes6": [
            {"net": "fa01:1::/64", "via": "fd00::111", "dev": "enp0s3", "metric": 1},
            {"net": "fa01:2::/64", "via": "fd01::111", "dev": "enp0s10", "metric": 1},
            {"net": "fa01:3::/64", "via": "fd02::111", "dev": "enp0s10", "metric": 1},
            {"net": "fa01:4::/64", "via": "fc01:154:1::111", "dev": "data0", "metric": 1},
            {"net": "fa01:5::/64", "via": "fc01:155:1::111", "dev": "data1", "metric": 1},
        ],
    }

    _STATIC_LINKS = ["enp0s3", "enp0s8", "enp0s9", "enp0s10"]

    def test_bonding_migration_a(self):
        self._setup_scenario(self._LEFT, self._RIGHT, self._STATIC_LINKS)

        self._run_apply_config()

        self.assertEqual(['data0 UP BONDING(enp0s8,enp0s9) 112.154.1.2/24 fc01:154:1::2/64',
                          'data1 UP VLAN(data0,50) 112.155.1.2/24 fc01:155:1::2/64',
                          'enp0s10 UP 169.254.202.2/24 192.168.204.2/24 192.168.206.2/24 '
                                     'fd01::2/64 fd02::2/64',
                          'enp0s3 UP 10.20.1.2/24 fd00::1:2/64',
                          'enp0s8 UP SLAVE(data0)',
                          'enp0s9 UP SLAVE(data0)'],
                          self._nwmock.get_links_status())

        self.assertEqual(['default via 10.20.1.1 dev enp0s3',
                          'default via fd00::1 dev enp0s3 metric 1024',
                          '14.14.1.0/24 via 10.20.1.111 dev enp0s3 metric 1',
                          'fa01:1::/64 via fd00::111 dev enp0s3 metric 1',
                          '14.15.1.0/24 via 169.254.202.111 dev enp0s10 metric 1',
                          '14.14.2.0/24 via 192.168.204.111 dev enp0s10 metric 1',
                          '14.14.3.0/24 via 192.168.206.111 dev enp0s10 metric 1',
                          '14.14.4.0/24 via 112.154.1.111 dev data0 metric 1',
                          '14.14.5.0/24 via 112.155.1.111 dev data1 metric 1',
                          'fa01:2::/64 via fd01::111 dev enp0s10 metric 1',
                          'fa01:3::/64 via fd02::111 dev enp0s10 metric 1',
                          'fa01:4::/64 via fc01:154:1::111 dev data0 metric 1',
                          'fa01:5::/64 via fc01:155:1::111 dev data1 metric 1'],
                          self._nwmock.get_routes())

        self._check_etc_file_list(self._RIGHT)

    def test_bonding_migration_b(self):
        self._setup_scenario(self._RIGHT, self._LEFT, self._STATIC_LINKS)

        self._run_apply_config()

        self.assertEqual(['data0 UP BONDING(enp0s9,enp0s10) 112.154.1.2/24 fc01:154:1::2/64',
                          'data1 UP VLAN(data0,50) 112.155.1.2/24 fc01:155:1::2/64',
                          'enp0s10 UP SLAVE(data0)',
                          'enp0s3 UP 10.20.1.2/24 fd00::1:2/64',
                          'enp0s8 UP 169.254.202.2/24 192.168.204.2/24 192.168.206.2/24 '
                                    'fd01::2/64 fd02::2/64',
                          'enp0s9 UP SLAVE(data0)'],
                          self._nwmock.get_links_status())

        self.assertEqual(['default via 10.20.1.1 dev enp0s3',
                          'default via fd00::1 dev enp0s3 metric 1024',
                          '14.14.1.0/24 via 10.20.1.111 dev enp0s3 metric 1',
                          'fa01:1::/64 via fd00::111 dev enp0s3 metric 1',
                          '14.15.1.0/24 via 169.254.202.111 dev enp0s8 metric 1',
                          '14.14.2.0/24 via 192.168.204.111 dev enp0s8 metric 1',
                          '14.14.3.0/24 via 192.168.206.111 dev enp0s8 metric 1',
                          '14.14.4.0/24 via 112.154.1.111 dev data0 metric 1',
                          '14.14.5.0/24 via 112.155.1.111 dev data1 metric 1',
                          'fa01:2::/64 via fd01::111 dev enp0s8 metric 1',
                          'fa01:3::/64 via fd02::111 dev enp0s8 metric 1',
                          'fa01:4::/64 via fc01:154:1::111 dev data0 metric 1',
                          'fa01:5::/64 via fc01:155:1::111 dev data1 metric 1'],
                          self._nwmock.get_routes())

        self._check_etc_file_list(self._LEFT)


class TestUpgrade(BaseTestCase):
    _CFG = {
        "interfaces": {
            "auto": ["enp0s3", "enp0s3:1-1", "enp0s3:1-2", "enp0s8", "enp0s8:2-3", "enp0s8:2-4"],
            "lo": {},
            "enp0s3": {},
            "enp0s3:1-1": {"address": "10.20.1.2/24", "gateway": "10.20.1.1"},
            "enp0s3:1-2": {"address": "fd00::1:2/64", "gateway": "fd00::1"},
            "enp0s8": {"address": "169.254.202.2/24"},
            "enp0s8:2-3": {"address": "192.168.204.2/24"},
            "enp0s8:2-4": {"address": "fd01::2/64"}},
    }

    _MIN_CFG = {
        "interfaces": {
            "lo": {},
        }
    }

    _STATIC_LINKS = ["enp0s3", "enp0s8"]

    def _setup_scenario(self, fs_contents):
        self._add_fs_mock(fs_contents)
        self._add_nw_mock(self._STATIC_LINKS)
        self._add_scmd_mock()
        self._add_logger_mock()
        self._fs.set_file_contents(anc.UPGRADE_FILE, '')
        stdout = self._nwmock.apply_auto()
        self.assertEqual("", stdout)

    def _run_update_interfaces(self):
        self._mocked_call([self._mock_fs, self._mock_syscmd,
                           self._mock_sysinv_lock, self._mock_logger], anc.update_interfaces)

    def test_upgrade_no_change(self):
        self._setup_scenario(FILE_GEN.generate_file_tree(
            etc_files=self._CFG, puppet_files=self._CFG))
        self._run_update_interfaces()
        self.assertEqual([
            ('info', 'Upgrade bootstrap is in execution'),
            ('info', 'Configuring interface enp0s3'),
            ('info', 'Configuring interface enp0s8'),
            ('info', 'Configuring interface enp0s3:1-1'),
            ('info', "Link already has address '10.20.1.2/24', no need to set label up"),
            ('info', 'Adding route: default via 10.20.1.1 dev enp0s3'),
            ('info', 'Route already exists, skipping'),
            ('info', 'Configuring interface enp0s3:1-2'),
            ('info', "Link already has address 'fd00::1:2/64', no need to set label up"),
            ('info', 'Adding route: default via fd00::1 dev enp0s3'),
            ('info', 'Route already exists, skipping'),
            ('info', 'Configuring interface enp0s8:2-3'),
            ('info', "Link already has address '192.168.204.2/24', no need to set label up"),
            ('info', 'Configuring interface enp0s8:2-4'),
            ('info', "Link already has address 'fd01::2/64', no need to set label up")],
            self._log.get_history())

    def test_upgrade_none_configured(self):
        self._setup_scenario(FILE_GEN.generate_file_tree(
            etc_files=self._MIN_CFG, puppet_files=self._CFG))
        self._run_update_interfaces()
        self.assertEqual(['enp0s3 UP 10.20.1.2/24 fd00::1:2/64',
                          'enp0s8 UP 169.254.202.2/24 192.168.204.2/24 fd01::2/64'],
                         self._nwmock.get_links_status())
        self.assertEqual(['default via 10.20.1.1 dev enp0s3',
                          'default via fd00::1 dev enp0s3 metric 1024'],
                         self._nwmock.get_routes())
        self.assertEqual([
            ('info', 'Upgrade bootstrap is in execution'),
            ('info', 'Configuring interface enp0s3'),
            ('info', "Interface 'enp0s3' is missing or down, bringing up"),
            ('info', 'Bringing enp0s3 up'),
            ('info', "Interface 'enp0s3' is now up/operational"),
            ('info', 'Configuring interface enp0s8'),
            ('info', "Interface 'enp0s8' is missing or down, bringing up"),
            ('info', 'Bringing enp0s8 up'),
            ('info', "Interface 'enp0s8' is now up/operational"),
            ('info', 'Configuring interface enp0s3:1-1'),
            ('info', 'Bringing enp0s3:1-1 up'),
            ('info', 'Adding IP 10.20.1.2/24 to interface enp0s3'),
            ('info', 'Interface enp0s3 already has address 10.20.1.2/24, skipping'),
            ('info', 'Route adding/replacing: default via 10.20.1.1 dev enp0s3'),
            ('info', 'Configuring interface enp0s3:1-2'),
            ('info', 'Bringing enp0s3:1-2 up'),
            ('info', 'Adding IP fd00::1:2/64 to interface enp0s3'),
            ('info', 'Interface enp0s3 already has address fd00::1:2/64, skipping'),
            ('info', 'Route adding/replacing: default via fd00::1 dev enp0s3'),
            ('info', 'Configuring interface enp0s8:2-3'),
            ('info', 'Bringing enp0s8:2-3 up'),
            ('info', 'Adding IP 192.168.204.2/24 to interface enp0s8'),
            ('info', 'Interface enp0s8 already has address 192.168.204.2/24, skipping'),
            ('info', 'Configuring interface enp0s8:2-4'),
            ('info', 'Bringing enp0s8:2-4 up'),
            ('info', 'Adding IP fd01::2/64 to interface enp0s8'),
            ('info', 'Interface enp0s8 already has address fd01::2/64, skipping')],
            self._log.get_history())

    def test_upgrade_already_configured(self):
        self._setup_scenario(FILE_GEN.generate_file_tree(
            etc_files=self._MIN_CFG, puppet_files=self._CFG))
        self._nwmock.ip_link_set_up("enp0s3")
        self._nwmock.ip_addr_add("10.20.1.2/24", "enp0s3")
        self._nwmock.ip_addr_add("fd00::1:2/64", "enp0s3")
        self._nwmock.ip_route_add("default", "10.20.1.111", "enp0s3", "1")
        self._nwmock.ip_link_set_up("enp0s8")
        self._nwmock.ip_addr_add("192.168.208.2/24", "enp0s8")
        self._run_update_interfaces()
        self.assertEqual([
            'enp0s3 UP 10.20.1.2/24 fd00::1:2/64',
            'enp0s8 UP 169.254.202.2/24 192.168.204.2/24 192.168.208.2/24 fd01::2/64'],
            self._nwmock.get_links_status())
        self.assertEqual(['default via 10.20.1.1 dev enp0s3',
                          'default via fd00::1 dev enp0s3 metric 1024'],
                         self._nwmock.get_routes())
        self.assertEqual([
            ('info', 'Upgrade bootstrap is in execution'),
            ('info', 'Configuring interface enp0s3'),
            ('info', 'Configuring interface enp0s8'),
            ('info', 'Adding IP 169.254.202.2/24 to interface enp0s8'),
            ('info', 'Configuring interface enp0s3:1-1'),
            ('info', "Link already has address '10.20.1.2/24', no need to set label up"),
            ('info', 'Adding route: default via 10.20.1.1 dev enp0s3'),
            ('info', 'Route to specified network already exists, replacing: default via '
                     '10.20.1.111 dev enp0s3 metric 1'),
            ('info', 'Configuring interface enp0s3:1-2'),
            ('info', "Link already has address 'fd00::1:2/64', no need to set label up"),
            ('info', 'Adding route: default via fd00::1 dev enp0s3'),
            ('info', 'Configuring interface enp0s8:2-3'),
            ('info', 'Bringing enp0s8:2-3 up'),
            ('info', 'Adding IP 192.168.204.2/24 to interface enp0s8'),
            ('info', 'Interface enp0s8 already has address 192.168.204.2/24, skipping'),
            ('info', 'Configuring interface enp0s8:2-4'),
            ('info', 'Bringing enp0s8:2-4 up'),
            ('info', 'Adding IP fd01::2/64 to interface enp0s8'),
            ('info', 'Interface enp0s8 already has address fd01::2/64, skipping')],
            self._log.get_history())


class AuditDhcpTests(BaseTestCase):

    def setUp(self):
        super().setUp()
        self._os_kill_call_count = 0

    def os_kill_side_effect(self, _pid, _sig):
        if self._os_kill_call_count == 0:
            self._os_kill_call_count += 1
            raise OSError("No such process")
        self._os_kill_call_count += 1

    def test_start_dhclient_for_bonding_interface(self):
        bond_iface = {
            "ifaces": {
                "bond0": {
                    "iface": "bond0 inet dhcp",
                    "bond-slave": "enp0s8 enp0s9",
                    "bond-mode": "active-backup",
                    "bond-primary": "enp0s8",
                    "bond-miimon": "100",
                }
            }
        }

        dhclient_started = {}

        def mock_popen(cmd, **_kwargs):
            if any("/sbin/ifup" in part for part in cmd):
                dhclient_started["started"] = True

            proc_mock = mock.Mock()
            proc_mock.communicate.return_value = (b"", None)
            proc_mock.returncode = 0
            return proc_mock

        with mock.patch("subprocess.Popen", side_effect=mock_popen), \
            mock.patch("os.path.isfile", return_value=True), \
            mock.patch("builtins.open", mock.mock_open(read_data="9999")), \
            mock.patch("os.kill", side_effect=self.os_kill_side_effect):

            anc.audit_dhcp_ifaces(bond_iface)

        self.assertTrue(dhclient_started.get("started", False),
                        "Expected dhclient to be started for interface bond0")

    def test_dhclient_running_for_bonding_interface(self):
        bond_iface = {
            "ifaces": {
                "bond0": {
                    "iface": "bond0 inet dhcp",
                    "bond-slave": "enp0s8 enp0s9",
                    "bond-mode": "active-backup",
                    "bond-primary": "enp0s8",
                    "bond-miimon": "100",
                }
            }
        }

        dhclient_started = {}

        self._os_kill_call_count = 1

        with mock.patch("os.path.isfile", return_value=True), \
            mock.patch("builtins.open", mock.mock_open(read_data="1234")), \
            mock.patch("os.kill", side_effect=self.os_kill_side_effect):

            anc.audit_dhcp_ifaces(bond_iface)

        self.assertFalse(dhclient_started.get("started", False),
                         "dhclient should not be restarted if already running")

    def test_ethernet_iface_without_dhclient_pid_file(self):
        contents = dict()
        contents[anc.ETC_DIR + "/ifcfg-enp0s8"] = (
            "iface enp0s8 inet dhcp\n"
            "mtu 9216\n"
            "post-up echo 0 > /proc/sys/net/ipv6/conf/enp0s8/autoconf; "
            "echo 0 > /proc/sys/net/ipv6/conf/enp0s8/accept_ra; "
            "echo 0 > /proc/sys/net/ipv6/conf/enp0s8/accept_redirects; "
            "echo 1 > /proc/sys/net/ipv6/conf/bond0/keep_addr_on_down\n"
            "stx-description ifname:pxeboot0,net:pxeboot")

        self._add_fs_mock(contents)

        eth_iface = "enp0s8"
        ifstate_path = f"/run/network/ifstate.{eth_iface}"
        self._fs.set_file_contents(ifstate_path, eth_iface)

        dhclient_started = {}

        def mock_popen(cmd, **_kwargs):
            if any("/sbin/ifup" in part for part in cmd):
                dhclient_started["started"] = True
            proc_mock = mock.Mock()
            proc_mock.communicate.return_value = (b"", None)
            proc_mock.returncode = 0
            return proc_mock

        self._os_kill_call_count = 1

        with mock.patch("subprocess.Popen", side_effect=mock_popen), \
            mock.patch("os.path.isfile", side_effect=[False, True]), \
            mock.patch("builtins.open", mock.mock_open(read_data="9999")), \
            mock.patch("os.kill", side_effect=self.os_kill_side_effect):

            self._mocked_call([self._mock_fs], anc.audit_config)

        self.assertTrue(dhclient_started.get("started", False),
                        "Expected dhclient to be started for interface enp0s8")

    def test_start_dhclient_eth_iface_process_not_running(self):
        contents = dict()
        contents[anc.ETC_DIR + "/ifcfg-enp0s8"] = (
            "iface enp0s8 inet dhcp\n"
            "mtu 9216\n"
            "post-up echo 0 > /proc/sys/net/ipv6/conf/enp0s8/autoconf; "
            "echo 0 > /proc/sys/net/ipv6/conf/enp0s8/accept_ra; "
            "echo 0 > /proc/sys/net/ipv6/conf/enp0s8/accept_redirects; "
            "echo 1 > /proc/sys/net/ipv6/conf/bond0/keep_addr_on_down\n"
            "stx-description ifname:pxeboot0,net:pxeboot")

        self._add_fs_mock(contents)

        eth_iface = "enp0s8"
        ifstate_path = f"/run/network/ifstate.{eth_iface}"
        self._fs.set_file_contents(ifstate_path, eth_iface)

        dhclient_started = {}

        def mock_popen(cmd, **_kwargs):
            if any("/sbin/ifup" in part for part in cmd):
                dhclient_started["started"] = True

            proc_mock = mock.Mock()
            proc_mock.communicate.return_value = (b"", None)
            proc_mock.returncode = 0
            return proc_mock

        with mock.patch("subprocess.Popen", side_effect=mock_popen), \
             mock.patch("os.path.isfile", return_value=True), \
             mock.patch("builtins.open", mock.mock_open(read_data="9999")), \
             mock.patch("os.kill", side_effect=self.os_kill_side_effect):

            self._mocked_call([self._mock_fs], anc.audit_config)

        self.assertTrue(dhclient_started.get("started", False),
                        f"Expected dhclient to be started for interface {eth_iface}")

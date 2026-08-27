#
# Copyright (c) 2026 Wind River Systems, Inc.
#
# SPDX-License-Identifier: Apache-2.0
#


"""Unit tests for apply_network_config.py edge cases."""

import subprocess
import unittest
from unittest.mock import MagicMock
from unittest.mock import patch

import debian.bullseye.src.bin.apply_network_config as anc


class TestAncExecuteSystemCmd(unittest.TestCase):
    """Tests for execute_system_cmd() timeout handling."""

    @patch('debian.bullseye.src.bin.apply_network_config.os.killpg')
    @patch('debian.bullseye.src.bin.apply_network_config.os.getpgid', return_value=12345)
    def test_timeout_sigterm_then_sigkill(self, _mock_pgid, mock_killpg):
        """Should send SIGTERM then SIGKILL on double timeout."""
        mock_proc = MagicMock()
        mock_proc.pid = 999
        mock_proc.communicate.side_effect = [
            subprocess.TimeoutExpired('cmd', 30),
            subprocess.TimeoutExpired('cmd', 10),
            (b'output', None)
        ]
        mock_proc.returncode = -9
        with patch('debian.bullseye.src.bin.apply_network_config.subprocess.Popen',
                   return_value=mock_proc):
            _, _ = anc.execute_system_cmd('sleep 100', timeout=1)
        self.assertEqual(mock_killpg.call_count, 2)


class TestAncGetVlanAttributes(unittest.TestCase):
    """Tests for get_vlan_attributes()."""

    def test_vlan_dot_notation(self):
        """Should parse eth0.100 as VLAN."""
        result = anc.get_vlan_attributes('eth0.100', {})
        self.assertEqual(result, ('eth0', 100))

    def test_vlan_nnn_with_raw_device(self):
        """Should parse vlan100 with vlan-raw-device."""
        result = anc.get_vlan_attributes('vlan100', {'vlan-raw-device': 'eth0'})
        self.assertEqual(result, ('eth0', 100))

    def test_vlan_nnn_without_raw_device(self):
        """Should return None for vlan100 without vlan-raw-device."""
        with patch('debian.bullseye.src.bin.apply_network_config.LOG'):
            result = anc.get_vlan_attributes('vlan100', {})
        self.assertIsNone(result)

    def test_not_vlan(self):
        """Should return None for non-VLAN interface."""
        result = anc.get_vlan_attributes('eth0', {})
        self.assertIsNone(result)

    def test_preup_ip_link_add(self):
        """Should parse VLAN from pre-up ip link add command."""
        config = {'pre-up': 'ip link add link eth0 name eth0.200 type vlan id 200'}
        result = anc.get_vlan_attributes('myvlan', config)
        self.assertEqual(result, ('eth0', 200))


class TestAncGetTypesAndDependencies(unittest.TestCase):
    """Tests for get_types_and_dependencies()."""

    def test_eth_type(self):
        """Should classify plain interface as ETH."""
        ifaces = {'eth0': {'iface': 'eth0 inet static'}}
        types, _ = anc.get_types_and_dependencies(ifaces)
        self.assertEqual(types['eth0'], 'eth')

    def test_lo_type(self):
        """Should classify lo as LO."""
        ifaces = {'lo': {'iface': 'lo inet loopback'}}
        types, _ = anc.get_types_and_dependencies(ifaces)
        self.assertEqual(types['lo'], 'lo')

    def test_label_type(self):
        """Should classify eth0:1 as LABEL with dependency."""
        ifaces = {'eth0:1': {'iface': 'eth0:1 inet static'}}
        types, deps = anc.get_types_and_dependencies(ifaces)
        self.assertEqual(types['eth0:1'], 'label')
        self.assertIn('eth0:1', deps.get('eth0', set()))

    def test_bonding_type(self):
        """Should classify bond with bond-slaves as BONDING."""
        ifaces = {'bond0': {'iface': 'bond0 inet static', 'bond-slaves': 'eth0 eth1'}}
        types, _ = anc.get_types_and_dependencies(ifaces)
        self.assertEqual(types['bond0'], 'bonding')

    def test_slave_type(self):
        """Should classify interface with bond-master as SLAVE."""
        ifaces = {'eth0': {'iface': 'eth0 inet manual', 'bond-master': 'bond0'}}
        types, _ = anc.get_types_and_dependencies(ifaces)
        self.assertEqual(types['eth0'], 'slave')


class TestAncCompareConfigs(unittest.TestCase):
    """Tests for compare_configs()."""

    def test_added_interface(self):
        """Should detect added interfaces."""
        iface_cfg = {'iface': 'eth0 inet static', 'address': '10.0.0.1'}
        new = {'auto': {'eth0', 'eth1'},
               'ifaces': {'eth0': iface_cfg, 'eth1': iface_cfg},
               'ifaces_types': {}, 'dependencies': {}}
        cur = {'auto': {'eth0'}, 'ifaces': {'eth0': iface_cfg},
               'ifaces_types': {}, 'dependencies': {}}
        with patch('debian.bullseye.src.bin.apply_network_config.LOG'):
            result = anc.compare_configs(new, cur)
        self.assertIn('eth1', result['added'])

    def test_removed_interface(self):
        """Should detect removed interfaces."""
        iface_cfg = {'iface': 'eth0 inet static', 'address': '10.0.0.1'}
        new = {'auto': {'eth0'}, 'ifaces': {'eth0': iface_cfg},
               'ifaces_types': {}, 'dependencies': {}}
        cur = {'auto': {'eth0', 'eth1'},
               'ifaces': {'eth0': iface_cfg, 'eth1': iface_cfg},
               'ifaces_types': {}, 'dependencies': {}}
        with patch('debian.bullseye.src.bin.apply_network_config.LOG'):
            result = anc.compare_configs(new, cur)
        self.assertIn('eth1', result['removed'])

    def test_no_changes(self):
        """Should return empty sets when configs are identical."""
        cfg = {'auto': {'eth0'}, 'ifaces': {'eth0': {'iface': 'eth0 inet static'}},
               'ifaces_types': {}, 'dependencies': {}}
        with patch('debian.bullseye.src.bin.apply_network_config.LOG'):
            result = anc.compare_configs(cfg, cfg)
        self.assertEqual(len(result['added']), 0)
        self.assertEqual(len(result['removed']), 0)


class TestAncGetDownAndUpList(unittest.TestCase):
    """Tests for get_down_list and get_up_list."""

    @patch('debian.bullseye.src.bin.apply_network_config.is_iface_up', return_value=False)
    @patch('debian.bullseye.src.bin.apply_network_config.LOG')
    def test_get_down_list_modified(self, _mock_log, _mock_up):
        """Should include modified interfaces in down list."""
        cur = {'auto': {'eth0'}, 'ifaces': {}, 'ifaces_types': {'eth0': 'eth'},
               'dependencies': {}}
        new = {'auto': {'eth0'}, 'ifaces': {}, 'ifaces_types': {'eth0': 'eth'},
               'dependencies': {}}
        comparison = {'modified': {'eth0'}, 'removed': set(), 'added': set()}
        result = anc.get_down_list(cur, new, comparison)
        self.assertIn('eth0', result)

    @patch('debian.bullseye.src.bin.apply_network_config.is_iface_missing_or_down',
           return_value=False)
    @patch('debian.bullseye.src.bin.apply_network_config.LOG')
    def test_get_up_list_added(self, _mock_log, _mock_down):
        """Should include added interfaces in up list."""
        new = {'auto': {'eth0', 'eth1'}, 'ifaces': {},
               'ifaces_types': {'eth0': 'eth', 'eth1': 'eth'}, 'dependencies': {}}
        comparison = {'modified': set(), 'removed': set(), 'added': {'eth1'}}
        result = anc.get_up_list(new, comparison)
        self.assertIn('eth1', result)


class TestAncSortIfacesByType(unittest.TestCase):
    """Tests for sort_ifaces_by_type()."""

    def test_sort_order(self):
        """Should sort interfaces by DOWN_ORDER."""
        config = {'ifaces_types': {
            'eth0': 'eth', 'vlan100': 'vlan', 'lo': 'lo', 'eth0:1': 'label'
        }}
        ifaces = {'eth0', 'vlan100', 'lo', 'eth0:1'}
        result = anc.sort_ifaces_by_type(config, ifaces, anc.DOWN_ORDER)
        types_order = [config['ifaces_types'][i] for i in result]
        # label before vlan before eth before lo in DOWN_ORDER
        self.assertEqual(types_order, ['label', 'vlan', 'eth', 'lo'])


class TestAncCreateRouteObjFromEntry(unittest.TestCase):
    """Tests for create_route_obj_from_entry()."""

    def test_basic_route(self):
        """Should parse basic route entry."""
        entry = '10.0.0.0 255.255.255.0 10.0.0.1 eth0'
        result = anc.create_route_obj_from_entry(entry)
        self.assertEqual(result['network'], '10.0.0.0')
        self.assertEqual(result['netmask'], '255.255.255.0')
        self.assertEqual(result['nexthop'], '10.0.0.1')
        self.assertEqual(result['ifname'], 'eth0')

    def test_route_with_metric_and_src(self):
        """Should parse route with metric and src."""
        entry = '10.0.0.0 255.255.255.0 10.0.0.1 eth0 metric 100 src 10.0.0.2'
        result = anc.create_route_obj_from_entry(entry)
        self.assertEqual(result['metric'], '100')
        self.assertEqual(result['src'], '10.0.0.2')


class TestAncGetLinuxNetwork(unittest.TestCase):
    """Tests for get_linux_network()."""

    def test_default_route(self):
        """Should return 'default' for default network."""
        route = {'network': 'default', 'netmask': '0.0.0.0'}
        result = anc.get_linux_network(route)
        self.assertEqual(result, 'default')

    def test_cidr_conversion(self):
        """Should convert netmask to CIDR notation."""
        route = {'network': '10.0.0.0', 'netmask': '255.255.255.0'}
        result = anc.get_linux_network(route)
        self.assertEqual(result, '10.0.0.0/24')

    def test_invalid_netmask_raises(self):
        """Should raise InvalidNetmaskError for bad netmask."""
        route = {'network': '10.0.0.0', 'netmask': 'invalid'}
        with self.assertRaises(anc.InvalidNetmaskError):
            anc.get_linux_network(route)


class TestAncIsIfaceUp(unittest.TestCase):
    """Tests for is_iface_up()."""

    @patch('debian.bullseye.src.bin.apply_network_config.read_file_text',
           return_value='eth0')
    @patch('os.path.isfile', return_value=True)
    def test_iface_up_via_ifstate(self, _mock_isfile, _mock_read):
        """Should return True if ifstate file matches."""
        result = anc.is_iface_up('eth0')
        self.assertTrue(result)

    @patch('debian.bullseye.src.bin.apply_network_config.read_file_text',
           side_effect=['other', 'up'])
    @patch('os.path.isfile', return_value=True)
    def test_iface_up_via_operstate(self, _mock_isfile, _mock_read):
        """Should return True if operstate is up."""
        result = anc.is_iface_up('eth0')
        self.assertTrue(result)

    def test_label_not_up(self):
        """Should return False for label interface without ifstate."""
        with patch('os.path.isfile', return_value=False):
            result = anc.is_iface_up('eth0:1')
        self.assertFalse(result)


class TestAncGetIfacesWithDhcp(unittest.TestCase):
    """Tests for get_ifaces_with_dhcp()."""

    def test_finds_dhcp_ifaces(self):
        """Should find interfaces configured with DHCP."""
        config = {
            'ifaces': {
                'eth0': {'iface': 'eth0 inet dhcp'},
                'eth1': {'iface': 'eth1 inet static'},
            }
        }
        result = anc.get_ifaces_with_dhcp(config)
        self.assertEqual(result, ['eth0'])

    def test_no_dhcp_ifaces(self):
        """Should return empty list when no DHCP interfaces."""
        config = {'ifaces': {'eth0': {'iface': 'eth0 inet static'}}}
        result = anc.get_ifaces_with_dhcp(config)
        self.assertEqual(result, [])


class TestAncPathExists(unittest.TestCase):
    """Tests for path_exists()."""

    @patch('os.path.exists', return_value=True)
    def test_path_exists_true(self, _mock_exists):
        """Should return True when path exists."""
        self.assertTrue(anc.path_exists('/some/path'))

    @patch('os.path.exists', return_value=False)
    def test_path_exists_false(self, _mock_exists):
        """Should return False when path does not exist."""
        self.assertFalse(anc.path_exists('/some/path'))


class TestAncValidateSrcIp(unittest.TestCase):
    """Tests for validate_src_ip() error paths."""

    def test_no_src(self):
        """Should return True when no src in route."""
        route = {'ifname': 'eth0'}
        self.assertTrue(anc.validate_src_ip(route))

    def test_no_ifname(self):
        """Should return True when no ifname in route."""
        route = {'src': '10.0.0.1'}
        self.assertTrue(anc.validate_src_ip(route))

    def test_ipv4_returns_true(self):
        """Should return True for IPv4 src (no DAD check)."""
        route = {'src': '10.0.0.1', 'ifname': 'eth0'}
        self.assertTrue(anc.validate_src_ip(route))

    @patch('debian.bullseye.src.bin.apply_network_config._get_iface_addr_info',
           return_value=None)
    def test_ipv6_addr_info_none(self, _mock_info):
        """Should return False if addr_info is None for IPv6."""
        route = {'src': 'fd00::1', 'ifname': 'eth0'}
        with patch('debian.bullseye.src.bin.apply_network_config.LOG'):
            result = anc.validate_src_ip(route)
        self.assertFalse(result)


class TestAncStanzaParserAdditional(unittest.TestCase):
    """Tests for StanzaParser edge cases."""

    def test_parse_empty_lines(self):
        """Should handle empty lines gracefully."""
        lines = ['', '  ', '# comment']
        auto, ifaces = anc.StanzaParser.ParseLines(lines)
        self.assertEqual(auto, [])
        self.assertEqual(ifaces, {})

    def test_parse_allow_property(self):
        """Should handle allow- properties."""
        lines = [
            'auto eth0',
            'iface eth0 inet static',
            'address 10.0.0.1',
            'allow-hotplug eth0',
        ]
        _, ifaces = anc.StanzaParser.ParseLines(lines)
        self.assertIn('eth0', ifaces)
        self.assertIn('allow-', ifaces['eth0'])

    def test_parse_multiple_auto(self):
        """Should handle multiple auto lines."""
        lines = [
            'auto lo',
            'iface lo inet loopback',
            '',
            'auto eth0',
            'iface eth0 inet static',
            'address 10.0.0.1',
        ]
        auto, _ = anc.StanzaParser.ParseLines(lines)
        self.assertIn('lo', auto)
        self.assertIn('eth0', auto)

    def test_duplicate_auto_ignored(self):
        """Should not duplicate auto entries."""
        lines = [
            'auto eth0',
            'auto eth0',
            'iface eth0 inet static',
        ]
        auto, _ = anc.StanzaParser.ParseLines(lines)
        self.assertEqual(auto.count('eth0'), 1)

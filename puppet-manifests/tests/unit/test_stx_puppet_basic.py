#
# Copyright (c) 2026 Wind River Systems, Inc.
#
# SPDX-License-Identifier: Apache-2.0


"""Basic unit tests for stx-puppet Python source modules.

Tests cover imports, module structure, and core utility functions from
apply_network_config, parse_sriov, and puppet-update-grub-env.
"""

import importlib
import unittest
import subprocess
from unittest.mock import MagicMock
from unittest.mock import mock_open
from unittest.mock import patch


# Safe direct imports for modules without import-time side effects
from debian.bullseye.src.bin.apply_network_config import InvalidNetmaskError
from debian.bullseye.src.bin.apply_network_config import StanzaParser
from debian.bullseye.src.bin.apply_network_config import format_stdout
from debian.bullseye.src.bin.apply_network_config import get_base_iface
from debian.bullseye.src.bin.apply_network_config import get_prefix_length
from debian.bullseye.src.bin.apply_network_config import get_route_description
from debian.bullseye.src.bin.apply_network_config import is_label
from debian.bullseye.src.bin.apply_network_config import read_file_lines
from debian.bullseye.src.bin.apply_network_config import read_file_text
from debian.bullseye.src.bin.apply_network_config import sort_properties
from debian.bullseye.src.bin.parse_sriov import chunk_list
from debian.bullseye.src.bin.parse_sriov import execute_command

# puppet-update-grub-env.py has a hyphen in the filename
grub_env = importlib.import_module('debian.bullseye.src.bin.puppet-update-grub-env')
convert_value_to_dict = grub_env.convert_value_to_dict
convert_dict_to_value = grub_env.convert_dict_to_value


class TestStanzaParser(unittest.TestCase):
    """Tests for StanzaParser from apply_network_config."""

    def test_parse_single_iface(self):
        """Parse a single interface stanza."""
        lines = [
            "auto eth0",
            "iface eth0 inet static",
            "  address 10.0.0.1",
            "  netmask 255.255.255.0",
        ]
        auto, ifaces = StanzaParser.ParseLines(lines)
        self.assertEqual(auto, ["eth0"])
        self.assertIn("eth0", ifaces)
        self.assertEqual(ifaces["eth0"]["address"], "10.0.0.1")
        self.assertEqual(ifaces["eth0"]["netmask"], "255.255.255.0")

    def test_parse_multiple_ifaces(self):
        """Parse multiple interface stanzas."""
        lines = [
            "auto lo",
            "iface lo inet loopback",
            "",
            "auto eth0",
            "iface eth0 inet static",
            "  address 192.168.1.1",
            "  netmask 255.255.255.0",
            "",
            "auto eth1",
            "iface eth1 inet dhcp",
        ]
        auto, ifaces = StanzaParser.ParseLines(lines)
        self.assertEqual(auto, ["lo", "eth0", "eth1"])
        self.assertEqual(len(ifaces), 3)

    def test_parse_empty_input(self):
        """Parse empty input returns empty results."""
        auto, ifaces = StanzaParser.ParseLines([])
        self.assertEqual(auto, [])
        self.assertEqual(ifaces, {})

    def test_parse_comments_ignored(self):
        """Comments are ignored during parsing."""
        lines = [
            "# This is a comment",
            "auto eth0",
            "iface eth0 inet static",
            "# Another comment",
            "  address 10.0.0.1",
        ]
        auto, ifaces = StanzaParser.ParseLines(lines)
        self.assertEqual(auto, ["eth0"])
        self.assertEqual(ifaces["eth0"]["address"], "10.0.0.1")

    def test_parse_vlan_interface(self):
        """Parse a VLAN interface stanza."""
        lines = [
            "auto vlan100",
            "iface vlan100 inet static",
            "  vlan-raw-device eth0",
            "  address 10.10.0.1",
            "  netmask 255.255.255.0",
        ]
        _, ifaces = StanzaParser.ParseLines(lines)
        self.assertIn("vlan100", ifaces)
        self.assertEqual(ifaces["vlan100"]["vlan-raw-device"], "eth0")

    def test_parse_bond_interface(self):
        """Parse a bonding interface stanza."""
        lines = [
            "auto bond0",
            "iface bond0 inet static",
            "  bond-slaves eth0 eth1",
            "  bond-mode active-backup",
            "  bond-miimon 100",
            "  address 10.0.0.1",
        ]
        _, ifaces = StanzaParser.ParseLines(lines)
        self.assertIn("bond0", ifaces)
        self.assertEqual(ifaces["bond0"]["bond-slaves"], "eth0 eth1")
        self.assertEqual(ifaces["bond0"]["bond-mode"], "active-backup")

    def test_parse_duplicate_auto_ignored(self):
        """Duplicate auto entries are deduplicated."""
        lines = [
            "auto eth0",
            "auto eth0",
            "iface eth0 inet static",
            "  address 10.0.0.1",
        ]
        auto, _ = StanzaParser.ParseLines(lines)
        self.assertEqual(auto, ["eth0"])

    def test_parse_allow_property(self):
        """Parse allow- property in stanza."""
        lines = [
            "auto eth0",
            "iface eth0 inet static",
            "  address 10.0.0.1",
            "  allow-hotplug eth0",
        ]
        _, ifaces = StanzaParser.ParseLines(lines)
        self.assertEqual(ifaces["eth0"]["allow-"], "allow-hotplug eth0")

    def test_parse_label_interface(self):
        """Parse a label (alias) interface stanza."""
        lines = [
            "auto eth0:1",
            "iface eth0:1 inet static",
            "  address 10.0.0.2",
            "  netmask 255.255.255.0",
        ]
        _, ifaces = StanzaParser.ParseLines(lines)
        self.assertIn("eth0:1", ifaces)


class TestConvertValueToDict(unittest.TestCase):
    """Tests for convert_value_to_dict from puppet-update-grub-env."""

    def test_simple_key_value(self):
        """Convert simple key=value pairs."""
        result = convert_value_to_dict("console=ttyS0 quiet")
        self.assertEqual(result["console"], "ttyS0")
        self.assertEqual(result["quiet"], "")

    def test_empty_string(self):
        """Convert empty string returns empty dict."""
        result = convert_value_to_dict("")
        self.assertEqual(result, {})

    def test_hugepage_params(self):
        """Convert hugepage parameters are cached together."""
        value = "default_hugepagesz=2M hugepagesz=2M hugepages=256"
        result = convert_value_to_dict(value)
        self.assertIn("hugepage", result)
        self.assertIn("default_hugepagesz=2M", result["hugepage"])
        self.assertIn("hugepagesz=2M", result["hugepage"])
        self.assertIn("hugepages=256", result["hugepage"])

    def test_multiple_params(self):
        """Convert multiple kernel parameters."""
        value = "console=ttyS0,115200 iommu=pt intel_iommu=on"
        result = convert_value_to_dict(value)
        self.assertEqual(result["console"], "ttyS0,115200")
        self.assertEqual(result["iommu"], "pt")
        self.assertEqual(result["intel_iommu"], "on")


class TestConvertDictToValue(unittest.TestCase):
    """Tests for convert_dict_to_value from puppet-update-grub-env."""

    def test_simple_dict(self):
        """Convert simple dict to kernel_params string."""
        params_dict = {"console": "ttyS0", "quiet": ""}
        result = convert_dict_to_value(params_dict)
        self.assertTrue(result.startswith("kernel_params="))
        self.assertIn("console=ttyS0", result)
        self.assertIn(" quiet", result)

    def test_hugepage_appended(self):
        """Hugepage key is appended at the end."""
        params_dict = {"console": "ttyS0", "hugepage": "hugepagesz=2M hugepages=256"}
        result = convert_dict_to_value(params_dict)
        self.assertIn("hugepagesz=2M hugepages=256", result)

    def test_empty_dict(self):
        """Convert empty dict returns kernel_params= prefix."""
        result = convert_dict_to_value({})
        self.assertEqual(result, "kernel_params=")

    def test_roundtrip(self):
        """Value -> dict -> value roundtrip preserves content."""
        original = "console=ttyS0 iommu=pt quiet"
        params_dict = convert_value_to_dict(original)
        result = convert_dict_to_value(params_dict)
        for param in ["console=ttyS0", "iommu=pt", "quiet"]:
            self.assertIn(param, result)


class TestIsLabel(unittest.TestCase):
    """Tests for is_label from apply_network_config."""

    def test_label_interface(self):
        """Interface with colon is a label."""
        self.assertTrue(is_label("eth0:1"))

    def test_non_label_interface(self):
        """Interface without colon is not a label."""
        self.assertFalse(is_label("eth0"))

    def test_vlan_not_label(self):
        """VLAN interface is not a label."""
        self.assertFalse(is_label("vlan100"))

    def test_bond_not_label(self):
        """Bond interface is not a label."""
        self.assertFalse(is_label("bond0"))


class TestGetBaseIface(unittest.TestCase):
    """Tests for get_base_iface from apply_network_config."""

    def test_label_returns_base(self):
        """Label interface returns base name."""
        self.assertEqual(get_base_iface("eth0:1"), "eth0")

    def test_plain_returns_self(self):
        """Plain interface returns itself."""
        self.assertEqual(get_base_iface("eth0"), "eth0")

    def test_multiple_colons(self):
        """Multiple colons returns first segment."""
        self.assertEqual(get_base_iface("eth0:1:2"), "eth0")


class TestGetPrefixLength(unittest.TestCase):
    """Tests for get_prefix_length from apply_network_config."""

    VALID_NETMASKS = [
        ("255.255.255.0", 24),
        ("255.255.0.0", 16),
        ("255.0.0.0", 8),
        ("255.255.255.128", 25),
        ("255.255.255.252", 30),
        ("255.255.255.255", 32),
    ]

    def test_valid_netmasks(self):
        """Valid netmasks return correct prefix lengths."""
        for netmask, expected in self.VALID_NETMASKS:
            with self.subTest(netmask=netmask):
                self.assertEqual(get_prefix_length(netmask), expected)

    def test_invalid_netmask_raises(self):
        """Invalid netmask raises InvalidNetmaskError."""
        with self.assertRaises(InvalidNetmaskError):
            get_prefix_length("999.999.999.999")

    def test_non_netmask_ip_raises(self):
        """Valid IP that is not a netmask raises InvalidNetmaskError."""
        with self.assertRaises(InvalidNetmaskError):
            get_prefix_length("10.0.0.1")

    def test_empty_string_raises(self):
        """Empty string raises InvalidNetmaskError."""
        with self.assertRaises(InvalidNetmaskError):
            get_prefix_length("")


class TestExecuteCommand(unittest.TestCase):
    """Tests for execute_command from parse_sriov."""

    @patch('debian.bullseye.src.bin.parse_sriov.subprocess.run')
    def test_successful_command(self, mock_run):
        """Successful command returns True and stdout."""
        mock_run.return_value = MagicMock(
            stdout="output", stderr="", returncode=0)
        success, msg = execute_command(["echo", "hello"])
        self.assertTrue(success)
        self.assertIn("output", msg)

    @patch('debian.bullseye.src.bin.parse_sriov.subprocess.run')
    def test_command_with_stderr(self, mock_run):
        """Command with stderr returns False."""
        mock_run.return_value = MagicMock(
            stdout="", stderr="error occurred", returncode=0)
        success, msg = execute_command(["cmd"])
        self.assertFalse(success)
        self.assertIn("error occurred", msg)

    @patch('debian.bullseye.src.bin.parse_sriov.subprocess.run')
    def test_command_with_skipping_stderr(self, mock_run):
        """Command with 'skipping' in stderr is not treated as error."""
        mock_run.return_value = MagicMock(
            stdout="ok", stderr="Skipping device", returncode=0)
        success, _ = execute_command(["cmd"])
        self.assertTrue(success)

    @patch('debian.bullseye.src.bin.parse_sriov.subprocess.run')
    def test_called_process_error(self, mock_run):
        """CalledProcessError returns False with error details."""
        mock_run.side_effect = subprocess.CalledProcessError(
            1, "cmd", output="out", stderr="err")
        success, msg = execute_command(["cmd"])
        self.assertFalse(success)
        self.assertIn("CalledProcessError", msg)

    @patch('debian.bullseye.src.bin.parse_sriov.subprocess.run')
    def test_timeout_expired(self, mock_run):
        """TimeoutExpired returns False."""
        mock_run.side_effect = subprocess.TimeoutExpired("cmd", 30)
        success, msg = execute_command(["cmd"])
        self.assertFalse(success)
        self.assertIn("TimeoutExpired", msg)


class TestChunkList(unittest.TestCase):
    """Tests for chunk_list from parse_sriov."""

    def test_even_chunks(self):
        """List evenly divisible by chunk size."""
        result = list(chunk_list([1, 2, 3, 4], 2))
        self.assertEqual(result, [[1, 2], [3, 4]])

    def test_uneven_chunks(self):
        """List not evenly divisible by chunk size."""
        result = list(chunk_list([1, 2, 3, 4, 5], 2))
        self.assertEqual(result, [[1, 2], [3, 4], [5]])

    def test_single_chunk(self):
        """Chunk size larger than list returns single chunk."""
        result = list(chunk_list([1, 2, 3], 10))
        self.assertEqual(result, [[1, 2, 3]])

    def test_empty_list(self):
        """Empty list yields no chunks."""
        result = list(chunk_list([], 5))
        self.assertEqual(result, [])

    def test_chunk_size_one(self):
        """Chunk size of 1 yields individual elements."""
        result = list(chunk_list(["a", "b", "c"], 1))
        self.assertEqual(result, [["a"], ["b"], ["c"]])


class TestReadFileLines(unittest.TestCase):
    """Tests for read_file_lines from apply_network_config."""

    def test_read_lines(self):
        """Read file returns stripped lines."""
        data = "line1\nline2\n  line3  \n"
        with patch('builtins.open', mock_open(read_data=data)):
            result = read_file_lines("/fake/path")
        self.assertEqual(result, ["line1", "line2", "line3"])

    def test_read_empty_file(self):
        """Read empty file returns empty list."""
        with patch('builtins.open', mock_open(read_data="")):
            result = read_file_lines("/fake/path")
        self.assertEqual(result, [])


class TestReadFileText(unittest.TestCase):
    """Tests for read_file_text from apply_network_config."""

    def test_read_text(self):
        """Read file returns full text content."""
        data = "hello world\nsecond line"
        with patch('builtins.open', mock_open(read_data=data)):
            result = read_file_text("/fake/path")
        self.assertEqual(result, data)

    def test_read_empty_text(self):
        """Read empty file returns empty string."""
        with patch('builtins.open', mock_open(read_data="")):
            result = read_file_text("/fake/path")
        self.assertEqual(result, "")


class TestFormatStdout(unittest.TestCase):
    """Tests for format_stdout from apply_network_config."""

    def test_single_line(self):
        """Single line output is quoted inline."""
        result = format_stdout("hello")
        self.assertEqual(result, " 'hello'")

    def test_multiline(self):
        """Multi-line output is formatted with newline prefix."""
        result = format_stdout("line1\nline2")
        self.assertEqual(result, "\nline1\nline2")

    def test_whitespace_stripped(self):
        """Leading/trailing whitespace is stripped."""
        result = format_stdout("  hello  ")
        self.assertEqual(result, " 'hello'")

    def test_empty_string(self):
        """Empty string returns quoted empty."""
        result = format_stdout("")
        self.assertEqual(result, " ''")


class TestSortProperties(unittest.TestCase):
    """Tests for sort_properties from apply_network_config."""

    def test_known_properties_sorted(self):
        """Known properties are sorted by defined order."""
        props = ["mtu", "address", "iface", "gateway"]
        result = sort_properties(props)
        self.assertEqual(result, ["iface", "address", "gateway", "mtu"])

    def test_unknown_properties_after_known(self):
        """Unknown properties sort after known ones."""
        props = ["custom-prop", "iface", "address"]
        result = sort_properties(props)
        self.assertEqual(result[0], "iface")
        self.assertEqual(result[1], "address")
        self.assertEqual(result[2], "custom-prop")

    def test_empty_list(self):
        """Empty list returns empty list."""
        result = sort_properties([])
        self.assertEqual(result, [])

    def test_allow_property_last(self):
        """allow- property sorts after default position."""
        props = ["address", "allow-", "iface"]
        result = sort_properties(props)
        self.assertEqual(result[-1], "allow-")


class TestGetRouteDescription(unittest.TestCase):
    """Tests for get_route_description from apply_network_config."""

    def test_full_route(self):
        """Full route description includes all fields."""
        route = {
            "network": "10.0.0.0",
            "netmask": "255.255.255.0",
            "nexthop": "10.0.0.1",
            "ifname": "eth0",
        }
        result = get_route_description(route)
        self.assertIn("10.0.0.0/24", result)
        self.assertIn("via 10.0.0.1", result)
        self.assertIn("dev eth0", result)

    def test_route_with_metric(self):
        """Route description includes metric when present."""
        route = {
            "network": "10.0.0.0",
            "netmask": "255.255.255.0",
            "nexthop": "10.0.0.1",
            "ifname": "eth0",
            "metric": "100",
        }
        result = get_route_description(route)
        self.assertIn("metric 100", result)

    def test_route_with_src(self):
        """Route description includes src when present."""
        route = {
            "network": "10.0.0.0",
            "netmask": "255.255.255.0",
            "nexthop": "10.0.0.1",
            "ifname": "eth0",
            "src": "10.0.0.5",
        }
        result = get_route_description(route)
        self.assertIn("src 10.0.0.5", result)

    def test_route_not_full(self):
        """Non-full route omits gateway and device."""
        route = {
            "network": "10.0.0.0",
            "netmask": "255.255.255.0",
            "nexthop": "10.0.0.1",
            "ifname": "eth0",
        }
        result = get_route_description(route, full=False)
        self.assertIn("10.0.0.0/24", result)
        self.assertNotIn("via", result)

    def test_default_route(self):
        """Default route uses 'default' as network."""
        route = {
            "network": "default",
            "netmask": "0.0.0.0",
            "nexthop": "10.0.0.1",
            "ifname": "eth0",
        }
        result = get_route_description(route)
        self.assertTrue(result.startswith("default"))


class TestInvalidNetmaskError(unittest.TestCase):
    """Tests for InvalidNetmaskError from apply_network_config."""

    def test_is_exception(self):
        """InvalidNetmaskError is a BaseException subclass."""
        self.assertTrue(issubclass(InvalidNetmaskError, BaseException))

    def test_message_preserved(self):
        """Error message is preserved."""
        err = InvalidNetmaskError("bad netmask")
        self.assertEqual(str(err), "bad netmask")

    def test_raised_and_caught(self):
        """Error can be raised and caught."""
        with self.assertRaises(InvalidNetmaskError):
            raise InvalidNetmaskError("test")

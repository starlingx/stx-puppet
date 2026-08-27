#
# Copyright (c) 2026 Wind River Systems, Inc.
#
# SPDX-License-Identifier: Apache-2.0
#


"""Coverage tests for puppet-update-grub-env.py."""

import importlib
import subprocess
import unittest
from unittest.mock import mock_open
from unittest.mock import patch

# puppet-update-grub-env has a hyphen so use importlib
grub_env = importlib.import_module('debian.bullseye.src.bin.puppet-update-grub-env')


class TestGrubEnvSetParser(unittest.TestCase):
    """Tests for set_parser()."""

    def test_set_parser_returns_parser(self):
        """set_parser should return an argparse.ArgumentParser."""
        parser = grub_env.set_parser()
        self.assertIsNotNone(parser)

    def test_set_parser_add_kernelparams(self):
        """Parser should accept --add-kernelparams."""
        parser = grub_env.set_parser()
        args = parser.parse_args(['--add-kernelparams', 'foo=bar'])
        self.assertEqual(args.add_kernel_params, 'foo=bar')

    def test_set_parser_remove_kernelparams(self):
        """Parser should accept --remove-kernelparams."""
        parser = grub_env.set_parser()
        args = parser.parse_args(['--remove-kernelparams', 'foo'])
        self.assertEqual(args.del_kernel_params, 'foo')

    def test_set_parser_list_kernelparams(self):
        """Parser should accept --list-kernelparams."""
        parser = grub_env.set_parser()
        args = parser.parse_args(['--list-kernelparams'])
        self.assertTrue(args.list_kernel_params)

    def test_set_parser_set_kernel(self):
        """Parser should accept --set-kernel."""
        parser = grub_env.set_parser()
        args = parser.parse_args(['--set-kernel', 'vmlinuz-5.10'])
        self.assertEqual(args.set_kernel, 'vmlinuz-5.10')

    def test_set_parser_set_boot_variable(self):
        """Parser should accept --set-boot-variable."""
        parser = grub_env.set_parser()
        args = parser.parse_args(['--set-boot-variable', 'key=val'])
        self.assertEqual(args.set_boot_variable, 'key=val')

    def test_set_parser_boot_index_choices(self):
        """Parser should only accept 1 or 2 for --boot-index."""
        parser = grub_env.set_parser()
        args = parser.parse_args(['--boot-index', '1'])
        self.assertEqual(args.boot_index, '1')
        args = parser.parse_args(['--boot-index', '2'])
        self.assertEqual(args.boot_index, '2')

    def test_set_parser_defaults(self):
        """Parser defaults should be empty/false."""
        parser = grub_env.set_parser()
        args = parser.parse_args([])
        self.assertEqual(args.add_kernel_params, '')
        self.assertEqual(args.del_kernel_params, '')
        self.assertFalse(args.list_kernel_params)
        self.assertEqual(args.set_kernel, '')


class TestGrubEnvConvertValueToDict(unittest.TestCase):
    """Tests for convert_value_to_dict()."""

    def test_simple_key_value(self):
        """Should parse simple key=value params."""
        result = grub_env.convert_value_to_dict('console=ttyS0 quiet')
        self.assertEqual(result['console'], 'ttyS0')
        self.assertEqual(result['quiet'], '')

    def test_hugepage_params_valid_pair(self):
        """Should cache hugepage params as a single 'hugepage' key."""
        value = 'hugepagesz=1G hugepages=4 default_hugepagesz=1G'
        result = grub_env.convert_value_to_dict(value)
        self.assertIn('hugepage', result)
        self.assertIn('hugepagesz=1G', result['hugepage'])
        self.assertIn('hugepages=4', result['hugepage'])
        self.assertIn('default_hugepagesz=1G', result['hugepage'])

    def test_hugepage_multiple_pairs(self):
        """Should handle multiple hugepagesz/hugepages pairs."""
        value = 'hugepagesz=1G hugepages=4 hugepagesz=2M hugepages=512 default_hugepagesz=1G'
        result = grub_env.convert_value_to_dict(value)
        self.assertIn('hugepage', result)

    def test_hugepages_only_without_default_exits(self):
        """Should sys.exit if hugepages= alone without
        default_hugepagesz.
        """
        with self.assertRaises(SystemExit):
            grub_env.convert_value_to_dict('hugepages=4')

    def test_hugepagesz_hugepages_mismatch_exits(self):
        """Should sys.exit if hugepagesz and hugepages counts
        don't match.
        """
        with self.assertRaises(SystemExit):
            grub_env.convert_value_to_dict('hugepagesz=1G hugepagesz=2M hugepages=4')

    def test_empty_value(self):
        """Should return empty dict for empty string."""
        result = grub_env.convert_value_to_dict('')
        self.assertEqual(result, {})

    def test_flag_without_value(self):
        """Should handle flags without = sign."""
        result = grub_env.convert_value_to_dict('nopti nokaslr')
        self.assertEqual(result['nopti'], '')
        self.assertEqual(result['nokaslr'], '')


class TestGrubEnvConvertDictToValue(unittest.TestCase):
    """Tests for convert_dict_to_value()."""

    def test_simple_dict(self):
        """Should convert dict back to kernel_params= string."""
        params_dict = {'console': 'ttyS0', 'quiet': ''}
        result = grub_env.convert_dict_to_value(params_dict)
        self.assertTrue(result.startswith('kernel_params='))
        self.assertIn('console=ttyS0', result)
        self.assertIn(' quiet', result)

    def test_hugepage_appended_last(self):
        """Hugepage params should be appended at the end."""
        params_dict = {'console': 'ttyS0', 'hugepage': 'hugepagesz=1G hugepages=4'}
        result = grub_env.convert_dict_to_value(params_dict)
        idx_console = result.index('console=ttyS0')
        idx_huge = result.index('hugepagesz=1G')
        self.assertGreater(idx_huge, idx_console)

    def test_empty_dict(self):
        """Should return kernel_params= for empty dict."""
        result = grub_env.convert_dict_to_value({})
        self.assertEqual(result, 'kernel_params=')

    def test_roundtrip_preserves_params(self):
        """Converting value->dict->value should preserve all params."""
        original = 'console=ttyS0 quiet nopti'
        params_dict = grub_env.convert_value_to_dict(original)
        result = grub_env.convert_dict_to_value(params_dict)
        self.assertIn('console=ttyS0', result)
        self.assertIn('quiet', result)
        self.assertIn('nopti', result)


class TestGrubEnvGetKernelDir(unittest.TestCase):
    """Tests for get_kernel_dir()."""

    def test_with_boot_index(self):
        """Should return boot/<index> when boot_index is provided."""
        result = grub_env.get_kernel_dir(boot_index='2')
        self.assertEqual(result, 'boot/2')

    @patch('builtins.open', mock_open(read_data='BOOT_IMAGE=/2/vmlinuz root=/dev/sda'))
    def test_boot_image_slot2(self):
        """Should return /boot/2 when cmdline contains
        BOOT_IMAGE=/2/.
        """
        result = grub_env.get_kernel_dir()
        self.assertEqual(result, '/boot/2')

    @patch('builtins.open', mock_open(read_data='BOOT_IMAGE=/1/vmlinuz root=/dev/sda'))
    def test_boot_image_slot1(self):
        """Should return /boot/1 when cmdline contains
        BOOT_IMAGE=/1/.
        """
        result = grub_env.get_kernel_dir()
        self.assertEqual(result, '/boot/1')

    @patch('builtins.open', mock_open(read_data='root=/dev/sda'))
    def test_no_boot_image(self):
        """Should default to /boot/1 when no BOOT_IMAGE=/2/ found."""
        result = grub_env.get_kernel_dir()
        self.assertEqual(result, '/boot/1')


class TestGrubEnvEditBootEnv(unittest.TestCase):
    """Tests for edit_boot_env()."""

    @patch.object(grub_env, 'write_conf')
    @patch.object(grub_env, 'read_kernel_params', return_value='console=ttyS0')
    def test_add_param(self, _mock_read, mock_write):
        """Should add a new kernel param."""
        parser = grub_env.set_parser()
        args = parser.parse_args(['--add-kernelparams', 'nopti'])
        grub_env.edit_boot_env(args)
        written = mock_write.call_args[0][1]
        self.assertIn('nopti', written)
        self.assertIn('console=ttyS0', written)

    @patch.object(grub_env, 'write_conf')
    @patch.object(grub_env, 'read_kernel_params', return_value='console=ttyS0 nopti')
    def test_remove_param(self, _mock_read, mock_write):
        """Should remove a kernel param."""
        parser = grub_env.set_parser()
        args = parser.parse_args(['--remove-kernelparams', 'nopti'])
        grub_env.edit_boot_env(args)
        written = mock_write.call_args[0][1]
        self.assertNotIn('nopti', written)
        self.assertIn('console=ttyS0', written)

    @patch.object(grub_env, 'write_conf')
    @patch.object(grub_env, 'read_kernel_params',
                  return_value='console=ttyS0 hugepagesz=1G hugepages=4 default_hugepagesz=1G')
    def test_remove_hugepage_removes_all(self, _mock_read, mock_write):
        """Removing hugepagesz should remove all hugepage params."""
        parser = grub_env.set_parser()
        args = parser.parse_args(['--remove-kernelparams', 'hugepagesz'])
        grub_env.edit_boot_env(args)
        written = mock_write.call_args[0][1]
        self.assertNotIn('hugepagesz', written)
        self.assertNotIn('hugepages', written)
        self.assertNotIn('default_hugepagesz', written)

    @patch.object(grub_env, 'write_conf')
    @patch.object(grub_env, 'read_kernel_params', return_value='console=ttyS0')
    def test_add_hugepage_params(self, _mock_read, mock_write):
        """Should add hugepage params correctly."""
        parser = grub_env.set_parser()
        args = parser.parse_args([
            '--add-kernelparams',
            'hugepagesz=1G hugepages=4 default_hugepagesz=1G'
        ])
        grub_env.edit_boot_env(args)
        written = mock_write.call_args[0][1]
        self.assertIn('hugepagesz=1G', written)
        self.assertIn('hugepages=4', written)
        self.assertIn('default_hugepagesz=1G', written)


class TestGrubEnvEditBootEnvVariable(unittest.TestCase):
    """Tests for edit_boot_env_variable()."""

    @patch.object(grub_env, 'write_conf')
    def test_valid_variable(self, mock_write):
        """Should call write_conf for valid key=value."""
        parser = grub_env.set_parser()
        args = parser.parse_args(['--set-boot-variable', 'mykey=myval'])
        grub_env.edit_boot_env_variable(args)
        self.assertEqual(mock_write.call_args[0], (grub_env.BOOT_ENV, 'mykey=myval'))

    def test_invalid_variable_raises(self):
        """Should raise KeyError for value without =."""
        parser = grub_env.set_parser()
        args = parser.parse_args(['--set-boot-variable', 'invalidformat'])
        with self.assertRaises(KeyError):
            grub_env.edit_boot_env_variable(args)


class TestGrubEnvReadKernelParams(unittest.TestCase):
    """Tests for read_kernel_params()."""

    @patch('subprocess.check_output',
           return_value=b'kernel_params=console=ttyS0\n')
    def test_read_kernel_params_success(self, _mock_sub):
        """Should extract kernel_params value from
        grub-editenv output.
        """
        result = grub_env.read_kernel_params('/boot/efi/EFI/BOOT/boot.env')
        self.assertEqual(result, 'console=ttyS0')

    @patch('subprocess.check_output',
           return_value=b'other_var=foo\n')
    def test_read_kernel_params_no_match(self, _mock_sub):
        """Should return empty string when kernel_params
        not in output.
        """
        result = grub_env.read_kernel_params('/boot/efi/EFI/BOOT/boot.env')
        self.assertEqual(result, '')

    @patch('subprocess.check_output',
           side_effect=subprocess.CalledProcessError(1, 'grub-editenv'))
    def test_read_kernel_params_exception(self, _mock_sub):
        """Should re-raise exception on subprocess failure."""
        with patch('builtins.print'), self.assertRaises(subprocess.CalledProcessError):
            grub_env.read_kernel_params('/boot/efi/EFI/BOOT/boot.env')


class TestGrubEnvWriteConf(unittest.TestCase):
    """Tests for write_conf()."""

    @patch('subprocess.check_output', return_value=b'')
    def test_write_conf_calls_unset_then_set(self, mock_sub):
        """Should call grub-editenv unset then set."""
        grub_env.write_conf('/boot/efi/EFI/BOOT/boot.env', 'kernel_params=console=ttyS0')
        calls = mock_sub.call_args_list
        self.assertEqual(len(calls), 2)
        self.assertIn('unset', calls[0][0][0])
        self.assertIn('set', calls[1][0][0])

    @patch('subprocess.check_output', return_value=b'')
    def test_write_conf_extracts_key_for_unset(self, mock_sub):
        """Should extract key from key=value for the unset command."""
        grub_env.write_conf('/boot/efi/EFI/BOOT/boot.env', 'mykey=myval')
        unset_call = mock_sub.call_args_list[0][0][0]
        self.assertIn('mykey', unset_call)
        self.assertNotIn('myval', unset_call)

    @patch('subprocess.check_output',
           side_effect=subprocess.CalledProcessError(1, 'grub-editenv'))
    def test_write_conf_exception(self, _mock_sub):
        """Should re-raise exception on subprocess failure."""
        with patch('builtins.print'), self.assertRaises(subprocess.CalledProcessError):
            grub_env.write_conf('/boot/efi/EFI/BOOT/boot.env', 'kernel_params=foo')


class TestGrubEnvEditKernelEnv(unittest.TestCase):
    """Tests for edit_kernel_env()."""

    @patch.object(grub_env, 'write_conf')
    @patch('glob.glob', return_value=['/boot/1/vmlinuz-5.10-amd64'])
    @patch.object(grub_env, 'get_kernel_dir', return_value='/boot/1')
    def test_set_kernel(self, _mock_dir, _mock_glob, mock_write):
        """Should write specified kernel to kernel.env."""
        parser = grub_env.set_parser()
        args = parser.parse_args(['--set-kernel', 'vmlinuz-5.10-amd64'])
        grub_env.edit_kernel_env(args)
        written = mock_write.call_args_list[0][0][1]
        self.assertIn('vmlinuz-5.10-amd64', written)

    @patch.object(grub_env, 'write_conf')
    @patch('glob.glob', side_effect=[
        ['/boot/1/vmlinuz-5.10-amd64', '/boot/1/vmlinuz-5.10-rt-amd64'],
        ['/boot/1/vmlinuz-5.10-rt-amd64'],
    ])
    @patch.object(grub_env, 'get_kernel_dir', return_value='/boot/1')
    def test_set_kernel_lowlatency(self, _mock_dir, _mock_glob, mock_write):
        """Should select the RT kernel when --set-kernel-lowlatency."""
        parser = grub_env.set_parser()
        args = parser.parse_args(['--set-kernel-lowlatency'])
        grub_env.edit_kernel_env(args)
        written = mock_write.call_args_list[0][0][1]
        self.assertIn('rt', written)

    @patch.object(grub_env, 'write_conf')
    @patch('glob.glob', side_effect=[
        ['/boot/1/vmlinuz-5.10-amd64', '/boot/1/vmlinuz-5.10-rt-amd64'],
        ['/boot/1/vmlinuz-5.10-rt-amd64'],
    ])
    @patch.object(grub_env, 'get_kernel_dir', return_value='/boot/1')
    def test_set_kernel_standard(self, _mock_dir, _mock_glob, mock_write):
        """Should select the standard (non-RT) kernel when
        --set-kernel-standard.
        """
        parser = grub_env.set_parser()
        args = parser.parse_args(['--set-kernel-standard'])
        grub_env.edit_kernel_env(args)
        written = mock_write.call_args_list[0][0][1]
        self.assertNotIn('rt', written)

    @patch.object(grub_env, 'write_conf')
    @patch('glob.glob', return_value=['/boot/1/vmlinuz-5.10-amd64'])
    @patch.object(grub_env, 'get_kernel_dir', return_value='/boot/1')
    def test_writes_kernel_and_rollback(self, _mock_dir, _mock_glob, mock_write):
        """Should write both kernel= and kernel_rollback= entries."""
        parser = grub_env.set_parser()
        args = parser.parse_args(['--set-kernel', 'vmlinuz-5.10-amd64'])
        grub_env.edit_kernel_env(args)
        self.assertEqual(mock_write.call_count, 2)
        self.assertIn('kernel=', mock_write.call_args_list[0][0][1])
        self.assertIn('kernel_rollback=', mock_write.call_args_list[1][0][1])


class TestGrubEnvListKernels(unittest.TestCase):
    """Tests for list_kernels()."""

    @patch('subprocess.check_output', return_value=b'kernel=vmlinuz-5.10-amd64\n')
    @patch('glob.glob', return_value=['/boot/1/vmlinuz-5.10-amd64'])
    @patch.object(grub_env, 'get_kernel_dir', return_value='/boot/1')
    @patch('builtins.print')
    def test_list_kernels_prints(self, mock_print, _mock_dir, _mock_glob, _mock_sub):
        """Should print available kernels and kernel.env contents."""
        grub_env.list_kernels()
        self.assertTrue(mock_print.called)

    @patch('subprocess.check_output',
           side_effect=subprocess.CalledProcessError(1, 'grub-editenv'))
    @patch('glob.glob', return_value=[])
    @patch.object(grub_env, 'get_kernel_dir', return_value='/boot/1')
    @patch('builtins.print')
    def test_list_kernels_exception(self, _mock_print, _mock_dir, _mock_glob, _mock_sub):
        """Should re-raise on subprocess failure."""
        with self.assertRaises(subprocess.CalledProcessError):
            grub_env.list_kernels()


class TestGrubEnvListKernelParams(unittest.TestCase):
    """Tests for list_kernel_params()."""

    @patch('subprocess.check_output',
           return_value=b'kernel_params=console=ttyS0\nother=val\n')
    @patch('builtins.print')
    def test_list_kernel_params_prints_matching(self, mock_print, _mock_sub):
        """Should print only the kernel_params line."""
        grub_env.list_kernel_params()
        printed = [str(call) for call in mock_print.call_args_list]
        found = any('kernel_params=' in line for line in printed)
        self.assertTrue(found)

    @patch('subprocess.check_output',
           side_effect=subprocess.CalledProcessError(1, 'grub-editenv'))
    @patch('builtins.print')
    def test_list_kernel_params_exception(self, _mock_print, _mock_sub):
        """Should re-raise on subprocess failure."""
        with self.assertRaises(subprocess.CalledProcessError):
            grub_env.list_kernel_params()

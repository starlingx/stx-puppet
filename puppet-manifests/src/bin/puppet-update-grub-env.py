#!/usr/bin/python3
#
# Copyright (c) 2022 Wind River Systems, Inc.
#
# SPDX-License-Identifier: Apache-2.0
#
# Utility to add or remove cmdline options and
# kernel image to grub environment file
#
"""Utility to add or remove cmdline options and
kernel image to grub environment file

The hugepagesz, hugepages and default_hugepagesz has close relationship:
- It is legal to specify "hugepages=" by itself as long as
  "default_hugepagesz" is specified, in which case it will
  allocate that many pages of the default size.
- Remove any of them means to remove all
- If hugepagesz is set, "hugepages=" and "hugepagesz=" should
  appear as pairs
"""

import argparse
import subprocess
import os
import glob
import sys

BOOT_ENV = "/boot/efi/EFI/BOOT/boot.env"
KERNEL_PARAMS_STRING = "kernel_params"


# Get value of kernel_params from conf
def read_kernel_params(conf):
    """Get value of kernel_params from conf"""
    res = ''
    try:
        cmd = f'grub-editenv {conf} list'
        output = subprocess.check_output(cmd.split()).decode('utf-8')
    except Exception as err:
        print(err)
        raise

    for line in output.split('\n'):
        if line.startswith('kernel_params='):
            res = line[len('kernel_params='):]
            break

    return res


# Write key=value string to conf
def write_conf(conf, string):
    """Write key=value string to conf"""
    try:
        cmd_unset = ['grub-editenv', conf, 'unset', KERNEL_PARAMS_STRING]
        subprocess.check_output(cmd_unset)

        cmd_set = ['grub-editenv', conf, 'set', string]
        subprocess.check_output(cmd_set)
    except Exception as err:
        print(err)
        raise


def set_parser():
    """Set command parser"""

    parser = argparse.ArgumentParser(
        description='Edit kernel params and set which kernel to boot',
        epilog='Use %(prog)s --help to get help')

    parser.add_argument('--add-kernelparams',
                        default='',
                        dest='add_kernel_params',
                        help='Add values to kernel_params',
                        action='store')

    parser.add_argument('--remove-kernelparams',
                        default='',
                        dest='del_kernel_params',
                        help='Remove values to kernel_params',
                        action='store')

    parser.add_argument('--list-kernelparams',
                        default=False,
                        dest='list_kernel_params',
                        help='List kernel params',
                        action='store_true')

    parser.add_argument('--set-kernel',
                        default='',
                        dest='set_kernel',
                        help='Set which kernel to boot',
                        action='store')

    parser.add_argument('--set-kernel-lowlatency',
                        default=False,
                        dest='set_kernel_lowlatency',
                        help='Set the lowlatency kernel to boot',
                        action='store_true')

    parser.add_argument('--set-kernel-standard',
                        default=False,
                        dest='set_kernel_standard',
                        help='Set the standard kernel to boot',
                        action='store_true')

    parser.add_argument('--list-kernels',
                        default=False,
                        dest='list_kernels',
                        help='List available kernels',
                        action='store_true')

    return parser


def convert_dict_to_value(kernel_params_dict):
    """Dictionary to value"""

    kernel_params = ""
    for key, val in kernel_params_dict.items():
        if key == 'hugepage':
            continue

        if val:
            kernel_params += f" {key}={val}"
        else:
            kernel_params += f" {key}"

    if 'hugepage' in kernel_params_dict:
        kernel_params += f" {kernel_params_dict['hugepage']}"

    return f"kernel_params={kernel_params}"


def convert_value_to_dict(value):
    """Value to dictionary"""

    kernel_params_dict = {}
    hugepage_cache = ''
    hugepages_count = 0
    hugepagesz_count = 0
    has_default_hugepagesz = False
    for param in value.split():
        if '=' in param:
            # The hugepagesz, hugepages and default_hugepagesz has close relationship.
            # Cache and process it later
            if param.startswith('hugepages') or param.startswith('default_hugepagesz='):
                hugepage_cache += " " + param
                # The hugepagesz is paired with hugepages, count them
                if param.startswith('hugepagesz='):
                    hugepagesz_count += 1
                elif param.startswith('hugepages='):
                    hugepages_count += 1
                elif param.startswith('default_hugepagesz='):
                    has_default_hugepagesz = True

                continue

            key, val = param.split('=')
        else:
            key, val = param, ''

        kernel_params_dict[key] = val

    if hugepage_cache:
        # It is not legal to specify "hugepages=" by itself without
        # default_hugepagesz and hugepagesz
        if not has_default_hugepagesz and \
           hugepagesz_count == 0 and \
           hugepages_count > 0:
            print("FAIL: default_hugepagesz and hugepagesz is not set")
            print("FAIL: only hugepages is not allowed ")
            sys.exit(1)

        # It is not legal if "hugepages=" and "hugepagesz=" not pairs
        elif hugepagesz_count > 0 and hugepages_count != hugepagesz_count:
            print("FAIL: hugepagesz and hugepages does not appear as pairs")
            sys.exit(1)
        kernel_params_dict['hugepage'] = hugepage_cache

    return kernel_params_dict


def edit_boot_env(args):
    """Edit boot environment"""

    # Config file to dictionary
    kernel_params = read_kernel_params(BOOT_ENV)
    kernel_params_dict = convert_value_to_dict(kernel_params)

    # New added kernel params to dictionary
    new_kernel_params_dict = convert_value_to_dict(args.add_kernel_params)

    # Update config file dictionary
    for key, val in new_kernel_params_dict.items():
        if key == 'hugepage':
            if 'hugepage' in kernel_params_dict:
                kernel_params_dict['hugepage'] += f' {val}'
            else:
                kernel_params_dict['hugepage'] = val
            continue
        kernel_params_dict[key] = val

    # Remove kernel params from dictionary
    for param in args.del_kernel_params.split():
        for key in kernel_params_dict.copy():
            if key == param:
                del kernel_params_dict[param]
            # The hugepagesz, hugepages and default_hugepagesz has
            # close relationship, remove one means to remove all
            elif param in ['hugepagesz', 'hugepages', 'default_hugepagesz']:
                if 'hugepage' in kernel_params_dict:
                    del kernel_params_dict['hugepage']

    # Dictionary to config file
    kernel_params = convert_dict_to_value(kernel_params_dict)
    write_conf(BOOT_ENV, kernel_params)


def get_kernel_dir():
    """Get kernel directory"""

    cmdline = ""
    with open("/proc/cmdline", encoding="utf-8") as f_cmdline:
        cmdline = f_cmdline.read()
    if cmdline.find("BOOT_IMAGE=/2/") >= 0:
        return "/boot/2"

    return "/boot/1"


def edit_kernel_env(args):
    """Edit kernel environment"""

    kernel_dir = get_kernel_dir()
    path_all = os.path.join(kernel_dir, "vmlinuz*-amd64")
    path_rt = os.path.join(kernel_dir, "vmlinuz*rt*-amd64")

    glob_all_kernels = [os.path.basename(f) for f in glob.glob(path_all)]
    glob_rt_kernels = [os.path.basename(f) for f in glob.glob(path_rt)]
    glob_std_kernels = list(set(glob_all_kernels) - set(glob_rt_kernels))

    if args.set_kernel_lowlatency:
        kernel = f"kernel={sorted(glob_rt_kernels, reverse=True).pop()}"
    elif args.set_kernel_standard:
        kernel = f"kernel={sorted(glob_std_kernels, reverse=True).pop()}"
    else:
        kernel = f"kernel={args.set_kernel}"

    if not kernel:
        err = f"Kernel not found in ${kernel_dir}"
        print(err)
        raise Exception(err)

    # write key-value kernel=... to kernel.env file
    kernel_env = os.path.join(kernel_dir, 'kernel.env')
    write_conf(kernel_env, kernel)

    # write key-value kernel_rollback=... to kernel.env file
    kernel_rollback_env = f"kernel_rollback={kernel}"
    write_conf(kernel_env, kernel_rollback_env)


def list_kernels():
    """List kernels"""

    print(f"Available Kernels in {get_kernel_dir()}")
    for kernel in glob.glob(os.path.join(get_kernel_dir(), "vmlinuz*-amd64")):
        print(f"  {os.path.basename(kernel)}")

    kernel_env = os.path.join(get_kernel_dir(), 'kernel.env')
    print(f"\nIn {kernel_env}:")
    try:
        cmd = f'grub-editenv {kernel_env} list'
        output = subprocess.check_output(cmd.split()).decode('utf-8')
    except Exception as err:
        print(err)
        raise

    print(output)


def list_kernel_params():
    """List kernel params"""

    print(f"In {BOOT_ENV}:")
    try:
        cmd = f'grub-editenv {BOOT_ENV} list'
        output = subprocess.check_output(cmd.split()).decode('utf-8')
    except Exception as err:
        print(err)
        raise

    for line in output.split('\n'):
        if line.startswith('kernel_params='):
            print(line)
            break


def main():
    """Main"""
    parser = set_parser()
    args = parser.parse_args()

    if args.add_kernel_params or args.del_kernel_params:
        edit_boot_env(args)

    if args.set_kernel or args.set_kernel_lowlatency or args.set_kernel_standard:
        edit_kernel_env(args)

    if args.list_kernels:
        list_kernels()

    if args.list_kernel_params:
        list_kernel_params()


if __name__ == "__main__":
    main()

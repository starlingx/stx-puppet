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
kernel image to grub environment file"""

import argparse
import subprocess
import os
import glob

# Get value of kernel_params from conf
def read_conf(conf):
    """Get value of kernel_params from conf"""
    res = ''
    try:
        cmd = 'grub-editenv %s list' % conf
        output = subprocess.check_output(cmd.split()).decode('utf-8')
    except Exception as err:
        print(err)
        raise

    for line in output.split('\n'):
        if line.startswith('kernel_params='):
            res = line[len('kernel_params='):]
            break

    return res

# Write value of kernel_params to conf
def write_conf(conf, value):
    """Write value of kernel_params to conf"""
    try:
        cmd = ['grub-editenv', conf, 'set', value]
        subprocess.check_output(cmd)
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

    parser.add_argument('--list-kernels',
                        default=False,
                        dest='list_kernels',
                        help='List available kernels',
                        action='store_true')

    return parser

def edit_boot_env(args):
    """Edit boot environment"""

    # Config file to dictionary
    confile = '/boot/efi/EFI/BOOT/boot.env'
    kernel_params = read_conf(confile)
    kernel_params_dict = dict()
    for param in kernel_params.split():
        if '=' in param:
            key, val = param.split('=')
        else:
            key, val = param, ''
        kernel_params_dict[key] = val

    # Add/Update node to kernel params dictionary
    for param in args.add_kernel_params.split():
        if '=' in param:
            key, val = param.split('=')
        else:
            key, val = param, ''
        kernel_params_dict[key] = val

    # Remove node from kernel params dictionary
    for param in args.del_kernel_params.split():
        if param in kernel_params_dict:
            del kernel_params_dict[param]

    # Convert dictionary to config file
    kernel_params = ""
    for key, val in kernel_params_dict.items():
        if val:
            kernel_params += " %s=%s" % (key, val)
        else:
            kernel_params += " %s" % (key)

    value = "kernel_params=%s" % kernel_params
    write_conf(confile, value)

def get_kernel_dir():
    """Get kernel directory"""

    cmdline = open("/proc/cmdline").read()
    if cmdline.find("BOOT_IMAGE=/2/") >= 0:
        return "/boot/2"

    return "/boot/1"

def edit_kernel_env(args):
    """Edit kernel environment"""

    confile = os.path.join(get_kernel_dir(), 'kernel.env')

    value = "kernel=%s" % args.set_kernel
    write_conf(confile, value)

    value = "kernel_rollback=%s" % args.set_kernel
    write_conf(confile, value)

def list_kernels():
    """List kernels"""

    print("Available Kernels in %s" % get_kernel_dir())
    for kernel in glob.glob(os.path.join(get_kernel_dir(), "vmlinuz*-amd64")):
        print("  %s" % os.path.basename(kernel))

    confile = os.path.join(get_kernel_dir(), 'kernel.env')
    print("\nIn %s:" % confile)
    try:
        cmd = 'grub-editenv %s list' % confile
        output = subprocess.check_output(cmd.split()).decode('utf-8')
    except Exception as err:
        print(err)
        raise

    print(output)

def list_kernel_params():
    """List kernel params"""

    confile = '/boot/efi/EFI/BOOT/boot.env'
    print("In %s:" % confile)
    try:
        cmd = 'grub-editenv %s list' % confile
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

    if args.set_kernel:
        edit_kernel_env(args)

    if args.list_kernels:
        list_kernels()

    if args.list_kernel_params:
        list_kernel_params()

if __name__ == "__main__":
    main()

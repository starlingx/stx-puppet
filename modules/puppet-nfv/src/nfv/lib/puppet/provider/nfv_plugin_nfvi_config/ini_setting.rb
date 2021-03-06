#
# Copyright (c) 2016 Wind River Systems, Inc.
#
# SPDX-License-Identifier: Apache-2.0
#

Puppet::Type.type(:nfv_plugin_nfvi_config).provide(
  :ini_setting,
  # set ini_setting as the parent provider
  :parent => Puppet::Type.type(:ini_setting).provider(:ruby)
) do

  def section
    # implemented section as the first part of the namevar
    resource[:name].split('/', 2).first
  end

  def setting
    # implemented setting as the second part of the namevar
    resource[:name].split('/', 2).last
  end

  def separator
    '='
  end

  # hard code the file path (this allows purging)
  def self.file_path
    '/etc/nfv/nfv_plugins/nfvi_plugins/config.ini'
  end
end

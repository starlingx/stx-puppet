#
# Files in this package are licensed under Apache; see LICENSE file.
#
# Copyright (c) 2024 Wind River Systems, Inc.
#
# SPDX-License-Identifier: Apache-2.0
#
#

class dcagent::params {

  $conf_dir = '/etc/dcagent'
  $conf_file = '/etc/dcagent/dcagent.conf'

  if $::osfamily == 'Debian' {
    $package_name           = 'distributedcloud-dcagent'
    $api_package            = false
    $api_service            = 'dcagent-api'

  } else {
    fail("Unsupported osfamily ${::osfamily}")
  }
}

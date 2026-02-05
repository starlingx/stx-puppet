#
# Files in this package are licensed under Apache; see LICENSE file.
#
# Copyright (c) 2024 Wind River Systems, Inc.
#
# SPDX-License-Identifier: Apache-2.0
#
# Jul 2024 Creation based off puppet-dcdbsync
#

#
# == Parameters
#
# [use_syslog]
#   Use syslog for logging.
#   (Optional) Defaults to false.
#
# [log_facility]
#   Syslog facility to receive log lines.
#   (Optional) Defaults to LOG_USER.

class dcagent (
  $package_ensure              = 'present',
  $use_stderr                  = false,
  $log_file                    = 'dcagent.log',
  $log_dir                     = '/var/log/dcagent',
  $use_syslog                  = false,
  $log_facility                = 'LOG_USER',
  $verbose                     = false,
  $debug                       = false,
  $region_name                 = 'RegionOne',
) {

  include dcagent::params

  Package['dcagent'] -> Dcagent_config<||>

  package { 'dcagent':
    ensure => $package_ensure,
    name   => $::dcagent::params::package_name,
  }

  file { $::dcagent::params::conf_file:
    ensure  => present,
    mode    => '0600',
    require => Package['dcagent'],
  }

  dcagent_config {
    'DEFAULT/verbose':             value => $verbose;
    'DEFAULT/debug':               value => $debug;
  }

  if $use_syslog {
    dcagent_config {
      'DEFAULT/use_syslog':           value => true;
      'DEFAULT/syslog_log_facility':  value => $log_facility;
    }
  } else {
    dcagent_config {
      'DEFAULT/use_syslog':           value => false;
      'DEFAULT/use_stderr':           value => false;
      'DEFAULT/log_file'  :           value => $log_file;
      'DEFAULT/log_dir'   :           value => $log_dir;
    }
  }

  dcagent_config {
    'keystone_authtoken/region_name':  value => $region_name;
  }
}

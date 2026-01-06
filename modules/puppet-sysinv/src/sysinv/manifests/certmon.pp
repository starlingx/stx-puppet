#
# Files in this package are licensed under Apache; see LICENSE file.
#
# Copyright (c) 2020, 2025 Wind River Systems, Inc.
#
# SPDX-License-Identifier: Apache-2.0
#
#
class sysinv::certmon (
  $local_keystone_password,
  $local_keystone_auth_uri     = false,
  $local_keystone_identity_uri = false,
  $local_keystone_project_domain = 'Default',
  $local_keystone_tenant       = 'services',
  $local_keystone_user         = 'sysinv',
  $local_keystone_user_domain  = 'Default',
  $local_region_name           = 'RegionOne',

  $use_syslog                 = false,
  $log_facility               = 'LOG_USER',
  $debug                      = false,

  $keystone_auth_protocol     = 'http',
  $keystone_auth_host         = 'localhost',
  $keystone_enabled           = true,
  $keystone_interface         = 'internal',
  $auth_type                  = 'password',
  $service_port               = '5000',
  $keystone_http_connect_timeout = '15',
  $package_ensure             = 'latest',
  $bind_host                  = '::',
  $pxeboot_host               = undef,
  $enabled                    = true,
) {
  include sysinv::params

  if $::sysinv::params::certmon_package {
    Package['certmon'] -> Certmon_config<||>
    package { 'certmon':
      ensure => $package_ensure,
      name   => $::sysinv::params::certmon_package,
    }
  }

  file { $::sysinv::params::certmon_conf:
    ensure  => present,
    owner   => 'root',
    group   => 'root',
    mode    => '0600',
    require => Package['sysinv'],
  }

  if $local_keystone_identity_uri {
    certmon_config {
      'keystone_authtoken/auth_url': value => $local_keystone_identity_uri;
      'keystone_authtoken/auth_uri': value => $local_keystone_identity_uri;
    }
  } else {
    certmon_config {
      'keystone_authtoken/auth_url': value => "${keystone_auth_protocol}://${keystone_auth_host}:5000/";
      'keystone_authtoken/auth_uri': value => "${keystone_auth_protocol}://${keystone_auth_host}:5000/";
    }
  }

  certmon_config {
    'DEFAULT/syslog_log_facility': value => $log_facility;
    'DEFAULT/use_syslog': value => $use_syslog;
    'DEFAULT/debug': value => $debug;
    'DEFAULT/logging_default_format_string': value => '%(process)d %(levelname)s %(name)s [-] %(instance)s%(message)s';
    'DEFAULT/logging_debug_format_suffix': value => '%(pathname)s:%(lineno)d';
  }

  certmon_config {
    'certmon/retry_interval': value => 600;
    'certmon/max_retry': value => 14;
  }

  if $keystone_enabled {
    certmon_config {
      'DEFAULT/auth_strategy':     value => 'keystone' ;
    }
    certmon_config {
      'keystone_authtoken/auth_type':    value => $auth_type;
      'keystone_authtoken/project_name': value => $local_keystone_tenant;
      'keystone_authtoken/username':     value => $local_keystone_user;
      'keystone_authtoken/password':     value => $local_keystone_password, secret=> true;
      'keystone_authtoken/user_domain_name':  value => $local_keystone_user_domain;
      'keystone_authtoken/project_domain_name':  value => $local_keystone_project_domain;
      'keystone_authtoken/interface':  value => $keystone_interface;
      'keystone_authtoken/region_name':  value => $local_region_name;
    }
  }
  else
  {
    certmon_config {
      'DEFAULT/auth_strategy':     value => 'noauth' ;
    }
  }
}

class sysinv::certmon::keystone::password (
  $keystone_enabled = true
) {

  if $keystone_enabled {
    certmon_config {
      'keystone_authtoken/password': value => lookup('sysinv::certmon::local_keystone_password'), secret => true;
    }
  }
}

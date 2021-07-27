#
# Files in this package are licensed under Apache; see LICENSE file.
#
# Copyright (c) 2021 Wind River Systems, Inc.
#
# SPDX-License-Identifier: Apache-2.0
#
#
class sysinv::certalarm (
  $local_keystone_password,
  $dc_keystone_password,
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
  $keystone_http_connect_timeout = '10',
  $package_ensure             = 'latest',
  $bind_host                  = '::',
  $pxeboot_host               = undef,
  $enabled                    = true,
) {
  include sysinv::params

  if $::sysinv::params::certalarm_package {
    Package['certalarm'] -> Certalarm_config<||>
    package { 'certalarm':
      ensure => $package_ensure,
      name   => $::sysinv::params::certalarm_package,
    }
  }

  file { $::sysinv::params::certalarm_conf:
    ensure  => present,
    owner   => 'root',
    group   => 'root',
    mode    => '0600',
    require => Package['sysinv'],
  }

  if $local_keystone_identity_uri {
    certalarm_config {
      'keystone_authtoken/auth_url': value => $local_keystone_identity_uri;
      'keystone_authtoken/auth_uri': value => $local_keystone_identity_uri;
    }
  } else {
    certalarm_config {
      'keystone_authtoken/auth_url': value => "${keystone_auth_protocol}://${keystone_auth_host}:${service_port}/";
      'keystone_authtoken/auth_uri': value => "${keystone_auth_protocol}://${keystone_auth_host}:${service_port}/";
    }
  }

  certalarm_config {
    'DEFAULT/syslog_log_facility': value => $log_facility;
    'DEFAULT/use_syslog': value => $use_syslog;
    'DEFAULT/debug': value => $debug;
    'DEFAULT/logging_default_format_string': value => '%(process)d %(levelname)s %(name)s [-] %(instance)s%(message)s';
    'DEFAULT/logging_debug_format_suffix': value => '%(pathname)s:%(lineno)d';
  }

  certalarm_config {
    'certalarm/retry_interval': value => 600;
    'certalarm/max_retry': value => 14;
    'certalarm/audit_interval': value => 86400;
  }

  if $keystone_enabled {
    certalarm_config {
      'DEFAULT/auth_strategy':     value => 'keystone' ;
    }
    certalarm_config {
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
    certalarm_config {
      'DEFAULT/auth_strategy':     value => 'noauth' ;
    }
  }
}

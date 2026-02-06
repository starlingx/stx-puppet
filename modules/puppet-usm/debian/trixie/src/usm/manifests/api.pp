#
# Copyright (c) 2023 Wind River Systems, Inc.
#
# SPDX-License-Identifier: Apache-2.0
#
class usm::api (
  $keystone_password,
  $keystone_enabled           = true,
  $keystone_tenant            = 'services',
  $keystone_user              = 'usm',
  $keystone_user_domain       = 'Default',
  $keystone_project_domain    = 'Default',
  $keystone_auth_host         = 'localhost',
  $keystone_auth_port         = '5000',
  $keystone_auth_protocol     = 'http',
  $keystone_auth_admin_prefix = false,
  $keystone_auth_uri          = false,
  $keystone_auth_version      = false,
  $keystone_identity_uri      = false,
  $keystone_region_name       = 'RegionOne',
  $auth_type                  = 'password',
  $service_port               = '5000',
  $package_ensure             = 'latest',
  $bind_host                  = '0.0.0.0',
  $enabled                    = true
) {

  include usm::params

  if $keystone_identity_uri {
    usm_config { 'keystone_authtoken/auth_url': value => $keystone_identity_uri; }
  } else {
    usm_config { 'keystone_authtoken/auth_url': value => "${keystone_auth_protocol}://${keystone_auth_host}:5000/"; }
  }

  if $keystone_auth_uri {
    usm_config { 'keystone_authtoken/auth_uri': value => $keystone_auth_uri; }
  } else {
    usm_config {
      'keystone_authtoken/auth_uri': value => "${keystone_auth_protocol}://${keystone_auth_host}:5000/";
    }
  }

  if $keystone_auth_version {
    usm_config { 'keystone_authtoken/auth_version': value => $keystone_auth_version; }
  } else {
    usm_config { 'keystone_authtoken/auth_version': ensure => absent; }
  }

  if $keystone_enabled {
    usm_config {
      'DEFAULT/auth_strategy':     value => 'keystone' ;
    }
    usm_config {
      'keystone_authtoken/auth_type':        value => $auth_type;
      'keystone_authtoken/project_name':     value => $keystone_tenant;
      'keystone_authtoken/username':         value => $keystone_user;
      'keystone_authtoken/user_domain_name': value => $keystone_user_domain;
      'keystone_authtoken/project_domain_name': value => $keystone_project_domain;
      'keystone_authtoken/region_name':      value => $keystone_region_name;
      'keystone_authtoken/password':         value => $keystone_password, secret => true;
    }

    if $keystone_auth_admin_prefix {
      validate_re($keystone_auth_admin_prefix, '^(/.+[^/])?$')
      usm_config {
        'keystone_authtoken/auth_admin_prefix': value => $keystone_auth_admin_prefix;
      }
    } else {
      usm_config {
        'keystone_authtoken/auth_admin_prefix': ensure => absent;
      }
    }
  }
  else
  {
    usm_config {
      'DEFAULT/auth_strategy':     value => 'noauth' ;
    }
  }
}

#
# Files in this package are licensed under Apache; see LICENSE file.
#
# Copyright (c) 2024 Wind River Systems, Inc.
#
# SPDX-License-Identifier: Apache-2.0
#

# == Class: dcagent::api
#
# Setup and configure the dcagent API endpoint
#
# === Parameters
#
# [*keystone_password*]
#   The password to use for authentication (keystone)
#
# [*keystone_enabled*]
#   (optional) Use keystone for authentification
#   Defaults to true
#
# [*keystone_tenant*]
#   (optional) The tenant of the auth user
#   Defaults to services
#
# [*keystone_user*]
#   (optional) The name of the auth user
#   Defaults to dcagent
#
# [*keystone_auth_host*]
#   (optional) The keystone host
#   Defaults to localhost
#
# [*keystone_auth_port*]
#   (optional) The keystone auth port
#   Defaults to 5000
#
# [*keystone_auth_protocol*]
#   (optional) The protocol used to access the auth host
#   Defaults to http.
#
# [*keystone_auth_admin_prefix*]
#   (optional) The admin_prefix used to admin endpoint of the auth host
#   This allow admin auth URIs like http://auth_host:5000/keystone.
#   (where '/keystone' is the admin prefix)
#   Defaults to false for empty. If defined, should be a string with a
#   leading '/' and no trailing '/'.
#
# [*keystone_user_domain*]
#   (Optional) domain name for auth user.
#   Defaults to 'Default'.
#
# [*keystone_project_domain*]
#   (Optional) domain name for auth project.
#   Defaults to 'Default'.
#
# [*auth_type*]
#   (Optional) Authentication type to load.
#   Defaults to 'password'.
#
# [*bind_port*]
#   (optional) The dcagent api port
#   Defaults to 8325
#
# [*package_ensure*]
#   (optional) The state of the package
#   Defaults to present
#
# [*bind_host*]
#   (optional) The dcagent api bind address
#   Defaults to 0.0.0.0
#
# [*enabled*]
#   (optional) The state of the service
#   Defaults to true
#
class dcagent::api (
  $keystone_password,
  $keystone_enabled           = true,
  $keystone_tenant            = 'services',
  $keystone_user              = 'dcagent',
  $keystone_auth_host         = 'localhost',
  $keystone_auth_port         = '5000',
  $keystone_auth_protocol     = 'http',
  $keystone_auth_admin_prefix = false,
  $keystone_auth_uri          = false,
  $keystone_auth_version      = false,
  $keystone_identity_uri      = false,
  $keystone_user_domain       = 'Default',
  $keystone_project_domain    = 'Default',
  $keystone_http_connect_timeout = '15',
  $auth_type                  = 'password',
  $package_ensure             = 'latest',
  $bind_host                  = '0.0.0.0',
  $bind_port                  = 8325,
  $enabled                    = false
) {

  include dcagent::params

  Dcagent_config<||> ~> Service['dcagent-audit']

  if $::dcagent::params::api_package {
    Package['dcagent-audit'] -> Dcagent_config<||>
    Package['dcagent-audit'] -> Service['dcagent-audit']
    package { 'dcagent-audit':
      ensure => $package_ensure,
      name   => $::dcagent::params::api_package,
    }
  }

  dcagent_config {
    'DEFAULT/bind_host': value => $bind_host;
    'DEFAULT/bind_port': value => $bind_port;
  }

  if $keystone_identity_uri {
    dcagent_config { 'keystone_authtoken/auth_url': value => $keystone_identity_uri; }
    dcagent_config { 'cache/auth_uri': value => "${keystone_identity_uri}/v3"; }
    dcagent_config { 'endpoint_cache/auth_uri': value => "${keystone_identity_uri}/v3"; }
  } else {
    dcagent_config { 'keystone_authtoken/auth_url': value => "${keystone_auth_protocol}://${keystone_auth_host}:5000/v3"; }
  }

  if $keystone_auth_uri {
    dcagent_config { 'keystone_authtoken/auth_uri': value => $keystone_auth_uri; }
  } else {
    dcagent_config {
      'keystone_authtoken/auth_uri': value => "${keystone_auth_protocol}://${keystone_auth_host}:5000/v3";
    }
  }

  if $keystone_auth_version {
    dcagent_config { 'keystone_authtoken/auth_version': value => $keystone_auth_version; }
  } else {
    dcagent_config { 'keystone_authtoken/auth_version': ensure => absent; }
  }

  if $keystone_enabled {
    dcagent_config {
      'DEFAULT/auth_strategy':     value => 'keystone' ;
    }
    dcagent_config {
      'keystone_authtoken/auth_type':    value => $auth_type;
      'keystone_authtoken/project_name': value => $keystone_tenant;
      'keystone_authtoken/username':     value => $keystone_user;
      'keystone_authtoken/password':     value => $keystone_password, secret=> true;
      'keystone_authtoken/user_domain_name':  value => $keystone_user_domain;
      'keystone_authtoken/project_domain_name':  value => $keystone_project_domain;
    }

    dcagent_config {
      'endpoint_cache/auth_plugin':    value => $auth_type;
      'endpoint_cache/username':     value => $keystone_user;
      'endpoint_cache/password':     value => $keystone_password, secret=> true;
      'endpoint_cache/project_name': value => $keystone_tenant;
      'endpoint_cache/user_domain_name':     value => $keystone_user_domain;
      'endpoint_cache/project_domain_name':  value => $keystone_project_domain;
      'endpoint_cache/http_connect_timeout': value => $keystone_http_connect_timeout;
    }

    if $keystone_auth_admin_prefix {
      validate_re($keystone_auth_admin_prefix, '^(/.+[^/])?$')
      dcagent_config {
        'keystone_authtoken/auth_admin_prefix': value => $keystone_auth_admin_prefix;
      }
    } else {
      dcagent_config {
        'keystone_authtoken/auth_admin_prefix': ensure => absent;
      }
    }
  }
  else
  {
    dcagent_config {
      'DEFAULT/auth_strategy':     value => 'noauth' ;
    }
  }

  if $enabled {
    $ensure = 'running'
  } else {
    $ensure = 'stopped'
  }

  service { 'dcagent-audit':
    ensure     => $ensure,
    name       => $::dcagent::params::api_service,
    enable     => $enabled,
    hasstatus  => true,
    hasrestart => true,
    tag        => 'dcagent-audit',
  }
  Keystone_endpoint<||> -> Service['dcagent-audit']
}

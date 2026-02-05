#
# Files in this package are licensed under Apache; see LICENSE file.
#
# Copyright (c) 2024 Wind River Systems, Inc.
#
# SPDX-License-Identifier: Apache-2.0
#
#  Jul 2024: creation
#

# == Class: dcagent::keystone::auth
#
# Configures dcagent user, service and endpoint in Keystone.
#
class dcagent::keystone::auth (
  $password,
  $auth_domain,
  $auth_name              = 'dcagent',
  $email                  = 'dcagent@localhost',
  $tenant                 = 'services',
  $region                 = 'RegionOne',
  $service_description    = 'DCAgent service',
  $service_name           = 'dcagent',
  $service_type           = 'dcagent',
  $configure_endpoint     = true,
  $configure_user         = true,
  $configure_user_role    = true,
  $public_url             = 'http://127.0.0.1:8325/v1',
  $admin_url              = 'http://127.0.0.1:8325/v1',
  $internal_url           = 'http://127.0.0.1:8325/v1',
  $distributed_cloud_role = 'none',
) {

  $real_service_name = pick($service_name, $auth_name)

  if $distributed_cloud_role == 'subcloud' {
    keystone::resource::service_identity { 'dcagent':
      configure_user      => $configure_user,
      configure_user_role => $configure_user_role,
      configure_endpoint  => $configure_endpoint,
      service_type        => $service_type,
      service_description => $service_description,
      service_name        => $real_service_name,
      region              => $region,
      auth_name           => $auth_name,
      password            => $password,
      email               => $email,
      tenant              => $tenant,
      public_url          => $public_url,
      admin_url           => $admin_url,
      internal_url        => $internal_url,
    }

    # dcagent is a private service only used by dcmanager-audit and dcorch,
    # its API is not exposed for public access.
    -> exec { 'Delete dcagent public endpoint':
      path      => '/usr/bin',
      command   => @("CMD"/L),
        /bin/sh -c 'source /etc/platform/openrc && \
        openstack endpoint list --service dcagent --interface public --format value -c ID | \
        xargs --no-run-if-empty openstack endpoint delete'
        | CMD
      logoutput => true,
    }
  }
}

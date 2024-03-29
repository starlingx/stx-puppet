#
# Copyright (c) 2023 Wind River Systems, Inc.
#
# SPDX-License-Identifier: Apache-2.0
#

class usm::keystone::auth (
  $password,
  $auth_name            = 'usm',
  $tenant               = 'services',
  $email                = 'usm@localhost',
  $region               = 'RegionOne',
  $service_description  = 'USM Service',
  $service_name         = undef,
  $service_type         = 'usm',
  $configure_endpoint   = true,
  $configure_user       = true,
  $configure_user_role  = true,
  $public_url           = 'http://127.0.0.1:15497/v1',
  $admin_url            = 'http://127.0.0.1:5497/v1',
  $internal_url         = 'http://127.0.0.1:5497/v1',
) {
  $real_service_name = pick($service_name, $auth_name)

  keystone::resource::service_identity { 'usm':
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

}

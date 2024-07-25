class platform::dcagent::params (
  $api_port = 8325,
  $region_name = undef,
  $service_create = false,
  $service_enabled = false,
  $default_endpoint_type = 'internalURL',
) {
  include ::platform::params
}

class platform::dcagent
  inherits ::platform::dcagent::params {
  if ($::platform::params::distributed_cloud_role == 'subcloud' or
      $::platform::params::distributed_cloud_role == 'systemcontroller') {
    if $service_create {
      if $::platform::params::init_keystone {
        include ::dcagent::keystone::auth
      }

      class { '::dcagent': }
    }
  }
}

class platform::dcagent::api
  inherits ::platform::dcagent::params {
  if ($::platform::params::distributed_cloud_role == 'subcloud') {
    if $service_create {
      include ::platform::network::mgmt::params

      include ::platform::params

      $system_mode = $::platform::params::system_mode

      # FQDN can be used after:
      # - after the bootstrap for any installation
      # - mate controller uses FQDN if mgmt::params::fqdn_ready is present
      #     mate controller can use FQDN before the bootstrap flag
      # - just AIO-SX can use FQDN during the an upgrade. For other installs
      #     the active controller in older release can resolve the .internal FQDN
      #     when the mate controller is updated to N+1 version
      if (!str2bool($::is_upgrade_do_not_use_fqdn) or $system_mode == 'simplex') {
        if (str2bool($::is_bootstrap_completed)) {
          $fqdn_ready = true
        } else {
          if ($::platform::network::mgmt::params::fqdn_ready != undef) {
            $fqdn_ready = $::platform::network::mgmt::params::fqdn_ready
          }
          else {
            $fqdn_ready = false
          }
        }
      }
      else {
        $fqdn_ready = false
      }

      if ($fqdn_ready) {
          $api_host = $::platform::params::controller_fqdn
      } else {
          $api_host = $::platform::network::mgmt::params::controller_address
      }

      class { '::dcagent::api':
        bind_host => $api_host,
        bind_port => $api_port,
        enabled   => $service_enabled,
      }
    }
  }

  include ::platform::dcagent::haproxy
}

class platform::dcagent::haproxy
  inherits ::platform::dcagent::params {
  include ::platform::params
  include ::platform::haproxy::params

  # Configure rules for https enabled admin endpoint.
  if ($::platform::params::distributed_cloud_role == 'subcloud') {
    platform::haproxy::proxy { 'dcagent-restapi-admin':
      https_ep_type     => 'admin',
      server_name       => 's-dcagent',
      public_ip_address => $::platform::haproxy::params::private_dc_ip_address,
      public_port       => $api_port + 1,
      private_port      => $api_port,
    }
  }
}

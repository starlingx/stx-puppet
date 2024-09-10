class platform::dcorch::params (
  $api_port = 8118,
  $region_name = undef,
  $domain_name = undef,
  $domain_admin = undef,
  $domain_pwd = undef,
  $service_name = 'dcorch',
  $default_endpoint_type = 'internalURL',
  $service_create = false,
  $neutron_api_proxy_port = 29696,
  $nova_api_proxy_port = 28774,
  $sysinv_api_proxy_port = undef,
  $cinder_api_proxy_port = 28776,
  $cinder_enable_ports   = false,
  $patch_api_proxy_port = undef,
  $usm_api_proxy_port = undef,
  $identity_api_proxy_port = undef,
  $sysinv_api_proxy_client_timeout = '600s',
  $sysinv_api_proxy_server_timeout = '600s',
  $engine_workers = undef,
) {
  include ::platform::params

  include ::platform::network::mgmt::params

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
}


class platform::dcorch
  inherits ::platform::dcorch::params {
  if $::platform::params::distributed_cloud_role =='systemcontroller' {
    include ::platform::params
    include ::platform::amqp::params
    include ::platform::network::mgmt::params

    if $::platform::params::init_database {
      include ::dcorch::db::postgresql
    }

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

    # If not defined, worker values can vary from 4 to 6 depending
    # on the number of physical cores and memory available
    if $::platform::dcorch::params::engine_workers == undef {
      $engine_workers_value = min($::platform::params::eng_workers_by_2, 6)
    } else {
      $engine_workers_value = $::platform::dcorch::params::engine_workers
    }

    class { '::dcorch':
      rabbit_host       => (str2bool($fqdn_ready)) ? {
                              true    => $::platform::amqp::params::host,
                              default => $::platform::amqp::params::host_url,
                            },
      rabbit_port       => $::platform::amqp::params::port,
      rabbit_userid     => $::platform::amqp::params::auth_user,
      rabbit_password   => $::platform::amqp::params::auth_password,
      proxy_bind_host   => $api_host,
      proxy_remote_host => $api_host,
      engine_workers    => $engine_workers_value,
    }

    # Purge dcorch database 20 minutes in the first hour daily
    cron { 'dcorch-cleaner':
      ensure      => 'present',
      command     => '/usr/bin/clean-dcorch',
      environment => 'PATH=/bin:/usr/bin:/usr/sbin',
      minute      => '20',
      hour        => '*/24',
      user        => 'root',
    }

  }
}


class platform::dcorch::firewall
  inherits ::platform::dcorch::params {
  if $::platform::params::distributed_cloud_role =='systemcontroller' {
    platform::firewall::rule { 'dcorch-api':
      service_name => 'dcorch',
      ports        => $api_port,
    }
    platform::firewall::rule { 'dcorch-nova-api-proxy':
      service_name => 'dcorch-nova-api-proxy',
      ports        => $nova_api_proxy_port,
    }
    platform::firewall::rule { 'dcorch-neutron-api-proxy':
      service_name => 'dcorch-neutron-api-proxy',
      ports        => $neutron_api_proxy_port,
    }
    platform::firewall::rule { 'dcorch-cinder-api-proxy':
      service_name => 'dcorch-cinder-api-proxy',
      ports        => $cinder_api_proxy_port,
    }
  }
}


class platform::dcorch::haproxy
  inherits ::platform::dcorch::params {
  include ::platform::haproxy::params

  if $::platform::params::distributed_cloud_role =='systemcontroller' {
    platform::haproxy::proxy { 'dcorch-neutron-api-proxy':
      server_name  => 's-dcorch-neutron-api-proxy',
      public_port  => $neutron_api_proxy_port,
      private_port => $neutron_api_proxy_port,
    }
    platform::haproxy::proxy { 'dcorch-nova-api-proxy':
      server_name  => 's-dcorch-nova-api-proxy',
      public_port  => $nova_api_proxy_port,
      private_port => $nova_api_proxy_port,
    }
    platform::haproxy::proxy { 'dcorch-sysinv-api-proxy':
      server_name    => 's-dcorch-sysinv-api-proxy',
      public_port    => $sysinv_api_proxy_port,
      private_port   => $sysinv_api_proxy_port,
      client_timeout => $sysinv_api_proxy_client_timeout,
      server_timeout => $sysinv_api_proxy_server_timeout,
    }
    platform::haproxy::proxy { 'dcorch-cinder-api-proxy':
      server_name  => 's-cinder-dc-api-proxy',
      public_port  => $cinder_api_proxy_port,
      private_port => $cinder_api_proxy_port,
    }
    platform::haproxy::proxy { 'dcorch-patch-api-proxy':
      server_name  => 's-dcorch-patch-api-proxy',
      public_port  => $patch_api_proxy_port,
      private_port => $patch_api_proxy_port,
    }
    platform::haproxy::proxy { 'dcorch-usm-api-proxy':
      server_name  => 's-dcorch-usm-api-proxy',
      public_port  => $usm_api_proxy_port,
      private_port => $usm_api_proxy_port,
    }
    platform::haproxy::proxy { 'dcorch-identity-api-proxy':
      server_name  => 's-dcorch-identity-api-proxy',
      public_port  => $identity_api_proxy_port,
      private_port => $identity_api_proxy_port,
    }

    # Configure rules for https enabled identity api proxy admin endpoint.
    platform::haproxy::proxy { 'dcorch-identity-api-proxy-admin':
      https_ep_type     => 'admin',
      server_name       => 's-dcorch-identity-api-proxy',
      public_ip_address => $::platform::haproxy::params::private_ip_address,
      public_port       => $identity_api_proxy_port + 1,
      private_port      => $identity_api_proxy_port,
    }
    # Configure rules for https enabled sysinv api proxy admin endpoint.
    platform::haproxy::proxy { 'dcorch-sysinv-api-proxy-admin':
      https_ep_type     => 'admin',
      server_name       => 's-dcorch-sysinv-api-proxy',
      public_ip_address => $::platform::haproxy::params::private_ip_address,
      public_port       => $sysinv_api_proxy_port + 1,
      private_port      => $sysinv_api_proxy_port,
      client_timeout    => $sysinv_api_proxy_client_timeout,
      server_timeout    => $sysinv_api_proxy_server_timeout,
    }
    # Configure rules for https enabled patching api proxy admin endpoint.
    platform::haproxy::proxy { 'dcorch-patch-api-proxy-admin':
      https_ep_type     => 'admin',
      server_name       => 's-dcorch-patch-api-proxy',
      public_ip_address => $::platform::haproxy::params::private_ip_address,
      public_port       => $patch_api_proxy_port + 1,
      private_port      => $patch_api_proxy_port,
    }
    # Configure rules for https enabled usm api proxy admin endpoint.
    platform::haproxy::proxy { 'dcorch-usm-api-proxy-admin':
      https_ep_type     => 'admin',
      server_name       => 's-dcorch-usm-api-proxy',
      public_ip_address => $::platform::haproxy::params::private_ip_address,
      public_port       => $usm_api_proxy_port + 1,
      private_port      => $usm_api_proxy_port,
    }
  }
}

class platform::dcorch::engine
  inherits ::platform::dcorch::params {
  if $::platform::params::distributed_cloud_role =='systemcontroller' {
    include ::dcorch::engine
  }
}


class platform::dcorch::api_proxy
  inherits ::platform::dcorch::params {
  if $::platform::params::distributed_cloud_role =='systemcontroller' {
    if ($::platform::dcorch::params::service_create and
        $::platform::params::init_keystone) {
      include ::dcorch::keystone::auth
    }

    class { '::dcorch::api_proxy':
      bind_host => $api_host,
      sync_db   => $::platform::params::init_database,
    }

    include ::platform::dcorch::firewall
    include ::platform::dcorch::haproxy
  }
}

class platform::dcorch::runtime {
  if $::platform::params::distributed_cloud_role == 'systemcontroller' {
    include ::platform::amqp::params
    include ::dcorch
    include ::dcorch::db::postgresql

    class { '::dcorch::api_proxy':
      sync_db   => str2bool($::is_standalone_controller),
    }
  }
}

class platform::dcorch::stx_openstack::runtime
  inherits ::platform::dcorch::params {
  if ($::platform::params::distributed_cloud_role == 'systemcontroller') {
    if $service_create {
      class { '::dcorch::stx_openstack': }
    }
  }
}

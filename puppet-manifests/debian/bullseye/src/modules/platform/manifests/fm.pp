class platform::fm::params (
  $api_port = undef,
  $api_host = '127.0.0.1',
  $region_name = undef,
  $system_name = undef,
  $service_create = false,
  $service_enabled = true,
  $sysinv_catalog_info = 'platform:sysinv:internalURL',
  $snmp_enabled = 0,
  $snmp_trap_server_port = 162,
) {
  # Set default values for database connection for AIO systems (except for
  # systemcontroller on DC)
  if ($::platform::params::system_type == 'All-in-one' and
      $::platform::params::distributed_cloud_role != 'systemcontroller') {
    $db_idle_timeout = 60
    $db_pool_size = 1
    $db_over_size = 5
  } else {
    $db_idle_timeout = undef
    $db_pool_size = undef
    $db_over_size = undef
  }
}

class platform::fm::custom::params (
  $db_idle_timeout = undef,
  $db_pool_size    = undef,
  $db_over_size    = undef,
) {}

class platform::fm::config
  inherits ::platform::fm::params {
  include ::platform::fm::custom::params

  # Decides between -in order- (1) custom: defined by system parameters,
  # (2) AIO values defined on params class, or (3) the default values defined
  # on personality yaml
  if $::platform::fm::custom::params::db_idle_timeout {
    $db_idle_timeout = $::platform::fm::custom::params::db_idle_timeout
  } else {
    $db_idle_timeout = $::platform::fm::params::db_idle_timeout
  }

  if $::platform::fm::custom::params::db_pool_size {
    $db_pool_size = $::platform::fm::custom::params::db_pool_size
  } else {
    $db_pool_size = $::platform::fm::params::db_pool_size
  }

  if $::platform::fm::custom::params::db_over_size {
    $db_over_size = $::platform::fm::custom::params::db_over_size
  } else {
    $db_over_size = $::platform::fm::params::db_over_size
  }

  class { '::fm':
    region_name            => $region_name,
    system_name            => $system_name,
    sysinv_catalog_info    => $sysinv_catalog_info,
    snmp_enabled           => $snmp_enabled,
    snmp_trap_server_port  => $snmp_trap_server_port,
    database_idle_timeout  => $db_idle_timeout,
    database_max_pool_size => $db_pool_size,
    database_min_pool_size => $db_pool_size,
    database_max_overflow  => $db_over_size,
  }
}

class platform::fm
  inherits ::platform::fm::params {

  include ::fm::client
  include ::fm::keystone::authtoken
  include ::platform::fm::config

  include ::platform::params
  if $::platform::params::init_database {
    include ::fm::db::postgresql
  }
}

class platform::fm::haproxy
  inherits ::platform::fm::params {

  include ::platform::params
  include ::platform::haproxy::params

  $system_mode = $::platform::params::system_mode

  if $system_mode != 'simplex' {
    platform::haproxy::proxy { 'fm-api-internal':
      server_name        => 's-fm-api-internal',
      public_ip_address  => $::platform::haproxy::params::private_ip_address,
      public_port        => $api_port,
      private_ip_address => $api_host,
      private_port       => $api_port,
      public_api         => false,
    }
  }

  platform::haproxy::proxy { 'fm-api-public':
    server_name  => 's-fm-api-public',
    public_port  => $api_port,
    private_port => $api_port,
  }

  # Configure rules for DC https enabled admin endpoint.
  if ($::platform::params::distributed_cloud_role == 'systemcontroller' or
      $::platform::params::distributed_cloud_role == 'subcloud') {
    platform::haproxy::proxy { 'fm-api-admin':
      https_ep_type     => 'admin',
      server_name       => 's-fm-api-admin',
      public_ip_address => $::platform::haproxy::params::private_dc_ip_address,
      public_port       => $api_port + 1,
      private_port      => $api_port,
    }
  }
}

class platform::fm::api
  inherits ::platform::fm::params {

  include ::platform::params

  # Assign up to 6 workers for system controllers
  if $::platform::params::distributed_cloud_role =='systemcontroller' {
    $assigned_workers = min($::platform::params::eng_workers, 6)
  } else {
    $assigned_workers = $::platform::params::eng_workers
  }

  # override the configuration of fm-api.service
  $fmapi_override_dir = '/etc/systemd/system/fm-api.service.d'

  file { $fmapi_override_dir:
    ensure => 'directory',
    owner  => 'root',
    group  => 'root',
    mode   => '0755',
  }

  -> file { "${fmapi_override_dir}/fm-api-stx-override.conf":
    ensure  => 'present',
    owner   => 'root',
    group   => 'root',
    mode    => '0644',
    content => template('platform/fm-api-stx-override.conf.erb'),
  }

  if $service_enabled {
    if ($::platform::fm::service_create and
        $::platform::params::init_keystone) {
      include ::fm::keystone::auth
    }

    include ::platform::params

    class { '::fm::api':
      host    => $api_host,
      workers => $assigned_workers,
      sync_db => $::platform::params::init_database,
    }

    include ::platform::fm::haproxy
  }
}

class platform::fm::runtime {

  require ::platform::fm::config

  exec { 'notify-fm-mgr':
    command => '/usr/bin/pkill -HUP fmManager',
    onlyif  => 'pgrep fmManager'
  }
}

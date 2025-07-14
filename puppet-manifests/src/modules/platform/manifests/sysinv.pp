class platform::sysinv::params (
  $api_port = undef,
  $region_name = undef,
  $service_create = false,
  $fm_catalog_info = 'faultmanagement:fm:internalURL',
  $server_timeout = '600s',
  $sysinv_api_workers = undef,
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

class platform::sysinv::custom::params (
  $db_idle_timeout = undef,
  $db_pool_size    = undef,
  $db_over_size    = undef,
) {}

class platform::sysinv
  inherits ::platform::sysinv::params {

  Anchor['platform::services'] -> Class[$name]

  include ::platform::params
  include ::platform::drbd::platform::params
  include ::platform::sysinv::custom::params

  # sysinv-agent is started on all hosts
  include ::sysinv::agent

  $keystone_key_repo_path = "${::platform::drbd::platform::params::mountpoint}/keystone"

  group { 'sysinv':
    ensure => 'present',
    gid    => '168',
  }

  -> user { 'sysinv':
    ensure           => 'present',
    comment          => 'sysinv Daemons',
    gid              => '168',
    groups           => ['nobody', 'sysinv', 'sys_protected'],
    home             => '/var/lib/sysinv',
    password         => '!!',
    password_max_age => '-1',
    password_min_age => '-1',
    shell            => '/sbin/nologin',
    uid              => '168',
  }

  -> file { '/etc/sysinv':
    ensure => 'directory',
    owner  => 'sysinv',
    group  => 'sysinv',
    mode   => '0750',
  }

  -> class { '::sysinv':
    fm_catalog_info       => $fm_catalog_info,
    fernet_key_repository => "${keystone_key_repo_path}/fernet-keys",
  }

  # Note: The log format strings are prefixed with "sysinv" because it is
  # interpreted as the program by syslog-ng, which allows the sysinv logs to be
  # filtered and directed to their own file.

  # TODO(mpeters): update puppet-sysinv to permit configuration of log formats
  # once the log configuration has been moved to oslo::log
  sysinv_config {
    'DEFAULT/logging_context_format_string': value =>
      'sysinv %(asctime)s.%(msecs)03d %(process)d %(levelname)s %(name)s [%(request_id)s %(user)s %(tenant)s] %(instance)s%(message)s';
    'DEFAULT/logging_default_format_string': value =>
      'sysinv %(asctime)s.%(msecs)03d %(process)d %(levelname)s %(name)s [-] %(instance)s%(message)s';
  }

  # Setup app framework behavior
  sysinv_config {
    'app_framework/missing_auto_update': value => true;
    'app_framework/skip_k8s_application_audit': value => false;
  }

  # On AIO systems, restrict the connection pool size
  # If database information doesn't exist in yaml file, use default values
  if $::platform::sysinv::custom::params::db_idle_timeout {
    Sysinv_config <| title == 'database/connection_recycle_time' |> {
      value => $::platform::sysinv::custom::params::db_idle_timeout,
    }
  } else {
    Sysinv_config <| title == 'database/connection_recycle_time' |> {
      value => $::platform::sysinv::params::db_idle_timeout,
    }
  }

  if $::platform::sysinv::custom::params::db_pool_size {
    Sysinv_config <| title == 'database/max_pool_size' |> {
      value => $::platform::sysinv::custom::params::db_pool_size,
    }
  } else {
    Sysinv_config <| title == 'database/max_pool_size' |> {
      value => $::platform::sysinv::params::db_pool_size,
    }
  }

  if $::platform::sysinv::custom::params::db_over_size {
    Sysinv_config <| title == 'database/max_overflow' |> {
      value => $::platform::sysinv::custom::params::db_over_size,
    }
  } else {
    Sysinv_config <| title == 'database/max_overflow' |> {
      value => $::platform::sysinv::params::db_over_size,
    }
  }
}


class platform::sysinv::conductor {

  Class['::platform::drbd::platform'] -> Class[$name]

  include ::sysinv::conductor
}


class platform::sysinv::haproxy
  inherits ::platform::sysinv::params {
  include ::platform::params
  include ::platform::haproxy::params

  platform::haproxy::proxy { 'sysinv-restapi':
    server_name    => 's-sysinv',
    public_port    => $api_port,
    private_port   => $api_port,
    server_timeout => $server_timeout,
  }

  # Configure rules for DC https enabled admin endpoint.
  if ($::platform::params::distributed_cloud_role == 'systemcontroller' or
      $::platform::params::distributed_cloud_role == 'subcloud') {
    platform::haproxy::proxy { 'sysinv-restapi-admin':
      https_ep_type     => 'admin',
      server_name       => 's-sysinv',
      public_ip_address => $::platform::haproxy::params::private_dc_ip_address,
      public_port       => $api_port + 1,
      private_port      => $api_port,
      server_timeout    => $server_timeout,
    }
  }
}


class platform::sysinv::api
  inherits ::platform::sysinv::params {

  include ::platform::params
  include ::sysinv::api

  if ($::platform::sysinv::params::service_create and
      $::platform::params::init_keystone) {
    include ::sysinv::keystone::auth

    # Cleanup the endpoints created at bootstrap if they are not in
    # the subcloud region.
    if ($::platform::params::distributed_cloud_role == 'subcloud' and
        $::platform::params::region_2_name != 'RegionOne') {
      Keystone_endpoint["${platform::params::region_2_name}/sysinv::platform"] -> Keystone_endpoint['RegionOne/sysinv::platform']
      keystone_endpoint { 'RegionOne/sysinv::platform':
        ensure       => 'absent',
        name         => 'sysinv',
        type         => 'platform',
        region       => 'RegionOne',
        public_url   => 'http://127.0.0.1:6385/v1',
        admin_url    => 'http://127.0.0.1:6385/v1',
        internal_url => 'http://127.0.0.1:6385/v1'
      }
    }
  }

  if ($::platform::sysinv::params::sysinv_api_workers != undef) {

    sysinv_config{
      'DEFAULT/sysinv_api_workers': value => $::platform::sysinv::params::sysinv_api_workers
    }
  } else {
    if $::platform::params::distributed_cloud_role =='systemcontroller' {
      sysinv_config{
        'DEFAULT/sysinv_api_workers': value => min($::platform::params::eng_workers_by_5, 6);
      }
    } else {
      # TODO(mpeters): move to sysinv puppet module parameters
      sysinv_config {
        'DEFAULT/sysinv_api_workers': value => $::platform::params::eng_workers_by_5;
      }
    }
  }

  include ::platform::sysinv::haproxy
}

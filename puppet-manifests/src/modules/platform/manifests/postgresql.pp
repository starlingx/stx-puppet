class platform::postgresql::base::params {
  include ::platform::params

  if $::platform::params::system_type == 'All-in-one' and
      $::platform::params::distributed_cloud_role != 'systemcontroller' {
    # Scale down AIO
    $autovacuum_max_workers = min($::platform::params::eng_workers, 5)
    $max_worker_processes = min($::platform::params::eng_workers, 8)
    $max_parallel_workers = min($::platform::params::eng_workers, 8)
    $max_parallel_maintenance_workers = min($::platform::params::eng_workers, 2)
    $max_parallel_workers_per_gather = min($::platform::params::eng_workers, 2)
  } else {
    # Make autovacuum more aggressive
    $autovacuum_max_workers = 5
    # Default values
    $max_worker_processes = 8
    $max_parallel_workers = 8
    $max_parallel_maintenance_workers = 2
    $max_parallel_workers_per_gather = 2
  }
}

class platform::postgresql::custom::params (
    $autovacuum_max_workers           = undef,
    $max_worker_processes             = undef,
    $max_parallel_workers             = undef,
    $max_parallel_maintenance_workers = undef,
    $max_parallel_workers_per_gather  = undef
) {}

class platform::postgresql::params
  inherits ::platform::params {

  include ::platform::postgresql::base::params
  include ::platform::postgresql::custom::params

  if $::platform::postgresql::custom::params::autovacuum_max_workers {
    $autovacuum_max_workers = $::platform::postgresql::custom::params::autovacuum_max_workers
  }
  else {
    $autovacuum_max_workers = $::platform::postgresql::base::params::autovacuum_max_workers
  }
  if $::platform::postgresql::custom::params::max_worker_processes {
    $max_worker_processes = $::platform::postgresql::custom::params::max_worker_processes
  }
  else {
    $max_worker_processes = $::platform::postgresql::base::params::max_worker_processes
  }
  if $::platform::postgresql::custom::params::max_parallel_workers {
    $max_parallel_workers = $::platform::postgresql::custom::params::max_parallel_workers
  }
  else {
    $max_parallel_workers = $::platform::postgresql::base::params::max_parallel_workers
  }
  if $::platform::postgresql::custom::params::max_parallel_maintenance_workers {
    $max_parallel_maintenance_workers = $::platform::postgresql::custom::params::max_parallel_maintenance_workers
  }
  else {
    $max_parallel_maintenance_workers = $::platform::postgresql::base::params::max_parallel_maintenance_workers
  }
  if $::platform::postgresql::custom::params::max_parallel_workers_per_gather {
    $max_parallel_workers_per_gather = $::platform::postgresql::custom::params::max_parallel_workers_per_gather
  }
  else {
    $max_parallel_workers_per_gather = $::platform::postgresql::base::params::max_parallel_workers_per_gather
  }

  $root_dir = '/var/lib/postgresql'
  $config_dir = $::osfamily ? {
    'RedHat' => '/etc/postgresql',
    default => '/etc/postgresql/13/main',
  }

  $data_dir = "${root_dir}/${::platform::params::software_version}"

  $password = undef

  include ::platform::network::mgmt::params
  if $::platform::network::mgmt::params::subnet_version == $::platform::params::ipv6 {
    $ip_mask_allow_all_users = '::0/0'
    $ip_mask_deny_postgres_user = '::0/128'
  } else {
    $ip_mask_allow_all_users = '0.0.0.0/0'
    $ip_mask_deny_postgres_user = '0.0.0.0/32'
  }
}


class platform::postgresql::server
  inherits ::platform::postgresql::params {

  include ::platform::params

  # Set up autovacuum
  postgresql::server::config_entry { 'track_counts':
    value => 'on',
  }
  postgresql::server::config_entry { 'autovacuum':
    value => 'on',
  }
  # Only log autovacuum calls that are slow
  postgresql::server::config_entry { 'log_autovacuum_min_duration':
    value => '100',
  }
  # Set autovacuum max workers
  postgresql::server::config_entry { 'autovacuum_max_workers':
    value => $autovacuum_max_workers,
  }
  if $::osfamily == 'Debian' {
    # Set max worker processes
    postgresql::server::config_entry { 'max_worker_processes':
      value => $max_worker_processes,
    }
    # Set max parallel workers
    postgresql::server::config_entry { 'max_parallel_workers':
      value => $max_parallel_workers,
    }
    # Set max parallel maintenance workers
    postgresql::server::config_entry { 'max_parallel_maintenance_workers':
      value => $max_parallel_maintenance_workers,
    }
    # Set max parallel workers per gather
    postgresql::server::config_entry { 'max_parallel_workers_per_gather':
      value => $max_parallel_workers_per_gather,
    }
  }
  postgresql::server::config_entry { 'autovacuum_vacuum_scale_factor':
    value => '0.05',
  }
  postgresql::server::config_entry { 'autovacuum_analyze_scale_factor':
    value => '0.1',
  }
  postgresql::server::config_entry { 'autovacuum_vacuum_cost_delay':
    value => '-1',
  }
  postgresql::server::config_entry { 'autovacuum_vacuum_cost_limit':
    value => '-1',
  }

  # Set up logging
  postgresql::server::config_entry { 'log_destination':
    value => 'syslog',
  }
  postgresql::server::config_entry { 'syslog_facility':
    value => 'LOCAL0',
  }

  # log postgres operations that exceed 1 second
  postgresql::server::config_entry { 'log_min_duration_statement':
    value => '1000',
  }

  # turn jit 'off' on Debian (it is on by default) since it negatively impacts performance
  if $::osfamily == 'Debian' {
    postgresql::server::config_entry { 'jit':
      value => 'off',
    }
  }


  # Set large values for postgres in standard or system controller.
  # In AIO or virtual box, use reduced settings.
  #
  if ((str2bool($::is_worker_subfunction) and
        ($::platform::params::distributed_cloud_role !='systemcontroller')) or
      (str2bool($::is_virtual))) {
    # Non system controller AIO or virtual box
    # 700 connections, 80MB shared_buffers
    postgresql::server::config_entry { 'max_connections':
      value => '700',
    }
    postgresql::server::config_entry { 'shared_buffers':
      value => '80MB',
    }
  } else {
    # System controller or standard controller
    # 1500 connections, 80MB shared_buffers, increase work_mem and
    # checkpoint_segments
    # TODO:
    #   - re-assess work_mem setting considering the complexity of the current
    #     queries.
    #   - re-assess shared_buffers setting for the system controller in a large
    #     distributed cloud.
    postgresql::server::config_entry { 'max_connections':
      value => '1500',
    }
    postgresql::server::config_entry { 'shared_buffers':
      value => '80MB',
    }
    postgresql::server::config_entry { 'work_mem':
      value => '512MB',
    }
    if $::osfamily == 'Debian' {
      postgresql::server::config_entry { 'max_wal_size':
        # checkpoint_segments was replaced by min_wal_size and max_wal_size
        # since Postgres 9.5. The default value of min_wal_size is 80MB.
        # The max_wal_size is set based on the following recommended formula
        # max_wal_size = (3 * checkpoint_segments) * 16MB
        value => '480MB',
      }
    } else {
      postgresql::server::config_entry { 'checkpoint_segments':
        value => '10',
      }
    }
  }

  class {'::postgresql::globals':
    datadir => $data_dir,
    confdir => $config_dir,
  }

  -> class {'::postgresql::server':
    ip_mask_allow_all_users    => $ip_mask_allow_all_users,
    ip_mask_deny_postgres_user => $ip_mask_deny_postgres_user,
    service_ensure             => 'stopped',
  }
}


class platform::postgresql::post {
  # postgresql needs to be running in order to apply the initial manifest,
  # however, it needs to be stopped/disabled to allow SM to manage the service.
  # To allow for the transition it must be explicitely stopped. Once puppet
  # can directly handle SM managed services, then this can be removed.
  if $::osfamily == 'RedHat' {
    exec { 'stop postgresql service':
        command => 'systemctl stop postgresql; systemctl disable postgresql',
    }
  } else {
    exec { 'stop postgresql service':
        command => 'systemctl stop postgresql@*.service; systemctl disable postgresql',
    }
  }
}


class platform::postgresql::bootstrap
  inherits ::platform::postgresql::params {

  Class['::platform::drbd::pgsql'] -> Class[$name]

  if $::osfamily == 'RedHat' {
    exec { 'Empty pg dir':
        command => "rm -fR ${root_dir}/*",
    }

    -> exec { 'Create pg datadir':
        command => "mkdir -p ${data_dir}",
    }

    -> exec { 'Change pg dir permissions':
        command => "chown -R postgres:postgres ${root_dir}",
    }

    -> file_line { 'allow sudo with no tty':
        path  => '/etc/sudoers',
        match => '^Defaults *requiretty',
        line  => '#Defaults    requiretty',
    }

    -> exec { 'Create pg database':
        command => "sudo -u postgres initdb -D ${data_dir}",
    }

    -> exec { 'Move Config files':
        command => "mkdir -p ${config_dir} && mv ${data_dir}/*.conf ${config_dir}/ && ln -s ${config_dir}/*.conf ${data_dir}/",
    }
  } else {
    exec { 'Drop pg database':
        command => 'pg_dropcluster 13 main',
    }

    -> exec { 'Create pg database':
        command => "pg_createcluster -d ${data_dir} 13 main",
    }

    -> exec { 'Set up symbolic links to config files':
        command => "ln -s ${config_dir}/*.conf /etc/postgresql/",
    }

    -> exec { 'Explicitly turn off jit':
        command => 'pg_conftool 13 main set jit off',
    }

    -> exec { 'Disable include_dir':
        command => 'pg_conftool 13 main remove include_dir',
    }

    -> exec { 'Change pg dir permissions':
        command => "chown -R postgres:postgres ${root_dir}",
    }
  }
  -> class {'::postgresql::globals':
    datadir => $data_dir,
    confdir => $config_dir,
  }

  -> class {'::postgresql::server':
    ip_mask_allow_all_users    => $ip_mask_allow_all_users,
    ip_mask_deny_postgres_user => $ip_mask_deny_postgres_user
  }

  if $::osfamily == 'Debian' {
    exec { 'Disable systemd from starting postgresql':
        command => 'echo manual > /etc/postgresql/13/main/start.conf ; systemctl daemon-reload',
    }
    Class['::postgresql::server'] -> Exec['Disable systemd from starting postgresql']
  }

  # Allow local postgres user as trusted for simplex upgrade scripts
  postgresql::server::pg_hba_rule { 'postgres trusted local access':
    type        => 'local',
    user        => 'postgres',
    auth_method => 'trust',
    database    => 'all',
    order       => '000',
  }

  postgresql::server::role {'admin':
    password_hash => 'admin',
    superuser     => true,
  }
}

class platform::postgresql::upgrade
  inherits ::platform::postgresql::params {

  if $::osfamily == 'RedHat' {
    exec { 'Move Config files':
        command => "mkdir -p ${config_dir} && mv ${data_dir}/*.conf ${config_dir}/ && ln -s ${config_dir}/*.conf ${data_dir}/",
    }
  } else {
    exec { 'Set up symbolic links to config files':
        command => "ln -s ${config_dir}/*.conf /etc/postgresql/",
    }
  }

  -> class {'::postgresql::globals':
    datadir      => $data_dir,
    confdir      => $config_dir,
    needs_initdb => false,
  }

  -> class {'::postgresql::server':
    ip_mask_allow_all_users    => $ip_mask_allow_all_users,
    ip_mask_deny_postgres_user => $ip_mask_deny_postgres_user
  }

  include ::barbican::db::postgresql
  include ::sysinv::db::postgresql
  include ::keystone::db::postgresql
  include ::fm::db::postgresql
}

class platform::postgresql::sc::configured {

  file { '/etc/platform/.sc_database_configured':
      ensure => present,
      owner  => 'root',
      group  => 'root',
      mode   => '0644',
  }
}

class platform::postgresql::sc::runtime
  inherits ::platform::postgresql::params {
  class {'::postgresql::globals':
    datadir      => $data_dir,
    confdir      => $config_dir,
    needs_initdb => false,
  }

  -> class {'::postgresql::server':
    ip_mask_allow_all_users    => $ip_mask_allow_all_users,
    ip_mask_deny_postgres_user => $ip_mask_deny_postgres_user
  }

  include ::platform::dcmanager::runtime
  include ::platform::dcorch::runtime

  class {'::platform::postgresql::sc::configured':
    stage => post
  }
}

class platform::postgresql::runtime
  inherits ::platform::postgresql::params {

  class {'platform::postgresql::server':
    stage => post
  }
}

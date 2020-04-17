class platform::dcmanager::params (
  $api_port = 8119,
  $region_name = undef,
  $domain_name = undef,
  $domain_admin = undef,
  $domain_pwd = undef,
  $service_name = 'dcmanager',
  $default_endpoint_type = 'internalURL',
  $service_create = false,
  $deploy_base_dir = '/opt/platform/deploy',
  $iso_base_dir_source = '/opt/platform/iso',
  $iso_base_dir_target = '/www/pages/iso',
) {
  include ::platform::params

  include ::platform::network::mgmt::params
  $api_host = $::platform::network::mgmt::params::controller_address
}


class platform::dcmanager
  inherits ::platform::dcmanager::params {
  if $::platform::params::distributed_cloud_role =='systemcontroller' {
    include ::platform::params
    include ::platform::amqp::params

    if $::platform::params::init_database {
      include ::dcmanager::db::postgresql
    }

    class { '::dcmanager':
      rabbit_host     => $::platform::amqp::params::host_url,
      rabbit_port     => $::platform::amqp::params::port,
      rabbit_userid   => $::platform::amqp::params::auth_user,
      rabbit_password => $::platform::amqp::params::auth_password,
    }
    file {$iso_base_dir_source:
      ensure => directory,
      mode   => '0755',
    }
    file {$iso_base_dir_target:
      ensure => directory,
      mode   => '0755',
    }
    file {$deploy_base_dir:
      ensure => directory,
      mode   => '0755',
    }
  }
}

class platform::dcmanager::haproxy
  inherits ::platform::dcmanager::params {
  if $::platform::params::distributed_cloud_role =='systemcontroller' {
    platform::haproxy::proxy { 'dcmanager-restapi':
      server_name  => 's-dcmanager',
      public_port  => $api_port,
      private_port => $api_port,
    }
  }
}

class platform::dcmanager::manager {
  if $::platform::params::distributed_cloud_role =='systemcontroller' {
    include ::dcmanager::manager
  }
}

class platform::dcmanager::api
  inherits ::platform::dcmanager::params {
  if $::platform::params::distributed_cloud_role =='systemcontroller' {
    if ($::platform::dcmanager::params::service_create and
        $::platform::params::init_keystone) {
      include ::dcmanager::keystone::auth
    }

    class { '::dcmanager::api':
      bind_host => $api_host,
      sync_db   => $::platform::params::init_database,
    }


    include ::platform::dcmanager::haproxy
  }
}

class platform::dcmanager::fs::runtime {
  if $::platform::params::distributed_cloud_role == 'systemcontroller' {
    include ::platform::dcmanager::params
    $iso_base_dir_source = $::platform::dcmanager::params::iso_base_dir_source
    $iso_base_dir_target = $::platform::dcmanager::params::iso_base_dir_target
    $deploy_base_dir = $::platform::dcmanager::params::deploy_base_dir

    file {$iso_base_dir_source:
      ensure => directory,
      mode   => '0755',
    }

    file {$iso_base_dir_target:
      ensure => directory,
      mode   => '0755',
    }

    file {$deploy_base_dir:
      ensure => directory,
      mode   => '0755',
    }

    exec { "bind mount ${iso_base_dir_target}":
      command => "mount -o bind -t ext4 ${iso_base_dir_source} ${iso_base_dir_target}",
      require => File[ $iso_base_dir_source, $iso_base_dir_target ]
    }
  }
}

class platform::dcmanager::runtime {
  if $::platform::params::distributed_cloud_role == 'systemcontroller' {
    include ::platform::amqp::params
    include ::dcmanager
    include ::dcmanager::db::postgresql
    class { '::dcmanager::api':
      sync_db   => str2bool($::is_standalone_controller),
    }
  }
}

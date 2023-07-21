class platform::usm::params (
  $private_port = 5497,
  $public_port = undef,
  $server_timeout = '600s',
  $region_name = undef,
  $service_create = false,
) { }


class platform::usm
  inherits ::platform::usm::params {

  include ::platform::params

  group { 'usm':
    ensure => 'present',
  }
  -> user { 'usm':
    ensure           => 'present',
    comment          => 'usm Daemons',
    groups           => ['nobody', 'usm', $::platform::params::protected_group_name],
    home             => '/var/lib/usm',
    password         => '!!',
    password_max_age => '-1',
    password_min_age => '-1',
    shell            => '/sbin/nologin',
  }
  -> file { '/etc/software':
    ensure => 'directory',
    owner  => 'usm',
    group  => 'usm',
    mode   => '0755',
  }
  -> class { '::usm': }
}


class platform::usm::haproxy
  inherits ::platform::usm::params {
  include ::platform::params
  include ::platform::haproxy::params

  platform::haproxy::proxy { 'usm-restapi':
    server_name    => 's-usm',
    public_port    => $public_port,
    private_port   => $private_port,
    server_timeout => $server_timeout,
  }

  # Configure rules for DC https enabled admin endpoint.
  if ($::platform::params::distributed_cloud_role == 'systemcontroller' or
      $::platform::params::distributed_cloud_role == 'subcloud') {
    platform::haproxy::proxy { 'usm-restapi-admin':
      https_ep_type     => 'admin',
      server_name       => 's-usm',
      public_ip_address => $::platform::haproxy::params::private_dc_ip_address,
      public_port       => $private_port + 1,
      private_port      => $private_port,
      server_timeout    => $server_timeout,
    }
  }
}


class platform::usm::api (
) inherits ::platform::usm::params {

  include ::usm::api

  if ($::platform::usm::params::service_create and
      $::platform::params::init_keystone) {
    include ::usm::keystone::auth
  }

  include ::platform::usm::haproxy
}

class platform::usm::agent::reload {

  exec { 'restart software-agent':
    command   => '/usr/sbin/software-agent-restart',
    logoutput => true,
  }
}

class platform::usm::runtime {

  class {'::platform::usm::agent::reload':
    stage => post
  }
}

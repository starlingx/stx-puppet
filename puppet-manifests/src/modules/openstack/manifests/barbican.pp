class openstack::barbican::params (
  $api_port = undef,
  $region_name = undef,
  $service_name = 'barbican-api',
  $service_create = false,
) { }

class openstack::barbican
  inherits ::openstack::barbican::params {

  include ::platform::params

  if $::platform::params::init_keystone {
    include ::barbican::keystone::auth
    include ::barbican::keystone::authtoken
  }

  if $::platform::params::init_database {
    include ::barbican::db::postgresql
  }

  barbican_config {
      'service_credentials/interface': value => 'internalURL'
  }

  file { '/var/run/barbican':
    ensure => 'directory',
    owner  => 'barbican',
    group  => 'barbican',
  }

  if $::platform::params::distributed_cloud_role =='systemcontroller' {
    $api_workers = min($::platform::params::eng_workers_by_4, 3)
  } else {
    $api_workers = $::platform::params::eng_workers_by_4
  }

  file_line { 'Modify workers in gunicorn-config.py':
    path  => '/etc/barbican/gunicorn-config.py',
    line  => "workers = ${api_workers}",
    match => '.*workers = .*',
    tag   => 'modify-workers',
  }

  # On Debian barbican uses barbican-common to configure logrotate
  if $::osfamily == 'Debian' {
    file { '/etc/logrotate.d/barbican-common':
      ensure  => present,
      content => template('openstack/barbican-api-logrotate.erb')
    }
  }
  else {
    file { '/etc/logrotate.d/barbican-api':
      ensure  => present,
      content => template('openstack/barbican-api-logrotate.erb')
    }
  }

  # Limit configuration file permission
  file { '/etc/barbican/barbican.conf':
    owner => 'barbican',
    group => 'barbican',
    mode  => '0600',
  }
}

class openstack::barbican::service (
  $service_enabled = false,
) inherits ::openstack::barbican::params {

  include ::platform::params
  include ::platform::network::mgmt::params

  $system_mode = $::platform::params::system_mode
  $controller_fqdn = $::platform::params::controller_fqdn

  # gunicorn-config.py doesn't support FQDN in IPv6 scenario,
  # for IPv4 it works well, for this reason the gunicorn-config.py
  # will always use the IP address
  if $service_enabled {
      $gunicorn_bind = '[::]'
  } else {
      $gunicorn_bind = $::platform::network::mgmt::params::subnet_version ? {
        6       => "[${::platform::network::mgmt::params::controller_address}]",
        default => $::platform::network::mgmt::params::controller_address,
      }
  }

  if ($::platform::network::mgmt::params::fqdn_ready != undef) {
    $fqdn_ready = $::platform::network::mgmt::params::fqdn_ready
  }
  else {
    $fqdn_ready = false
  }

  #use FQDN after bootstrap completed
  if (str2bool($::is_bootstrap_completed) or
      $fqdn_ready) {
    $api_fqdn = $controller_fqdn
    $api_host = $controller_fqdn
  } else {
    $api_fqdn = $::platform::params::controller_hostname
    $api_host = $gunicorn_bind
  }
  $api_href = "http://${api_fqdn}:${api_port}"

  # On Debian barbican is set to run by UWSGI by default so
  # it doesn't update gunicorn-config.py. Update it in order
  # to run by gunicorn.
  if $::osfamily == 'Debian' {
    file_line { 'Modify bind_port in gunicorn-config.py':
      path  => '/etc/barbican/gunicorn-config.py',
      line  => "bind = '${gunicorn_bind}:${api_port}'",
      match => '.*bind = .*',
      tag   => 'modify-bind-port',
    }
  }

  include ::platform::amqp::params

  class { '::barbican::api':
    enabled                      => $service_enabled,
    bind_host                    => $api_host,
    bind_port                    => $api_port,
    host_href                    => $api_href,
    sync_db                      => !$::openstack::barbican::params::service_create,
    enable_proxy_headers_parsing => true,
    rabbit_use_ssl               => $::platform::amqp::params::ssl_enabled,
    default_transport_url        => $::platform::amqp::params::transport_url,
  }

  class { '::barbican::keystone::notification':
    enable_keystone_notification => true,
  }

  cron { 'barbican-cleaner':
    ensure      => 'present',
    command     => '/usr/bin/barbican-manage db clean -p -e -L /var/log/barbican/barbican-clean.log',
    environment => 'PATH=/bin:/usr/bin:/usr/sbin',
    minute      => '50',
    hour        => '*/24',
    user        => 'root',
  }
}

class openstack::barbican::haproxy
  inherits ::openstack::barbican::params {
  include ::platform::params
  include ::platform::haproxy::params

  platform::haproxy::proxy { 'barbican-restapi':
    server_name  => 's-barbican-restapi',
    public_port  => $api_port,
    private_port => $api_port,
  }

  # Configure rules for DC https enabled admin endpoint.
  if ($::platform::params::distributed_cloud_role == 'systemcontroller' or
      $::platform::params::distributed_cloud_role == 'subcloud') {
    platform::haproxy::proxy { 'barbican-restapi-admin':
      https_ep_type     => 'admin',
      server_name       => 's-barbican-restapi',
      public_ip_address => $::platform::haproxy::params::private_dc_ip_address,
      public_port       => $api_port + 1,
      private_port      => $api_port,
    }
  }
}

class openstack::barbican::api
  inherits ::openstack::barbican::params {
  include ::platform::params

  # The barbican user and service are always required and they
  # are used by subclouds when the service itself is disabled
  # on System Controller
  # whether it creates the endpoint is determined by
  # barbican::keystone::auth::configure_endpoint which is
  # set via sysinv puppet
  if ($::openstack::barbican::params::service_create and
      $::platform::params::init_keystone) {

    if ($::platform::params::distributed_cloud_role == 'subcloud' and
        $::platform::params::region_2_name != 'RegionOne') {
      Keystone_endpoint["${platform::params::region_2_name}/barbican::key-manager"] -> Keystone_endpoint['RegionOne/barbican::key-manager']
      keystone_endpoint { 'RegionOne/barbican::key-manager':
        ensure       => 'absent',
        name         => 'barbican',
        type         => 'key-manager',
        region       => 'RegionOne',
        public_url   => "http://127.0.0.1:${api_port}",
        admin_url    => "http://127.0.0.1:${api_port}",
        internal_url => "http://127.0.0.1:${api_port}"
      }
    }
  }

  include ::openstack::barbican::service
  include ::openstack::barbican::haproxy
}

class openstack::barbican::bootstrap
  inherits ::openstack::barbican::params {

  class { '::barbican::keystone::auth':
    configure_user_role => false,
  }
  class { '::barbican::keystone::authtoken':
    auth_url            => 'http://localhost:5000',
    project_name        => 'services',
    user_domain_name    => 'Default',
    project_domain_name => 'Default',
  }

  $bu_name = $::barbican::keystone::auth::auth_name
  $bu_tenant = $::barbican::keystone::auth::tenant
  keystone_role { 'creator':
    ensure => present,
  }
  keystone_user_role { "${bu_name}@${bu_tenant}":
    ensure => present,
    roles  => ['admin', 'creator'],
  }

  include ::barbican::db::postgresql

  include ::openstack::barbican
  class { '::openstack::barbican::service':
    service_enabled => true,
  }
}

class openstack::barbican::runtime
  inherits ::openstack::barbican::params {

  include ::openstack::barbican::service
}

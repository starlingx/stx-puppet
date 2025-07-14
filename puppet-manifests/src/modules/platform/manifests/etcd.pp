class platform::etcd::params (
  $bind_address = '0.0.0.0',
  $bind_address_version = 4,
  $port    = 2379,
  $node   = 'controller',
)
{
  include ::platform::params

  $sw_version = $::platform::params::software_version
  $etcd_basedir = '/opt/etcd'
  $etcd_dir = "${etcd_basedir}/db"

  if $bind_address_version == $::platform::params::ipv6 {
    $client_url = "https://[${bind_address}]:${port},https://[127.0.0.1]:${port}"
  }
  else {
    $client_url = "https://${bind_address}:${port},https://[127.0.0.1]:${port}"
  }
}

# Modify the systemd service file for etcd and
# create an init.d script for SM to manage the service
class platform::etcd::setup {

  include ::platform::params
  include ::platform::k8splatform::params

  if $::platform::params::system_type == 'All-in-one' and
    $::platform::params::distributed_cloud_role != 'systemcontroller' {
    $etcd_max_procs = $::platform::params::eng_workers
  } else {
    $etcd_max_procs = '$(nproc)'
  }

  file {'etcd_override_dir':
    ensure => directory,
    path   => '/etc/systemd/system/etcd.service.d',
    mode   => '0755',
  }
  -> file { '/etc/systemd/system/etcd.service.d/etcd-override.conf':
    ensure  => file,
    owner   => 'root',
    group   => 'root',
    mode    => '0644',
    content => template('platform/etcd-override.conf.erb'),
  }
  -> file {'etcd_initd_script':
    ensure => 'present',
    path   => '/etc/init.d/etcd',
    mode   => '0755',
    source => "puppet:///modules/${module_name}/etcd"
  }
  -> exec { 'systemd-reload-daemon':
    command     => '/usr/bin/systemctl daemon-reload',
  }
  # Mitigate systemd hung behaviour after daemon-reload
  -> exec { 'verify-systemd-running - etcd setup':
    command   => '/usr/local/bin/verify-systemd-running.sh',
    logoutput => true,
  }
  -> Service['etcd']
}

class platform::etcd::init (
  $service_enabled = false,
) inherits ::platform::etcd::params {

  if $service_enabled {
    $service_ensure = 'running'
  }
  else {
    $service_ensure = 'stopped'
  }

  $client_cert_auth = true
  $cert_file = '/etc/etcd/etcd-server.crt'
  $key_file = '/etc/etcd/etcd-server.key'
  $trusted_ca_file = '/etc/etcd/ca.crt'

  class { 'etcd':
    ensure                => 'present',
    etcd_name             => $node,
    service_enable        => false,
    service_ensure        => $service_ensure,
    cluster_enabled       => false,
    listen_client_urls    => $client_url,
    advertise_client_urls => $client_url,
    data_dir              => "${etcd_dir}/${node}.etcd",
    proxy                 => 'off',
    client_cert_auth      => $client_cert_auth,
    cert_file             => $cert_file,
    key_file              => $key_file,
    trusted_ca_file       => $trusted_ca_file,
  }
}


class platform::etcd
  inherits ::platform::etcd::params {

  Class['::platform::drbd::etcd'] -> Class[$name]

  include ::platform::etcd::datadir
  include ::platform::etcd::setup
  include ::platform::etcd::init

  Class['::platform::etcd::datadir']
  -> Class['::platform::etcd::setup']
  -> Class['::platform::etcd::init']
}

class platform::etcd::datadir
  inherits ::platform::etcd::params {

  Class['::platform::drbd::etcd'] -> Class[$name]

  if $::platform::params::init_database {
    file { $etcd_dir:
        ensure => 'directory',
        owner  => 'root',
        group  => 'root',
        mode   => '0755',
    }
  }
}

class platform::etcd::datadir::bootstrap
  inherits ::platform::etcd::params {

  require ::platform::drbd::etcd::bootstrap
  Class['::platform::drbd::etcd::bootstrap'] -> Class[$name]

  file { $etcd_dir:
      ensure => 'directory',
      owner  => 'root',
      group  => 'root',
      mode   => '0755',
  }
}

class platform::etcd::bootstrap
  inherits ::platform::etcd::params {

  include ::platform::etcd::datadir::bootstrap
  include ::platform::etcd::setup

  Class['::platform::etcd::datadir::bootstrap']
  -> Class['::platform::etcd::setup']
  -> class { '::platform::etcd::init':
    service_enabled => false,
  }
}

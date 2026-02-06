class platform::dockerdistribution::params (
    $registry_ks_endpoint = undef,
    $registry_username = undef,
    $registry_password = undef,
) {}

define platform::dockerdistribution::write_config (
  $registry_readonly = false,
  $file_path = '/etc/docker-distribution/registry/runtime_config.yml',
  $docker_registry_host = undef,
  $docker_realm_host = undef,
){
  file { $file_path:
    ensure  => present,
    owner   => 'root',
    group   => 'root',
    mode    => '0644',
    content => template('platform/dockerdistribution.conf.erb'),
  }
}

class platform::dockerdistribution::registries {
  include ::platform::docker::params

  # This class is to filter out insecure registries and store
  # insecure registries' IP into array.
  # insecure-registries used in template insecuredockerregistry.conf.erb
  # If all registries are secure, insecure_registries will be an empty array
  $registries = [
    {url => $::platform::docker::params::k8s_registry,
    secure => $::platform::docker::params::k8s_registry_secure},

    {url => $::platform::docker::params::gcr_registry,
    secure => $::platform::docker::params::gcr_registry_secure},

    {url => $::platform::docker::params::quay_registry,
    secure => $::platform::docker::params::quay_registry_secure},

    {url => $::platform::docker::params::docker_registry,
    secure => $::platform::docker::params::docker_registry_secure},

    {url => $::platform::docker::params::elastic_registry,
    secure => $::platform::docker::params::elastic_registry_secure},

    {url => $::platform::docker::params::ghcr_registry,
    secure => $::platform::docker::params::ghcr_registry_secure},

    {url => $::platform::docker::params::registryk8s_registry,
    secure => $::platform::docker::params::registryk8s_registry_secure},

    {url => $::platform::docker::params::icr_registry,
    secure => $::platform::docker::params::icr_registry_secure},
  ]

  $insecure_registries_list = $registries.filter |$registry| { $registry['secure'] == 'False' }
  $insecure_registries = unique(
    $insecure_registries_list.reduce([]) |$result, $registry| {
      $result + regsubst($registry['url'], '/.*', '')
    }
  )
}

class platform::dockerdistribution::config
  inherits ::platform::dockerdistribution::params {
  include ::platform::params
  include ::platform::kubernetes::params

  include ::platform::network::mgmt::params
  include ::platform::docker::params
  include ::platform::haproxy::params
  include ::platform::docker::daemonconfig

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

  if ($fqdn_ready == true) {
    $docker_registry_host = $::platform::params::controller_fqdn
  } else {
    $docker_registry_host = $::platform::network::mgmt::params::controller_address_url
  }

  if $::platform::params::distributed_cloud_role == 'subcloud' {
    $docker_realm_host = 'registry.local'
  } else {
    $docker_realm_host = $::platform::haproxy::params::public_address_url
  }
  $runtime_config = '/etc/docker-distribution/registry/runtime_config.yml'
  $used_config = '/etc/docker-distribution/registry/config.yml'
  $open_file_limit = 4096

  if $::osfamily == 'Debian' {
    $service_name = 'docker-registry.service'
  } else {
    $service_name = 'docker-distribution.service'
  }

  platform::dockerdistribution::write_config { 'runtime_config':
    docker_registry_host => $docker_registry_host,
    docker_realm_host    => $docker_realm_host,
  }

  -> exec { 'use runtime config file':
    command => "ln -fs ${runtime_config} ${used_config}",
  }

  platform::dockerdistribution::write_config { 'readonly_config':
    registry_readonly    => true,
    file_path            => '/etc/docker-distribution/registry/readonly_config.yml',
    docker_registry_host => $docker_registry_host,
    docker_realm_host    => $docker_realm_host,
  }

  file { '/etc/docker-distribution/registry/token_server.conf':
    ensure  => present,
    owner   => 'root',
    group   => 'root',
    mode    => '0644',
    content => template('platform/registry-token-server.conf.erb'),
  }

  # copy the startup script to where it is supposed to be
  file {'docker_distribution_initd_script':
    ensure => 'present',
    path   => '/etc/init.d/docker-distribution',
    mode   => '0755',
    source => "puppet:///modules/${module_name}/docker-distribution"
  }

  file {'registry_token_server_initd_script':
    ensure => 'present',
    path   => '/etc/init.d/registry-token-server',
    mode   => '0755',
    source => "puppet:///modules/${module_name}/registry-token-server"
  }

  if $::platform::params::system_type == 'All-in-one' and
    $::platform::params::distributed_cloud_role != 'systemcontroller' {
    $registry_token_server_max_procs = $::platform::params::eng_workers

    file { '/etc/systemd/system/registry-token-server.service.d':
      ensure => 'directory',
      owner  => 'root',
      group  => 'root',
      mode   => '0755',
    }
    -> file { '/etc/systemd/system/registry-token-server.service.d/registry-token-server-stx-override.conf':
      ensure  => file,
      content => template('platform/registry-token-server-stx-override.conf.erb'),
      owner   => 'root',
      group   => 'root',
      mode    => '0644',
    }
  }

  # override the configuration of docker-distribution.service
  file { "/etc/systemd/system/${service_name}.d":
    ensure => 'directory',
    owner  => 'root',
    group  => 'root',
    mode   => '0755',
  }
  -> file { "/etc/systemd/system/${service_name}.d/override.conf":
    ensure  => 'present',
    owner   => 'root',
    group   => 'root',
    mode    => '0644',
    content => template('platform/docker-distribution-override.conf.erb'),
  }

  if $::platform::params::system_type == 'All-in-one' and
    $::platform::params::distributed_cloud_role != 'systemcontroller' {
    $docker_registry_max_procs = $::platform::params::eng_workers

    file { "/etc/systemd/system/${service_name}.d/docker-distribution-stx-override.conf":
      ensure  => file,
      content => template('platform/docker-distribution-stx-override.conf.erb'),
      owner   => 'root',
      group   => 'root',
      mode    => '0644',
    }
  }
}

# compute also needs the "insecure" flag in order to deploy images from
# the registry. This is needed for insecure external registry
class platform::dockerdistribution::compute
  inherits ::platform::dockerdistribution::params {
  include ::platform::kubernetes::params

  include ::platform::docker::daemonconfig

  if $::personality != 'controller' {
    # it is for worker node only, since controller node already has ca cert in ssl folder.

    # containerd requires ca file to access local secure registry
    # For self signed cert, ca file is itself.
    # cert_file and key_file are not needed when TLS mutual authentication is unused.
    $shared_dir = $::platform::params::config_path
    $certs_dir = '/etc/ssl/private'
    file { $certs_dir:
      ensure => 'directory',
      owner  => 'root',
      group  => 'root',
      mode   => '0700',
    }
    -> file { "${certs_dir}/registry-cert.crt":
      ensure => 'file',
      owner  => 'root',
      group  => 'root',
      mode   => '0400',
      source => "${shared_dir}/registry-cert.crt",
    }
  }
}

class platform::dockerdistribution
  inherits ::platform::dockerdistribution::params {
  include ::platform::kubernetes::params

  include platform::dockerdistribution::config

  include ::platform::docker::haproxy

  Class['::platform::docker::config'] -> Class[$name]
}

class platform::dockerdistribution::reload {
  platform::sm::restart {'registry-token-server': }
  platform::sm::restart {'docker-distribution': }
}

# this does not update the config right now
# the run time is only used to restart the token server and registry
class platform::dockerdistribution::runtime {

  class {'::platform::dockerdistribution::reload':
    stage => post
  }
}

class platform::dockerdistribution::garbagecollect {
  $runtime_config = '/etc/docker-distribution/registry/runtime_config.yml'
  $readonly_config = '/etc/docker-distribution/registry/readonly_config.yml'
  $used_config = '/etc/docker-distribution/registry/config.yml'
  $registry_cmd = $::osfamily ? { 'Debian' => 'docker-registry', default => 'registry' }

  exec { 'turn registry read only':
    command => "ln -fs ${readonly_config} ${used_config}",
  }

  # it doesn't like 2 platform::sm::restart with the same name
  # so we have to do 1 as a command
  -> exec { 'restart docker-distribution in read only':
    command => 'sm-restart-safe service docker-distribution',
  }

  -> exec { 'run garbage collect':
    command => "/usr/bin/${registry_cmd} garbage-collect ${used_config}",
  }

  -> exec { 'turn registry back to read write':
    command => "ln -fs ${runtime_config} ${used_config}",
  }

  -> platform::sm::restart {'docker-distribution': }
}

class platform::dockerdistribution::bootstrap
  inherits ::platform::dockerdistribution::params {

  include platform::dockerdistribution::config
  Class['::platform::docker::config'] -> Class[$name]
}

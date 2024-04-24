class platform::docker::params (
  $package_name = $::osfamily ? {
    'Debian' => 'docker.io',
    default => 'docker-ce',
  },
  $http_proxy                  = undef,
  $https_proxy                 = undef,
  $no_proxy                    = undef,
  $registry_port               = undef,
  $token_port                  = undef,
  $k8s_registry                = undef,
  $gcr_registry                = undef,
  $quay_registry               = undef,
  $docker_registry             = undef,
  $elastic_registry            = undef,
  $ghcr_registry               = undef,
  $registryk8s_registry        = undef,
  $icr_registry                = undef,
  $k8s_registry_secure         = true,
  $quay_registry_secure        = true,
  $gcr_registry_secure         = true,
  $docker_registry_secure      = true,
  $elastic_registry_secure     = true,
  $ghcr_registry_secure        = true,
  $registryk8s_registry_secure = true,
  $icr_registry_secure         = true,
) {

  include ::platform::network::oam::params
  include ::platform::network::mgmt::params
  include ::platform::network::cluster_host::params
  include ::platform::kubernetes::params

  if $::platform::network::mgmt::params::subnet_version == $::platform::params::ipv6 {
    $localhost_address = '::1'
  } else {
    $localhost_address = '127.0.0.1'
  }

  if $::platform::params::system_mode == 'simplex' {
    $no_proxy_unfiltered_list = @("EOL"/L)
      localhost,${localhost_address},registry.local,\
      ${platform::network::oam::params::gateway_address},\
      ${platform::network::oam::params::controller_address},\
      ${platform::network::oam::params::controller0_address},\
      ${platform::network::mgmt::params::gateway_address},\
      ${platform::network::mgmt::params::controller_address},\
      ${platform::network::mgmt::params::controller0_address},\
      ${platform::network::cluster_host::params::gateway_address},\
      ${platform::network::cluster_host::params::controller_address},\
      ${platform::network::cluster_host::params::controller0_address},\
      ${platform::kubernetes::params::apiserver_cluster_ip},\
      ${platform::kubernetes::params::dns_service_ip},\
      cluster.local,${no_proxy}
      | -EOL
  } else {
    $no_proxy_unfiltered_list = @("EOL"/L)
      localhost,${localhost_address},registry.local,\
      ${platform::network::oam::params::gateway_address},\
      ${platform::network::oam::params::controller_address},\
      ${platform::network::oam::params::controller0_address},\
      ${platform::network::oam::params::controller1_address},\
      ${platform::network::mgmt::params::gateway_address},\
      ${platform::network::mgmt::params::controller_address},\
      ${platform::network::mgmt::params::controller0_address},\
      ${platform::network::mgmt::params::controller1_address},\
      ${platform::network::cluster_host::params::gateway_address},\
      ${platform::network::cluster_host::params::controller_address},\
      ${platform::network::cluster_host::params::controller0_address},\
      ${platform::network::cluster_host::params::controller1_address},\
      ${platform::kubernetes::params::apiserver_cluster_ip},\
      ${platform::kubernetes::params::dns_service_ip},\
      cluster.local,${no_proxy}
      | -EOL
  }

  # Remove duplicates.
  $no_proxy_complete_list = split($no_proxy_unfiltered_list, ',').unique.join(',')
}

class platform::docker::proxyconfig
  inherits ::platform::docker::params {
  include ::platform::docker::install

  # Docker on Debian doesn't work with the NO_PROXY environment variable if it
  # has IPv6 addresses with square brackets, thus remove the square brackets
  $no_proxy = regsubst($::platform::docker::params::no_proxy_complete_list, '\\[|\\]', '', 'G')

  if $http_proxy or $https_proxy {
    file { '/etc/systemd/system/docker.service.d':
      ensure => 'directory',
      owner  => 'root',
      group  => 'root',
      mode   => '0755',
    }
    -> file { '/etc/systemd/system/docker.service.d/http-proxy.conf':
      ensure  => present,
      owner   => 'root',
      group   => 'root',
      mode    => '0644',
      content => template('platform/dockerproxy.conf.erb'),
    }
    ~> exec { 'perform systemctl daemon reload for docker proxy':
      command     => 'systemctl daemon-reload',
      logoutput   => true,
      refreshonly => true,
    } ~> Service['docker']
  } else {
    file { '/etc/systemd/system/docker.service.d/http-proxy.conf':
      ensure  => absent,
    }
    ~> exec { 'perform systemctl daemon reload for docker proxy':
      command     => 'systemctl daemon-reload',
      logoutput   => true,
      refreshonly => true,
    } ~> Service['docker']
  }

  service { 'docker':
    ensure  => 'running',
    name    => 'docker',
    enable  => true,
    require => [
      Package['docker'],
      Mount['docker-lv'],
    ],
  }
}

class platform::docker::config
  inherits ::platform::docker::params {

  include ::platform::docker::proxyconfig

  # Docker restarts will trigger a containerd restart and containerd needs a
  # default route present for it's CRI plugin to load correctly. Since we are
  # defering containerd restart until after the network config is applied, do
  # the same here to align config/restart times for both containerd and docker.
  Anchor['platform::networking'] -> Class[$name]

  Class['::platform::filesystem::docker'] -> Class[$name]

  Service['docker']
  -> exec { 'enable-docker':
    command => '/usr/bin/systemctl enable docker.service',
  }
}

class platform::docker::install
  inherits ::platform::docker::params {

  package { 'docker':
    ensure => 'installed',
    name   => $package_name,
  }
}

class platform::docker::controller
{
  include ::platform::docker::install
  include ::platform::docker::config
}

class platform::docker::worker
{
  if $::personality != 'controller' {
    include ::platform::docker::install
    include ::platform::docker::config
  }
}

class platform::docker::storage
{
  if $::personality != 'controller' {
    include ::platform::docker::install
    include ::platform::docker::config
  }
}

class platform::docker::config::bootstrap
  inherits ::platform::docker::params {

  require ::platform::filesystem::docker

  Class['::platform::filesystem::docker'] ~> Class[$name]

  service { 'docker':
    ensure  => 'running',
    name    => 'docker',
    enable  => true,
    require => [
      Package['docker'],
      Mount['docker-lv'],
    ],
  }
  -> exec { 'enable-docker':
    command => '/usr/bin/systemctl enable docker.service',
  }
}

class platform::docker::bootstrap
{
  include ::platform::docker::install
  include ::platform::docker::config::bootstrap
}

class platform::docker::haproxy
  inherits ::platform::docker::params {

  platform::haproxy::proxy { 'docker-registry':
    server_name       => 's-docker-registry',
    public_port       => $registry_port,
    private_port      => $registry_port,
    x_forwarded_proto => false,
    mode_option       => 'tcp',
  }

  platform::haproxy::proxy { 'docker-token':
    server_name       => 's-docker-token',
    public_port       => $token_port,
    private_port      => $token_port,
    x_forwarded_proto => false,
    mode_option       => 'tcp',
  }
}

class platform::docker::runtime
{
  include ::platform::docker::proxyconfig
  include ::platform::containerd::proxyconfig

  if str2bool($::is_initial_config) {
    $containerd_restart_cmd = 'systemctl restart containerd'
    $dockerd_restart_cmd = 'systemctl restart docker'
  }
  else {
    $containerd_restart_cmd = 'pmon-restart containerd'
    $dockerd_restart_cmd = 'pmon-restart dockerd'
  }

  # Restart containerd.
  exec { 'restart containerd for proxy changes':
    command     => $containerd_restart_cmd,
  }
  # Restart docker.
  -> exec { 'restart docker for proxy changes':
    command     => $dockerd_restart_cmd,
  }
}

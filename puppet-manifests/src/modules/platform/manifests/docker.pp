class platform::docker::params (
  $package_name = 'docker-ce',
  $http_proxy   = undef,
  $https_proxy  = undef,
  $no_proxy     = undef,
  $registry_port        = '9001',
  $token_port           = '9002',
  $k8s_registry     = undef,
  $gcr_registry     = undef,
  $quay_registry    = undef,
  $docker_registry  = undef,
  $elastic_registry = undef,
  $ghcr_registry = undef,
  $k8s_registry_secure     = true,
  $quay_registry_secure    = true,
  $gcr_registry_secure     = true,
  $docker_registry_secure  = true,
  $elastic_registry_secure = true,
  $ghcr_registry_secure = true,
) { }

class platform::docker::proxyconfig
  inherits ::platform::docker::params {
  include ::platform::docker::install

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
  }

  service { 'docker':
    ensure  => 'running',
    name    => 'docker',
    enable  => true,
    require => Package['docker']
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

  Class['::platform::filesystem::docker'] ~> Class[$name]

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

  require ::platform::filesystem::docker::bootstrap

  Class['::platform::filesystem::docker::bootstrap'] ~> Class[$name]

  service { 'docker':
    ensure  => 'running',
    name    => 'docker',
    enable  => true,
    require => Package['docker']
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
    tcp_mode          => true,
  }

  platform::haproxy::proxy { 'docker-token':
    server_name       => 's-docker-token',
    public_port       => $token_port,
    private_port      => $token_port,
    x_forwarded_proto => false,
    tcp_mode          => true,
  }
}

class platform::docker::runtime
{
  include ::platform::docker::proxyconfig
  include ::platform::containerd::proxyconfig

  if str2bool($::is_initial_config) {
    $containerd_restart_cmd = 'systemctl restart containerd'
  }
  else {
    $containerd_restart_cmd = 'pmon-restart containerd'
  }

  # Restart containerd also cause docker to restart.
  exec { 'restart containerd for proxy changes':
    command     => $containerd_restart_cmd,
  }
}

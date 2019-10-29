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
  $k8s_registry_secure     = true,
  $quay_registry_secure    = true,
  $gcr_registry_secure     = true,
  $docker_registry_secure  = true,
  $elastic_registry_secure = true,
) { }

class platform::docker::config
  inherits ::platform::docker::params {

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

  Class['::platform::filesystem::docker'] ~> Class[$name]

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

class platform::docker::install
  inherits ::platform::docker::params {

  package { 'docker':
    ensure => 'installed',
    name   => $package_name,
  }
}

class platform::docker
{
  include ::platform::docker::install
  include ::platform::docker::config
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

class platform::containerd::params (
  $package_name = 'containerd',
  $http_proxy   = undef,
  $https_proxy  = undef,
  $no_proxy     = undef,
  $k8s_registry    = undef,
  $insecure_registries = undef,
  $k8s_cni_bin_dir = '/usr/libexec/cni'
) { }

class platform::containerd::config
  inherits ::platform::containerd::params {

  include ::platform::docker::params
  include ::platform::dockerdistribution::params
  include ::platform::kubernetes::params
  include ::platform::dockerdistribution::registries

  # inherit the proxy setting from docker
  $http_proxy = $::platform::docker::params::http_proxy
  $https_proxy = $::platform::docker::params::https_proxy
  $no_proxy = $::platform::docker::params::no_proxy
  $insecure_registries = $::platform::dockerdistribution::registries::insecure_registries

  if $http_proxy or $https_proxy {
    file { '/etc/systemd/system/containerd.service.d':
      ensure => 'directory',
      owner  => 'root',
      group  => 'root',
      mode   => '0755',
    }
    -> file { '/etc/systemd/system/containerd.service.d/http-proxy.conf':
      ensure  => present,
      owner   => 'root',
      group   => 'root',
      mode    => '0644',
      # share the same template as docker, since the conf file is the same
      content => template('platform/dockerproxy.conf.erb'),
    }
    ~> exec { 'perform systemctl daemon reload for containerd proxy':
      command     => 'systemctl daemon-reload',
      logoutput   => true,
      refreshonly => true,
    } ~> Service['containerd']
  }

  Class['::platform::filesystem::docker'] ~> Class[$name]

  # get cni bin directory
  $k8s_cni_bin_dir = $::platform::kubernetes::params::k8s_cni_bin_dir

  file { '/etc/containerd':
    ensure => 'directory',
    owner  => 'root',
    group  => 'root',
    mode   => '0700',
  }
  -> file { '/etc/containerd/config.toml':
    ensure  => present,
    owner   => 'root',
    group   => 'root',
    mode    => '0600',
    content => template('platform/config.toml.erb'),
  }
  -> service { 'containerd':
    ensure  => 'running',
    name    => 'containerd',
    enable  => true,
    require => Package['containerd']
  }
  -> exec { 'enable-containerd':
    command => '/usr/bin/systemctl enable containerd.service',
  }
  -> exec { 'restart-containerd':
    # containerd may be already started by docker. Need restart it after configuration
    command => '/usr/bin/systemctl restart containerd.service',
  }
}

class platform::containerd::install
  inherits ::platform::containerd::params {

  package { 'containerd':
    ensure => 'installed',
    name   => $package_name,
  }
}

class platform::containerd
{
  include ::platform::containerd::install
  include ::platform::containerd::config
}

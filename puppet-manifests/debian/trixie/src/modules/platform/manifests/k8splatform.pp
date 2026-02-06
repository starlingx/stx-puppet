class platform::k8splatform::params (
  $slice                  = 'k8splatform.slice',
  $k8splatform_shares     = 1024,
  $etcd_shares            = 1024,
  $etcd_quota_scale       = '',
  $containerd_shares      = 1024,
  $containerd_quota_scale = 75,
  $kubelet_shares         = 1024,
  $kubelet_quota_scale    = 75,
) {

}

class platform::k8splatform
  inherits ::platform::k8splatform::params {

  include ::platform::k8splatform::config

  Class['::platform::k8splatform::config']
  -> exec { 'systemctl daemon reload for k8splatform':
    command     => 'systemctl daemon-reload',
    logoutput   => true,
    refreshonly => true,
  }
  -> exec { 'start-k8splatform':
    command => '/usr/bin/systemctl start k8splatform.slice',
  }
}

class platform::k8splatform::config
  inherits ::platform::k8splatform::params {

  $k8splatform_cpushares = $::platform::params::distributed_cloud_role ? {
    'systemcontroller' => 10240,
    default            => $platform::k8splatform::params::k8splatform_shares
  }

  file { '/etc/systemd/system/k8splatform.slice':
    ensure  => file,
    owner   => 'root',
    group   => 'root',
    mode    => '0644',
    content => template('platform/k8splatform.slice.erb'),
  }
}

class platform::k8splatform::bootstrap
  inherits ::platform::k8splatform::params {

  include ::platform::k8splatform::config

  Class['::platform::k8splatform::config']
  -> exec { 'start-k8splatform':
    command => '/usr/bin/systemctl start k8splatform.slice',
  }
}

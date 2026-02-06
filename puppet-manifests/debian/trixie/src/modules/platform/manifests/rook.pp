class platform::rook::params(
  $service_enabled = false,
  $node_rook_configured_flag = '/etc/platform/.node_rook_configured',
) { }

class platform::rook::post
  inherits ::platform::rook::params {

  if $service_enabled {
    # Ceph configuration on this node is done
    file { $node_rook_configured_flag:
      ensure => present
    }
  } else {
    # Remove the configuration file if service is not enabled
    file { $node_rook_configured_flag:
      ensure => absent
    }
  }
}

class platform::rook::base
  inherits ::platform::rook::params {

  if $service_enabled {
    include ::platform::filesystem::ceph::mountpoint
  }

  class { '::platform::rook::post':
    stage => post
  }
}

class platform::rook {
  include ::platform::rook::base
}

class platform::rook::runtime {
  include ::platform::rook::base
}

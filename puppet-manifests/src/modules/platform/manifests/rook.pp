class platform::rook::params(
  $service_enabled = false,
  $node_rook_configured_flag = '/etc/platform/.node_rook_configured',
) { }


define platform::rook::mapping {
  exec { 'enable volume group device mapper mapping':
    command => "vgchange -ay ${name} || true",
    onlyif  => "test ! -d /dev/${name}",
  }
}


define platform::rook::directory(
  $disk_node,
  $data_path,
  $directory,
) {
  exec { "mount ${disk_node}":
    unless  => "mount | grep -q ${disk_node}",
    command => "mount ${data_path} ${directory} || true",
  }
}

class platform::rook::directories(
  $dir_config = {},
) inherits ::platform::rook::params {

  create_resources('platform::rook::directory', $dir_config)
}

class platform::rook::vg::rook_vg(
  $vg_name = [],
) inherits platform::rook::params {
  ::platform::rook::mapping { $vg_name:
  }
}

class platform::rook::storage {
    include ::platform::rook::directories
    include ::platform::rook::vg::rook_vg
}

class platform::rook::post
  inherits ::platform::rook::params {

  if $service_enabled {
    # Ceph configuration on this node is done
    file { $node_rook_configured_flag:
      ensure => present
    }
  }
}

class platform::rook::base
  inherits ::platform::rook::params {

  $system_mode = $::platform::params::system_mode
  $system_type = $::platform::params::system_type

  if $service_enabled {
    include ::platform::filesystem::ceph::mountpoint

    if $system_type == 'All-in-one' and 'duplex' in $system_mode {
      File['/var/lib/ceph'] -> Drbd::Resource <| |> -> Class[$name]
    }

    class { '::platform::rook::post':
      stage => post
    }
  }
}

class platform::rook {
  include ::platform::rook::storage
  include ::platform::rook::base
}

class platform::rook::runtime {

  include ::platform::rook::base
}

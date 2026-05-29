class platform::lvm::params (
  $transition_filter = '[]',
  $final_filter = '[]',
  $cgts_thin_pool_enabled = false,
  $cgts_thin_pool_size = '',
  $removing_lvgs = [],
  $csi_service_enabled = false,
  $node_lvm_csi_configured_flag = '/etc/platform/.node_lvm_csi_configured',
) {}


class platform::lvm
  inherits platform::lvm::params {
}


define platform::lvm::global_filter($filter) {
  file_line { "${name}: update lvm global_filter":
    path  => '/etc/lvm/lvm.conf',
    line  => "    global_filter = ${filter}",
    match => '^[\s]*#? global_filter =',
  }
}


define platform::lvm::umount {
  exec { "umount disk ${name}":
    command => "umount ${name}; true",
  }
}


class platform::lvm::vg::cgts_vg(
  $vg_name = 'cgts-vg',
  $physical_volumes = [],
) inherits platform::lvm::params {

  ::platform::lvm::umount { $physical_volumes:
  }
  -> physical_volume { $physical_volumes:
    ensure => present,
  }
  -> volume_group { $vg_name:
    ensure           => present,
    physical_volumes => $physical_volumes,
  }

  include ::platform::lvm::vg::cgts_vg::thinpool
}

class platform::lvm::vg::cgts_vg::thinpool(
  $vg_name = 'cgts-vg',
) inherits platform::lvm::params {

  if $cgts_thin_pool_enabled {
    $ensure_value = 'present'
  } else {
    $ensure_value = 'absent'
  }

  platform::lvm::csi::create_thinpool { 'lvmcsi-pool':
    ensure    => $ensure_value,
    vg_name   => $vg_name,
    pool_size => $cgts_thin_pool_size
  }
}

class platform::lvm::vg::cgts_vg::resizing::runtime (
  $vg_name = 'cgts-vg',
  $pool_name = 'lvmcsi-pool',
)
  inherits ::platform::lvm::params {

  exec { "resizing thin pool ${pool_name}":
    command => "lvresize -L ${cgts_thin_pool_size}G ${vg_name}/${pool_name}",
    path    => ['/usr/sbin', '/sbin'],
    onlyif  => "lvs ${vg_name}/${pool_name}",
  }
}


class platform::lvm::vg::cgts_vg::thinpool::runtime {
  include ::platform::lvm::vg::cgts_vg::thinpool
}

class platform::lvm::vg::nova_local(
  $vg_name = 'nova-local',
  $physical_volumes = [],
) inherits platform::lvm::params {
  # TODO(rchurch): refactor portions of platform::worker::storage and move here
}

##################
# Controller Hosts
##################

class platform::lvm::controller::vgs {
  include ::platform::lvm::vg::cgts_vg
  include ::platform::lvm::vg::nova_local
}

class platform::lvm::controller
  inherits ::platform::lvm::params {

  ::platform::lvm::global_filter { 'transition filter controller':
    filter => $transition_filter,
    before => Class['::platform::lvm::controller::vgs']
  }

  ::platform::lvm::global_filter { 'final filter controller':
    filter  => $final_filter,
    require => Class['::platform::lvm::controller::vgs']
  }

  include ::platform::lvm
  include ::platform::lvm::controller::vgs
}


class platform::lvm::controller::runtime {
  include ::platform::lvm::controller
}

###############
# Compute Hosts
###############

class platform::lvm::compute::vgs {
  include ::platform::lvm::vg::cgts_vg
  include ::platform::lvm::vg::nova_local
}

class platform::lvm::compute
  inherits ::platform::lvm::params {

  ::platform::lvm::global_filter { 'transition filter compute':
    filter => $transition_filter,
    before => Class['::platform::lvm::compute::vgs']
  }

  ::platform::lvm::global_filter { 'final filter compute':
    filter  => $final_filter,
    require => Class['::platform::lvm::compute::vgs']
  }

  include ::platform::lvm
  include ::platform::lvm::compute::vgs
}


class platform::lvm::compute::runtime {
  include ::platform::lvm::compute
}

###############
# AIO
###############

class platform::lvm::aio
  inherits ::platform::lvm::params {
    include ::platform::lvm::controller
    include ::platform::lvm::compute
    Class['::platform::lvm::controller']
    -> Class['::platform::lvm::compute']
    -> Class['::platform::worker::storage']
}


###############
# Storage Hosts
###############

class platform::lvm::storage::vgs {
  include ::platform::lvm::vg::cgts_vg
}

class platform::lvm::storage
  inherits ::platform::lvm::params {

  ::platform::lvm::global_filter { 'final filter':
    filter => $final_filter,
    before => Class['::platform::lvm::storage::vgs']
  }

  include ::platform::lvm
  include ::platform::lvm::storage::vgs
}


class platform::lvm::storage::runtime {
  include ::platform::lvm::storage
}

define platform::lvm::csi::create_thinpool(
  $vg_name,
  $pool_size,
  $pool_name = $title,
  $metadata_size = undef,
  $ensure = present,
) {

  if $ensure == 'present' {

    $metadata_param = $metadata_size ? {
      undef   => '',
      ''      => '',
      default => "--poolmetadatasize ${metadata_size}",
    }
    # lint:ignore:only_variable_string
    if "${pool_size}" =~ /%/ {
      $npool_size = "-l ${pool_size}"
    } else {
      $npool_size = "-L ${pool_size}G"
    }
    # lint:endignore:only_variable_string

    # If the ThinPool exists, its a PV addition operation, so, we need to
    # extend it size, otherwise, create the thinpool.
    exec { "resizing thin pool ${pool_name}":
      command => "lvresize ${npool_size} ${vg_name}/${pool_name}",
      path    => ['/usr/sbin', '/sbin'],
      onlyif  => "lvs ${vg_name}/${pool_name}",
    }
    exec { "create thin pool ${pool_name}":
      command => "lvcreate -T ${npool_size} ${metadata_param} ${vg_name}/${pool_name}",
      path    => ['/usr/sbin', '/sbin'],
      unless  => "lvs ${vg_name}/${pool_name}",
      onlyif  => "vgs ${vg_name}",
    }

  } elsif $ensure == 'absent' {
    exec { "remove thin pool ${pool_name}":
      command => "lvremove -f ${vg_name}/${pool_name}",
      path    => ['/usr/sbin', '/sbin'],
      onlyif  => "lvs ${vg_name}/${pool_name}",
    }
  }
}

define platform::lvm::csi::wipe_and_add_pv {
  notice("Adding PV ${name}")
  exec { "notice: wipe start of device ${name}":
    command => "wipefs -af ${name}",
    path    => ['/usr/sbin', '/sbin', '/usr/bin', '/bin'],
    unless  => "pvdisplay ${name}",
  }
  -> exec { "pvcreate ${name}":
    command => "pvcreate -y ${name}",
    path    => ['/usr/sbin', '/sbin'],
    unless  => "pvdisplay ${name}",
  }
}

class platform::lvm::csi::params::thick (
  $vg_name = '',
  $physical_volumes = [],
) {}

class platform::lvm::csi::thick::resources
  inherits ::platform::lvm::csi::params::thick {

    if $vg_name != '' {
      platform::lvm::csi::wipe_and_add_pv { $physical_volumes:
      }
      -> volume_group { $vg_name:
        ensure           => present,
        physical_volumes => $physical_volumes,
      }
    }
}

class platform::lvm::csi::thick::runtime
  inherits ::platform::lvm::params {
    ::platform::lvm::global_filter { 'final filter':
      filter => $final_filter,
      before => Class['::platform::lvm::csi::thick::resources']
    }

    include ::platform::lvm::csi::thick::resources
}

class platform::lvm::csi::params::thin (
  $vg_name = '',
  $physical_volumes = [],
  $pool_name = 'lvmcsi-pool',
  $pool_size = '+99%FREE',
  $metadata_size = undef,
) {}

class platform::lvm::csi::thin::resources
  inherits ::platform::lvm::csi::params::thin {

    if $vg_name != '' {
      platform::lvm::csi::wipe_and_add_pv { $physical_volumes:
      }
      -> volume_group { $vg_name:
        ensure           => present,
        physical_volumes => $physical_volumes,
      }
      -> platform::lvm::csi::create_thinpool { $pool_name:
        ensure        => present,
        vg_name       => $vg_name,
        pool_size     => $pool_size,
        metadata_size => $metadata_size,
      }
    }
}

class platform::lvm::csi::thin::runtime
  inherits ::platform::lvm::params {

  ::platform::lvm::global_filter { 'final filter':
    filter => $final_filter,
    before => Class['::platform::lvm::csi::thin::resources']
  }

  include ::platform::lvm::csi::thin::resources
}

define platform::lvm::csi::remove_vg {
  exec { "vgremove ${name}":
    command => "vgremove -fy ${name}",
    path    => ['/usr/sbin', '/sbin'],
    onlyif  => "vgs ${name}",
  }
}

class platform::lvm::csi::remove_pv::runtime (
  $removing_pvs = lookup('platform::worker::storage::removing_pvs', Array, 'first', []),
) {
  include ::platform::lvm::params
  notice("Removing VG ${$::platform::lvm::params::removing_lvgs}")
  notice("Removing PV ${$removing_pvs}")
  platform::lvm::csi::remove_vg { $::platform::lvm::params::removing_lvgs:
  }
  -> physical_volume { $removing_pvs:
    ensure => absent,
  }
}

class platform::lvm::csi::flag
  inherits ::platform::lvm::params {

  if $csi_service_enabled {
    $ensure_value = 'present'
  } else {
    $ensure_value = 'absent'
  }

  file { $node_lvm_csi_configured_flag:
    ensure  => $ensure_value,
    content => '',
    owner   => 'root',
    group   => 'root',
    mode    => '0640',
  }

}

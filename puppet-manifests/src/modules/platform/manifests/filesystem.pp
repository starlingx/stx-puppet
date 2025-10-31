class platform::filesystem::params (
  $vg_name = 'cgts-vg',
) {}


define platform::filesystem (
  $lv_name,
  $lv_size,
  $mountpoint,
  $fs_type,
  $fs_options,
  $fs_use_all = false,
  $ensure = present,
  $group = 'root',
  $mode = '0750',
  $ensure_mount = 'mounted',
) {
  include ::platform::filesystem::params
  $vg_name = $::platform::filesystem::params::vg_name

  $device = "/dev/${vg_name}/${lv_name}"

  if !$fs_use_all {
    $size = "${lv_size}G"
    $fs_size_is_minsize = true
  }
  else {
    # use all available space
    $size = undef
    $fs_size_is_minsize = false
  }

  if ($ensure == 'absent') {
    mount { $name:
      ensure  => $ensure,
      atboot  => 'yes',
      name    => $mountpoint,
      device  => $device,
      options => 'defaults',
      fstype  => $fs_type,
    }
    -> file { $mountpoint:
      ensure => $ensure,
      force  => true,
    }
    -> exec { "removing: wipe start of device ${device}":
      command => "dd if=/dev/zero of=${device} bs=512 count=34",
      onlyif  => "blkid ${device}",
    }
    -> exec { "removing: wipe end of device ${device}":
      command => "dd if=/dev/zero of=${device} bs=512 seek=$(($(blockdev --getsz ${device}) - 34)) count=34",
      onlyif  => "blkid ${device}",
    }
    -> exec { "lvremove lv ${lv_name}":
      command => "lvremove -f cgts-vg/${lv_name}; true",
      onlyif  => "test -e /dev/cgts-vg/${lv_name}"
    }
  }

  if ($ensure == 'present') {
    # A filesystem previously mounted, for example the scratch fs, needs to be unmounted
    # before cleaning, otherwise the make filesystem command and/or dd command will fail.
    exec { "umount mountpoint ${mountpoint} before cleaning":
      command => "umount ${mountpoint}; true",
      onlyif  => "test -e ${mountpoint}",
    }

    # create logical volume
    -> logical_volume { $lv_name:
        ensure          => $ensure,
        volume_group    => $vg_name,
        size            => $size,
        size_is_minsize => $fs_size_is_minsize,
    }
    # Wipe 10MB at the beginning and at the end
    # of each LV in cgts-vg to prevent problems caused
    # by stale data on the disk
    -> exec { "creating: wipe start of device ${device}":
      command => "dd if=/dev/zero of=${device} bs=1M count=10",
      onlyif  => "test ! -e /etc/platform/.${lv_name}"
    }
    -> exec { "creating: wipe end of device ${device}":
      command => "dd if=/dev/zero of=${device} bs=1M seek=$(($(blockdev --getsz ${device})/2048 - 10)) count=10",
      onlyif  => "test ! -e /etc/platform/.${lv_name}"
    }
    -> exec { "mark lv as wiped ${lv_name}:":
      command => "touch /etc/platform/.${lv_name}",
      onlyif  => "test ! -e /etc/platform/.${lv_name}"
    }
    # create filesystem
    -> filesystem { $device:
      ensure  => $ensure,
      fs_type => $fs_type,
      options => $fs_options,
    }

    -> file { $mountpoint:
      ensure => 'directory',
      owner  => 'root',
      group  => $group,
      mode   => $mode,
    }

    # The mount resource below will try to remount devices that were already
    # present in /etc/fstab but were unmounted during manifest application,
    # but will fail if the device is not mounted. So, it will try to mount them
    # in this step if they are not mounted, tolerating failure if they aren't
    # in fstab yet, as they will be added to it and mounted in the following
    # mount resource
    -> exec { "mount ${device}":
      unless  => "mount | awk '{print \$3}' | grep -Fxq ${mountpoint}",
      command => "mount ${mountpoint} || true",
      path    => '/usr/bin',
    }

    -> mount { $name:
      ensure  => $ensure_mount,
      atboot  => 'yes',
      name    => $mountpoint,
      device  => $device,
      options => 'defaults',
      fstype  => $fs_type,
    }

    -> exec {"Change ${mountpoint} dir permissions":
      command => "chmod ${mode} ${mountpoint}",
    }
    -> exec {"Change ${mountpoint} dir group":
      command => "chgrp ${group} ${mountpoint}",
    }
  }
}


define platform::filesystem::resize(
  $lv_name,
  $lv_size,
  $devmapper,
) {
  include ::platform::filesystem::params
  $vg_name = $::platform::filesystem::params::vg_name

  $device = "/dev/${vg_name}/${lv_name}"

  # TODO (rchurch): Fix this... Allowing return code 5 so that lvextends using the same size doesn't blow up
  exec { "lvextend ${device}":
    command => "lvextend -L${lv_size}G ${device}",
    returns => [0, 5]
  }
  # After a partition extend, wipe 10MB at the end of the partition
  # to make sure that there is no leftover
  # type metadata from a previous install
  -> exec { "resizing: wipe end of device ${device}":
    command => "dd if=/dev/zero of=${device} bs=1M seek=$(($(blockdev --getsz ${device})/2048 - 10)) count=10",
    onlyif  => "blkid -s TYPE -o value ${devmapper} | grep -v xfs",
  }
  -> exec { "resize2fs ${devmapper}":
    command => "resize2fs ${devmapper}",
    onlyif  => "blkid -s TYPE -o value ${devmapper} | grep -v xfs",
  }
  -> exec { "xfs_growfs ${devmapper}":
    command => "xfs_growfs ${devmapper}",
    onlyif  => "blkid -s TYPE -o value ${devmapper} | grep xfs",
  }
}


class platform::filesystem::backup::params (
  $lv_name = 'backup-lv',
  $lv_size = '1',
  $mountpoint = $::osfamily ? { 'Debian' => '/var/rootdirs/opt/backups', default => '/opt/backups' },
  $devmapper = '/dev/mapper/cgts--vg-backup--lv',
  $fs_type = 'ext4',
  $fs_options = ' '
) {}

class platform::filesystem::backup
  inherits ::platform::filesystem::backup::params {

  platform::filesystem { $lv_name:
    lv_name    => $lv_name,
    lv_size    => $lv_size,
    mountpoint => $mountpoint,
    fs_type    => $fs_type,
    fs_options => $fs_options
  }
}

class platform::filesystem::scratch::params (
  $lv_size = '2',
  $lv_name = 'scratch-lv',
  $mountpoint = $::osfamily ? {
    'Debian' => '/var/rootdirs/scratch',
    default => '/scratch',
  },
  $devmapper = '/dev/mapper/cgts--vg-scratch--lv',
  $fs_type = 'ext4',
  $fs_options = ' ',
  $group = 'sys_protected',
  $mode = '0770',
  $ensure_mount = 'present',
) { }

class platform::filesystem::scratch
  inherits ::platform::filesystem::scratch::params {

  platform::filesystem { $lv_name:
    lv_name      => $lv_name,
    lv_size      => $lv_size,
    mountpoint   => $mountpoint,
    fs_type      => $fs_type,
    fs_options   => $fs_options,
    group        => $group,
    mode         => $mode,
    ensure_mount => $ensure_mount,
  }
}

class platform::filesystem::conversion::params (
  $conversion_enabled = false,
  $ensure = absent,
  $lv_size = '1',
  $lv_name = 'conversion-lv',
  $mountpoint = $::osfamily ? { 'Debian' => '/var/rootdirs/opt/conversion', default => '/opt/conversion' },
  $devmapper = '/dev/mapper/cgts--vg-conversion--lv',
  $fs_type = 'ext4',
  $fs_options = ' ',
  $mode = '0750'
) { }

class platform::filesystem::conversion
  inherits ::platform::filesystem::conversion::params {

  if $conversion_enabled {
    $ensure = present
    $mode = '0777'
  }
  platform::filesystem { $lv_name:
    ensure     => $ensure,
    lv_name    => $lv_name,
    lv_size    => $lv_size,
    mountpoint => $mountpoint,
    fs_type    => $fs_type,
    fs_options => $fs_options,
    mode       => $mode
  }
}

class platform::filesystem::instances::mountpoint {
  file { '/var/lib/nova':
    ensure => 'directory',
    owner  => 'root',
    group  => 'root',
    mode   => '0755',
  }
}

class platform::filesystem::instances::params (
  $instances_enabled = false,
  $ensure = absent,
  $lv_size = '1',
  $lv_name = 'instances-lv',
  $mountpoint = '/var/lib/nova/instances',
  $devmapper = '/dev/mapper/cgts--vg-instances--lv',
  $fs_type = 'ext4',
  $fs_options = ' ',
  $mode = '0750',
) { }

class platform::filesystem::instances
  inherits ::platform::filesystem::instances::params {
  include ::platform::filesystem::instances::mountpoint

  if $instances_enabled {
    $ensure = present
    $mode = '0777'
  }

  Class['::platform::filesystem::instances::mountpoint']
  -> platform::filesystem { $lv_name:
    ensure     => $ensure,
    lv_name    => $lv_name,
    lv_size    => $lv_size,
    mountpoint => $mountpoint,
    fs_type    => $fs_type,
    fs_options => $fs_options,
    mode       => $mode
  }
}

class platform::filesystem::kubelet::params (
  $lv_size = '2',
  $lv_name = 'kubelet-lv',
  $mountpoint = '/var/lib/kubelet',
  $devmapper = '/dev/mapper/cgts--vg-kubelet--lv',
  $fs_type = 'ext4',
  $fs_options = ' '
) { }

class platform::filesystem::kubelet
  inherits ::platform::filesystem::kubelet::params {

  platform::filesystem { $lv_name:
    lv_name    => $lv_name,
    lv_size    => $lv_size,
    mountpoint => $mountpoint,
    fs_type    => $fs_type,
    fs_options => $fs_options
  }
}

class platform::filesystem::docker::params (
  $lv_size = '20',
  $lv_name = 'docker-lv',
  $mountpoint = '/var/lib/docker',
  $devmapper = '/dev/mapper/cgts--vg-docker--lv',
  $fs_type = 'xfs',
  $fs_options = '-n ftype=1',
  $fs_use_all = false
) { }

class platform::filesystem::docker
  inherits ::platform::filesystem::docker::params {

  platform::filesystem { $lv_name:
    lv_name    => $lv_name,
    lv_size    => $lv_size,
    mountpoint => $mountpoint,
    fs_type    => $fs_type,
    fs_options => $fs_options,
    fs_use_all => $fs_use_all,
    mode       => '0711',
  }

  $docker_overrides = '/etc/systemd/system/docker.service.d/docker-stx-override.conf'
  file_line { "${docker_overrides}: add unit section":
    path => $docker_overrides,
    line => '[Unit]',
  }
  -> file_line { "${docker_overrides}: add mount After dependency":
    path => $docker_overrides,
    line => 'After=var-lib-docker.mount',
  }
  -> file_line { "${docker_overrides}: add mount Requires dependency":
    path => $docker_overrides,
    line => 'Requires=var-lib-docker.mount',
  }
  -> exec { 'perform systemctl daemon reload for docker override':
    command   => 'systemctl daemon-reload',
    logoutput => true,
  }
}

class platform::filesystem::storage {
  include ::platform::filesystem::scratch
  include ::platform::filesystem::kubelet

  class {'platform::filesystem::docker::params' :
    lv_size => 30
  }
  -> class {'platform::filesystem::docker' :
  }

  Class['::platform::lvm::vg::cgts_vg'] -> Class[$name]
}


class platform::filesystem::compute {
  if $::personality == 'worker' {
    include ::platform::filesystem::instances
    include ::platform::filesystem::ceph
    include ::platform::filesystem::scratch

    # The default docker size for controller is 20G
    # other than 30G. To prevent the docker size to
    # be overrided to 30G for AIO, this is scoped to
    # worker node.
    include ::platform::filesystem::kubelet
    class {'platform::filesystem::docker::params' :
      lv_size => 30
    }
    -> class {'platform::filesystem::docker' :
    }
}

  Class['::platform::lvm::vg::cgts_vg'] -> Class[$name]
}

class platform::filesystem::controller {
  include ::platform::filesystem::backup
  include ::platform::filesystem::scratch
  include ::platform::filesystem::conversion
  include ::platform::filesystem::instances
  include ::platform::filesystem::docker
  include ::platform::filesystem::kubelet
  include ::platform::filesystem::log_bind
  include ::platform::filesystem::luks
  include ::platform::filesystem::ceph
}

class platform::filesystem::log_bind {
  file {'/var/lib/systemd/coredump/':
    ensure  => directory,
  }
  -> file {'/var/log/coredump/':
    ensure  => directory,
  }
  -> mount { '/var/lib/systemd/coredump':
    ensure  => mounted,
    device  => '/var/log/coredump',
    fstype  => 'none',
    options => 'rw,bind',
  }
}


class platform::filesystem::backup::runtime {

  include ::platform::filesystem::backup::params
  $lv_name = $::platform::filesystem::backup::params::lv_name
  $lv_size = $::platform::filesystem::backup::params::lv_size
  $devmapper = $::platform::filesystem::backup::params::devmapper

  platform::filesystem::resize { $lv_name:
    lv_name   => $lv_name,
    lv_size   => $lv_size,
    devmapper => $devmapper,
  }
}


class platform::filesystem::scratch::runtime {

  include ::platform::filesystem::scratch::params
  $lv_name = $::platform::filesystem::scratch::params::lv_name
  $lv_size = $::platform::filesystem::scratch::params::lv_size
  $devmapper = $::platform::filesystem::scratch::params::devmapper

  platform::filesystem::resize { $lv_name:
    lv_name   => $lv_name,
    lv_size   => $lv_size,
    devmapper => $devmapper,
  }
}

class platform::filesystem::conversion::runtime {
  include ::platform::filesystem::conversion
  include ::platform::filesystem::conversion::params

  $conversion_enabled = $::platform::filesystem::conversion::params::conversion_enabled
  $lv_name = $::platform::filesystem::conversion::params::lv_name
  $lv_size = $::platform::filesystem::conversion::params::lv_size
  $devmapper = $::platform::filesystem::conversion::params::devmapper

  if $conversion_enabled {
    Class['::platform::filesystem::conversion']
    -> platform::filesystem::resize { $lv_name:
      lv_name   => $lv_name,
      lv_size   => $lv_size,
      devmapper => $devmapper,
    }
  } else {
    $mountpoint = $::platform::filesystem::conversion::params::mountpoint
    exec { "umount ${lv_name} mountpoint ${mountpoint}":
      command => "umount ${mountpoint}; true",
      onlyif  => "mountpoint -q ${mountpoint}",
    } -> Mount[$lv_name]
  }
}

class platform::filesystem::instances::runtime {
  include ::platform::filesystem::instances
  include ::platform::filesystem::instances::params

  $instances_enabled = $::platform::filesystem::instances::params::instances_enabled
  $lv_name = $::platform::filesystem::instances::params::lv_name
  $lv_size = $::platform::filesystem::instances::params::lv_size
  $devmapper = $::platform::filesystem::instances::params::devmapper

  if $instances_enabled {
    Class['::platform::filesystem::instances']
    -> platform::filesystem::resize { $lv_name:
      lv_name   => $lv_name,
      lv_size   => $lv_size,
      devmapper => $devmapper,
    }
  }
}

class platform::filesystem::kubelet::runtime {

  include ::platform::filesystem::kubelet::params
  $lv_name = $::platform::filesystem::kubelet::params::lv_name
  $lv_size = $::platform::filesystem::kubelet::params::lv_size
  $devmapper = $::platform::filesystem::kubelet::params::devmapper

  platform::filesystem::resize { $lv_name:
    lv_name   => $lv_name,
    lv_size   => $lv_size,
    devmapper => $devmapper,
  }
  -> exec { "restart kubelet after ${lv_name} resize ${lv_size}":
      command => '/usr/local/sbin/pmon-restart kubelet'
  }
}


class platform::filesystem::docker::runtime {

  include ::platform::filesystem::docker::params
  $lv_name = $::platform::filesystem::docker::params::lv_name
  $lv_size = $::platform::filesystem::docker::params::lv_size
  $devmapper = $::platform::filesystem::docker::params::devmapper

  platform::filesystem::resize { $lv_name:
    lv_name   => $lv_name,
    lv_size   => $lv_size,
    devmapper => $devmapper,
  }
}

class platform::filesystem::log::params (
  $lv_name = 'log-lv',
  $lv_size = '8',
  $mountpoint = '/var/log',
  $devmapper = '/dev/mapper/cgts--vg-log--lv',
  $fs_type = 'ext4',
  $fs_options = ' '
) {}

class platform::filesystem::log
  inherits ::platform::filesystem::log::params {

  platform::filesystem { $lv_name:
      lv_name    => $lv_name,
      lv_size    => $lv_size,
      mountpoint => $mountpoint,
      fs_type    => $fs_type,
      fs_options => $fs_options
  }
}

class platform::filesystem::log::runtime {

  include ::platform::filesystem::log::params
  $lv_name = $::platform::filesystem::log::params::lv_name
  $lv_size = $::platform::filesystem::log::params::lv_size
  $devmapper = $::platform::filesystem::log::params::devmapper

  platform::filesystem::resize { $lv_name:
      lv_name   => $lv_name,
      lv_size   => $lv_size,
      devmapper => $devmapper,
  }
}

class platform::filesystem::var::params (
  $lv_name = 'var-lv',
  $lv_size = '20',
  $mountpoint = '/var',
  $devmapper = '/dev/mapper/cgts--vg-var--lv',
  $fs_type = 'ext4',
  $fs_options = ' '
) {}

class platform::filesystem::var
  inherits ::platform::filesystem::var::params {

  platform::filesystem { $lv_name:
      lv_name    => $lv_name,
      lv_size    => $lv_size,
      mountpoint => $mountpoint,
      fs_type    => $fs_type,
      fs_options => $fs_options
  }
}

class platform::filesystem::var::runtime {

  include ::platform::filesystem::var::params
  $lv_name = $::platform::filesystem::var::params::lv_name
  $lv_size = $::platform::filesystem::var::params::lv_size
  $devmapper = $::platform::filesystem::var::params::devmapper

  platform::filesystem::resize { $lv_name:
      lv_name   => $lv_name,
      lv_size   => $lv_size,
      devmapper => $devmapper,
  }
}

class platform::filesystem::root::params (
  $lv_name = 'root-lv',
  $lv_size = '20',
  $mountpoint = '/',
  $devmapper = '/dev/mapper/cgts--vg-root--lv',
  $fs_type = 'ext4',
  $fs_options = ' '
) {}

class platform::filesystem::root
  inherits ::platform::filesystem::root::params {

  platform::filesystem { $lv_name:
      lv_name    => $lv_name,
      lv_size    => $lv_size,
      mountpoint => $mountpoint,
      fs_type    => $fs_type,
      fs_options => $fs_options
  }
}

class platform::filesystem::root::runtime {

  include ::platform::filesystem::root::params
  $lv_name = $::platform::filesystem::root::params::lv_name
  $lv_size = $::platform::filesystem::root::params::lv_size
  $devmapper = $::platform::filesystem::root::params::devmapper

  platform::filesystem::resize { $lv_name:
      lv_name   => $lv_name,
      lv_size   => $lv_size,
      devmapper => $devmapper,
  }
}

class platform::filesystem::luks {

  if !str2bool($::is_controller_active) and !str2bool($::is_standalone_controller) {

    # Execute rsync command only on the standby controller
    exec { 'rsync_luks_folder':
      command   => '/usr/bin/rsync -v -acv --delete rsync://controller/luksdata/ /var/luks/stx/luks_fs/controller/',
      logoutput => true,
      # Allow exit code 0 (success) and 5 (Unknown module)
      returns   => [0, 5],
      onlyif    => [ "test ${::controller_sw_versions_match} = true", '/usr/local/bin/connectivity_test -t 10 controller', ],
    }
  }
}

class platform::filesystem::ceph::mountpoint {
  file { '/var/lib/ceph':
    ensure => 'directory',
    owner  => 'root',
    group  => 'root',
    mode   => '0755',
  }
}

class platform::filesystem::ceph::params (
  $ceph_enabled = false,
  $ensure = absent,
  $lv_size = '1',
  $lv_name = 'ceph-lv',
  $mountpoint = '/var/lib/ceph/data',
  $devmapper = '/dev/mapper/cgts--vg-ceph--lv',
  $fs_type = 'ext4',
  $fs_options = ' ',
  $mode = '0750',
) { }

class platform::filesystem::ceph
  inherits ::platform::filesystem::ceph::params {
  include ::platform::filesystem::ceph::mountpoint

  if $ceph_enabled {
    $ensure = present
    $mode = '0777'
  }

  Class['::platform::filesystem::ceph::mountpoint']
  -> platform::filesystem { $lv_name:
    ensure     => $ensure,
    lv_name    => $lv_name,
    lv_size    => $lv_size,
    mountpoint => $mountpoint,
    fs_type    => $fs_type,
    fs_options => $fs_options,
    mode       => $mode
  }
}

class platform::filesystem::ceph::runtime {
  include ::platform::filesystem::ceph
  include ::platform::filesystem::ceph::params

  $ceph_enabled = $::platform::filesystem::ceph::params::ceph_enabled
  $lv_name = $::platform::filesystem::ceph::params::lv_name
  $lv_size = $::platform::filesystem::ceph::params::lv_size
  $devmapper = $::platform::filesystem::ceph::params::devmapper

  if $ceph_enabled {
    Class['::platform::filesystem::ceph']
    -> platform::filesystem::resize { $lv_name:
      lv_name   => $lv_name,
      lv_size   => $lv_size,
      devmapper => $devmapper,
    }
  } else {
    $mountpoint = $::platform::filesystem::ceph::params::mountpoint
    exec { "umount ${lv_name} mountpoint ${mountpoint}":
      command => "umount ${mountpoint}; true",
      onlyif  => "mountpoint -q ${mountpoint}",
    } -> Mount[$lv_name]
  }
}

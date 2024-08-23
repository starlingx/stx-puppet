define platform::devices::qat_device_files(
  $qat_idx,
  $device_id,
) {
  if $device_id == 'dh895xcc'{
      file { "/etc/dh895xcc_dev${qat_idx}.conf":
        ensure => 'present',
        owner  => 'root',
        group  => 'root',
        mode   => '0640',
        notify => Service['qat_service'],
      }
  }

  if $device_id == 'c62x'{
      file { "/etc/c62x_dev${qat_idx}.conf":
        ensure => 'present',
        owner  => 'root',
        group  => 'root',
        mode   => '0640',
        notify => Service['qat_service'],
      }
  }
}

class platform::devices::qat (
  $device_config = {},
  $service_enabled = false
)
{
  if $service_enabled {
    create_resources('platform::devices::qat_device_files', $device_config)

    service { 'qat_service':
      ensure     => 'running',
      enable     => true,
      hasrestart => true,
      notify     => Service['sysinv-agent'],
    }
  }
}

define platform::devices::sriov_enable (
  $num_vfs,
  $addr,
  $driver,
  $device_id,
  $up_requirement = false
) {
  if ($driver == 'igb_uio') {
    $vf_file = 'max_vfs'
  } else {
    $vf_file = 'sriov_numvfs'
  }
  exec { "sriov-enable-device: ${title}":
    command   => template('platform/sriov.enable-device.erb'),
    provider  => shell,
    onlyif    => ["test -d /sys/bus/pci/devices/${addr}", "egrep -wvq ^${num_vfs} /sys/bus/pci/devices/${addr}/${vf_file}"],
    logoutput => true,
  }
}

define platform::devices::sriov_bind (
  $addr,
  $driver,
  $num_vfs = undef,
  $device_id = undef
) {
  if ($driver != undef) and ($addr != undef) {
    if ($device_id != undef) and ($device_id == '0d8f') {
      include platform::devices::fpga::n3000::reset
      Class['platform::devices::fpga::n3000::reset']
      -> Exec["sriov-bind-device: ${title}"]

      include platform::devices::n3000::config
      Exec["sriov-enable-device: ${title}"]
      -> Class['platform::devices::n3000::config']
    }
    if ($device_id != undef) and ($device_id == '0d5c') {
      class { platform::devices::acc100::config :
        num_vf_bundles => $num_vfs
      }
      Exec["sriov-enable-device: ${title}"]
      -> Class['platform::devices::acc100::config']
    }
    if ($device_id != undef) and ($device_id == '57c0') {
      class { platform::devices::acc200::config :
        num_vf_bundles => $num_vfs
      }
      Exec["sriov-enable-device: ${title}"]
      -> Class['platform::devices::acc200::config']
    }
    if ($driver == 'vfio-pci') {
      exec { "Load vfio-pci driver with sriov enabled: ${title}":
        command   => 'modprobe vfio-pci enable_sriov=1 disable_idle_d3=1',
        logoutput => true,
      }
      -> exec { "Ensure enable_sriov is set: ${title}":
        command   => 'echo 1 > /sys/module/vfio_pci/parameters/enable_sriov',
        logoutput => true,
      }
      -> exec { "Ensure disable_idle_d3 is set: ${title}":
        command   => 'echo 1 > /sys/module/vfio_pci/parameters/disable_idle_d3',
        logoutput => true,
      }
      -> exec { "sriov-bind-device: ${title}":
        command   => template('platform/sriov.bind-device.erb'),
        logoutput => true,
      }
    } else {
      ensure_resource(kmod::load, $driver)
      exec { "sriov-bind-device: ${title}":
        command   => template('platform/sriov.bind-device.erb'),
        logoutput => true,
        require   => [ Kmod::Load[$driver] ],
      }
    }
  }
}

define platform::devices::sriov_vf_bind (
  $vf_config,
  $pf_config = undef,
) {
    create_resources('platform::devices::sriov_bind', $vf_config, {})
}

define platform::devices::sriov_pf_bind (
  $pf_config,
  $vf_config = undef
) {
  Platform::Devices::Sriov_pf_bind[$name] -> Platform::Devices::Sriov_pf_enable[$name]
  create_resources('platform::devices::sriov_bind', $pf_config, {})
}

define platform::devices::sriov_pf_enable (
  $pf_config,
  $vf_config = undef
) {
  create_resources('platform::devices::sriov_enable', $pf_config, {})
}

class platform::devices::fpga::fec::vf
  inherits ::platform::devices::fpga::fec::params {
  require ::platform::devices::fpga::fec::pf
  create_resources('platform::devices::sriov_vf_bind', $device_config, {})
}

class platform::devices::fpga::fec::pf
  inherits ::platform::devices::fpga::fec::params {
  create_resources('platform::devices::sriov_pf_bind', $device_config, {})
  create_resources('platform::devices::sriov_pf_enable', $device_config, {})
}

class platform::devices::fpga::fec::runtime {
  include ::platform::devices::fpga::fec::pf
}

class platform::devices::fpga::fec::params (
  $device_config = {}
) { }

class platform::devices::fpga::n3000::reset
  inherits ::platform::devices::fpga::fec::params {
  # To reset N3000 FPGA
  Class[$name] -> Class['::platform::devices::fpga::fec::pf']
  Class[$name] -> Class['::platform::network::interfaces::sriov::enable']
  exec { 'Reset n3000 fpgas':
    command   => 'sysinv-reset-n3000-fpgas',
    path      => ['/usr/bin/', '/usr/sbin/'],
    tries     => 60,
    try_sleep => 1,
    require   => Anchor['platform::networking'],
    unless    => 'test -e /var/run/.sysinv_n3000_reset'
  }
}

class platform::devices::fpga::fec::config
  inherits ::platform::devices::fpga::fec::params {
  notice('Looking for N3000 device to reset...')
  if $::is_n3000_present {
    include platform::network::interfaces::sriov::enable
    include platform::devices::fpga::n3000::reset
  }
  include platform::devices::fpga::fec::pf
  include platform::devices::fpga::fec::vf
}

class platform::devices::fpga::fec {
  Class[$name] -> Class['::sysinv::agent']
  require ::platform::devices::fpga::fec::config
}

class platform::devices::n3000::fec (
  $enabled = true
) {}

class platform::devices::n3000::config
  inherits ::platform::devices::n3000::fec {
  if $enabled {
    exec { 'Configure N3000 FPGA 5GNR device':
      command   => template('platform/n3000-config.erb'),
      logoutput => true,
    }
  }
}

class platform::devices::acc100::fec (
  $enabled = true
) {}

class platform::devices::acc100::config (
  $num_vf_bundles
) inherits ::platform::devices::acc100::fec {
  if $enabled {
    file { [ '/etc/pf-bb-config/', '/etc/pf-bb-config/acc100' ]:
      ensure => 'directory',
      owner  => 'root',
      group  => 'root',
      mode   => '0640',
    }
    -> exec { "Configure ACC100 device with ${num_vf_bundles} VF bundles":
        command   => template('platform/acc100-config.erb'),
        logoutput => true,
    }
  }
}

class platform::devices::acc200::fec (
  $enabled = true
) {}

class platform::devices::acc200::config (
  $num_vf_bundles
) inherits ::platform::devices::acc200::fec {
  if $enabled {
    file { [ '/etc/pf-bb-config/', '/etc/pf-bb-config/vrb1' ]:
      ensure => 'directory',
      owner  => 'root',
      group  => 'root',
      mode   => '0640',
    }
    -> exec { "Configure ACC200/VRB1 device with ${num_vf_bundles} VF bundles":
        command   => template('platform/acc200-config.erb'),
        logoutput => true,
    }
  }
}

class platform::devices::qat::qat_4xxx {
  if $::is_qat_device_present {
    notice('QAT device found.')

    $vf_driver = 'vfio-pci'

    exec { 'Load vfio-pci driver with sriov enabled for QAT device':
      command   => 'modprobe vfio-pci enable_sriov=1 disable_idle_d3=1',
      logoutput => true,
    }
    -> exec { 'Ensure enable_sriov is set for QAT device':
      command   => 'echo 1 > /sys/module/vfio_pci/parameters/enable_sriov',
      logoutput => true,
    }
    -> exec { 'Ensure disable_idle_d3 is set for QAT device':
      command   => 'echo 1 > /sys/module/vfio_pci/parameters/disable_idle_d3',
      logoutput => true,
    }

    exec { 'config_qat':
      command   => 'bash /usr/share/puppet/modules/platform/files/config_qat.sh',
      logoutput => true,
      timeout   => 5,
      notify    => Service['qat_service'],
    }

    service { 'qat_service':
      ensure     => 'running',
      enable     => true,
      hasrestart => true,
      notify     => Service['sysinv-agent'],
      require    => Exec['Load vfio-pci driver with sriov enabled for QAT device'],
    }

    exec { 'qat_systemctl_enable':
        command => 'systemctl enable qat_service.service',
        unless  => 'systemctl is-enabled qat_service.service'
    }
  } else {
    notice('QAT device not found.')
  }
}

class platform::devices {
  include ::platform::devices::qat
  include ::platform::devices::qat::qat_4xxx
  include ::platform::devices::fpga::fec
}

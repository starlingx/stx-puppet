define qat_device_files(
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
    create_resources('qat_device_files', $device_config)

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
  $driver
) {
  if ($driver == 'igb_uio') {
    $vf_file = 'max_vfs'
  } else {
    $vf_file = 'sriov_numvfs'
  }
  if $num_vfs {
    exec { "sriov-enable-device: ${title}":
      command   => template('platform/sriov.enable-device.erb'),
      logoutput => true,
    }
  }
}

define platform::devices::sriov_bind (
  $addr,
  $driver,
  $num_vfs = undef
) {
  if ($driver != undef) and ($addr != undef) {
    ensure_resource(kmod::load, $driver)
    exec { "sriov-bind-device: ${title}":
      command   => template('platform/sriov.bind-device.erb'),
      logoutput => true,
      require   => [ Kmod::Load[$driver] ],
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
  if ($::personality == 'controller') and (length($device_config) > 0) {
    # In an AIO system, it's possible for the device plugin pods to start
    # before the device VFs are bound to a driver.  Restarting the device
    # plugin pods will allow them to re-scan the set of matching
    # device ids/drivers specified in the /etc/pcidp/config.json file.
    # This may be mitigated by moving to helm + configmap for the device
    # plugin.
    exec { 'Restart sriovdp daemonset':
      path      => '/usr/bin:/usr/sbin:/bin',
      command   => 'kubectl --kubeconfig=/etc/kubernetes/admin.conf rollout restart ds -n kube-system kube-sriov-device-plugin-amd64 || true', # lint:ignore:140chars
      logoutput => true,
    }
  }
}

class platform::devices::fpga::fec::pf
  inherits ::platform::devices::fpga::fec::params {
  create_resources('platform::devices::sriov_pf_bind', $device_config, {})
  create_resources('platform::devices::sriov_pf_enable', $device_config, {})
}

class platform::devices::fpga::fec::runtime {
  include ::platform::devices::fpga::fec::config
}

class platform::devices::fpga::fec::params (
  $device_config = {}
) { }

class platform::devices::fpga::fec::config
  inherits ::platform::devices::fpga::fec::params {
  include platform::devices::fpga::fec::pf
  include platform::devices::fpga::fec::vf
}

class platform::devices::fpga::fec {
  Class[$name] -> Class['::sysinv::agent']
  require ::platform::devices::fpga::fec::config
}


class platform::devices {
  include ::platform::devices::qat
  include ::platform::devices::fpga::fec
}


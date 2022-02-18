define ptp_config_files(
  $_name,
  $service,
  $global_parameters,
  $interfaces,
  $ensure,
  $enable,
  $cmdline_opts,
  $id
) {
  file { $_name:
    ensure  => file,
    notify  => Service["instance-${_name}"],
    path    => "/etc/ptpinstance/${service}-${_name}.conf",
    mode    => '0644',
    content => template('platform/ptpinstance.conf.erb'),
    require => File['/etc/ptpinstance']
  }
  -> file { "${_name}-sysconfig":
    ensure  => file,
    notify  => Service["instance-${_name}"],
    path    => "/etc/sysconfig/ptpinstance/${service}-instance-${_name}",
    mode    => '0644',
    content => template("platform/${service}-instance.erb"),
    require => File['/etc/sysconfig/ptpinstance']
  }
  -> service { "instance-${_name}":
    ensure     => $ensure,
    enable     => $enable,
    name       => "${service}@${_name}",
    hasstatus  => true,
    hasrestart => true,
  }
  -> exec { "enable-${_name}":
    command => "/usr/bin/systemctl enable \
    ${service}@${_name}",
  }
}

define nic_clock_handler (
  $ifname,
  $parameters,
  $port_names,
  $uuid,
  $base_port,
  $wpc_commands = {
    'sma1' => {
        'input' => "1 1 > /sys/class/net/${base_port}/device/ptp/\$PTP/pins/SMA1",
        'output' => "2 1 > /sys/class/net/${base_port}/device/ptp/\$PTP/pins/SMA1"
    },
    'sma2' => {
        'input' => "1 2 > /sys/class/net/${base_port}/device/ptp/\$PTP/pins/SMA2",
        'output' => "2 2 > /sys/class/net/${base_port}/device/ptp/\$PTP/pins/SMA2"
    },
    'u.fl1' => {
        'output' => "2 1 > /sys/class/net/${base_port}/device/ptp/\$PTP/pins/U.FL1"
    },
    'u.fl2' => {
        'input' => "1 2 > /sys/class/net/${base_port}/device/ptp/\$PTP/pins/U.FL2"
    },
    'synce_rclka' => {
        'enabled' => "1 0 > /sys/class/net/${name}/device/phy/synce"
    },
    'synce_rclkb' => {
        'enabled' => "1 1 > /sys/class/net/${name}/device/phy/synce"
    }
  }
) {
  exec { "${ifname}_heading":
    command => "echo ifname [${name}] >> /etc/ptpinstance/clock-conf.conf",
    require => File['ensure_clock_conf_present']
  }
  -> exec { "${ifname}_${base_port}_heading":
    command  => "echo base_port [${base_port}] >> /etc/ptpinstance/clock-conf.conf",
  }
  $parameters.each |String $parm, String $value| {
    exec { "${ifname}_${parm}":
      command  => "PTP=$(basename /sys/class/net/${base_port}/device/ptp/ptp*);\
        echo ${wpc_commands[$parm][$value]}",
      provider => shell,
      onlyif   => "grep 000e /sys/class/net/${base_port}/device/subsystem_device",
      require  => [ Exec["${ifname}_heading"], Exec["${ifname}_${base_port}_heading"] ]
    }
    -> exec { "${ifname}_${parm}_to_file":
      command  => "echo ${parm} ${value} >> /etc/ptpinstance/clock-conf.conf"
    }
  }
}

define nic_clock_reset (
  $ifname,
  $parameters,
  $port_names,
  $uuid,
  $base_port,
) {
  exec { "${ifname}_clear_UFL1":
    command  => "PTP=$(basename /sys/class/net/${base_port}/device/ptp/ptp*);\
      echo 0 1 > /sys/class/net/${base_port}/device/ptp/\$PTP/pins/U.FL1",
    provider => shell,
    onlyif   => "grep 000e /sys/class/net/${base_port}/device/subsystem_device"
  }
  exec { "${ifname}_clear_UFL2":
    command  => "PTP=$(basename /sys/class/net/${base_port}/device/ptp/ptp*);\
      echo 0 2 > /sys/class/net/${base_port}/device/ptp/\$PTP/pins/U.FL2",
    provider => shell,
    onlyif   => "grep 000e /sys/class/net/${base_port}/device/subsystem_device"
  }
  exec { "${ifname}_clear_SMA1":
    command  => "PTP=$(basename /sys/class/net/${base_port}/device/ptp/ptp*);\
      echo 0 1 > /sys/class/net/${base_port}/device/ptp/\$PTP/pins/SMA1",
    provider => shell,
    onlyif   => "grep 000e /sys/class/net/${base_port}/device/subsystem_device"
  }
  exec { "${ifname}_clear_SMA2":
    command  => "PTP=$(basename /sys/class/net/${base_port}/device/ptp/ptp*);\
      echo 0 2 > /sys/class/net/${base_port}/device/ptp/\$PTP/pins/SMA2",
    provider => shell,
    onlyif   => "grep 000e /sys/class/net/${base_port}/device/subsystem_device"
  }
  exec { "${ifname}_clear_rclka":
    command => "echo 0 0 > /sys/class/net/${name}/device/phy/synce",
    onlyif  => "grep 000e /sys/class/net/${name}/device/subsystem_device"
  }
  exec { "${ifname}_clear_rclkb":
    command => "echo 0 1 > /sys/class/net/${name}/device/phy/synce",
    onlyif  => "grep 000e /sys/class/net/${name}/device/subsystem_device"
  }
}

class platform::ptpinstance::nic_clock (
  $nic_clock_config = {},
  $nic_clock_enabled = false,
) {
  require ::platform::ptpinstance::nic_clock::nic_reset

  file { 'ensure_clock_conf_present':
    ensure  => present,
    path    => '/etc/ptpinstance/clock-conf.conf',
    mode    => '0644',
    require => File['/etc/ptpinstance']
  }
  if $nic_clock_enabled {
    create_resources('nic_clock_handler', $nic_clock_config)
  }
}

class platform::ptpinstance::nic_clock::nic_reset (
  $nic_clock_config = $platform::ptpinstance::nic_clock::nic_clock_config,
  $nic_clock_enabled = $platform::ptpinstance::nic_clock::nic_clock_enabled
) {
  if $nic_clock_enabled {
    create_resources('nic_clock_reset', $nic_clock_config)
  }
  exec { 'clear_clock_conf_file':
    command => 'echo "" > /etc/ptpinstance/clock-conf.conf',
    onlyif  => 'stat /etc/ptpinstance/clock-conf.conf'
  }
}

class platform::ptpinstance (
  $enabled = false,
  $runtime = false,
  $config = []
) {
  if $enabled {
    $ptp_state = {
      'ensure' => 'running',
      'enable' => true
    }
  }

  if $runtime {
    # During runtime we set first_step_threshold to 0. This ensures that there are
    # no large time changes to a running host
    $phc2sys_cmd_opts = '-F 0'
  } else {
    $phc2sys_cmd_opts = ''
  }

  file {'/etc/ptpinstance':
    ensure =>  directory,
    mode   =>  '0755',
  }
  -> file{'/etc/sysconfig/ptpinstance':
    ensure =>  directory,
    mode   =>  '0755',
  }
  -> file { 'ptp4l_service_instance':
    ensure  => file,
    path    => '/etc/systemd/system/ptp4l@.service',
    mode    => '0644',
    content => template('platform/ptp4l-instance.service.erb')
  }
  -> file { 'phc2sys_service_instance':
    ensure  => file,
    path    => '/etc/systemd/system/phc2sys@.service',
    mode    => '0644',
    content => template('platform/phc2sys-instance.service.erb'),
    }
  -> file { 'ts2phc_service_instance':
    ensure  => file,
    path    => '/etc/systemd/system/ts2phc@.service',
    mode    => '0644',
    content => template('platform/ts2phc-instance.service.erb'),
    }
  -> exec { 'ptpinstance-systemctl-daemon-reload':
    command => '/usr/bin/systemctl daemon-reload',
  }

  if $enabled {
    create_resources('ptp_config_files', $config, $ptp_state)
  } else {
    exec { 'disable-ptp4l-instance':
      command => '/usr/bin/systemctl disable ptp4l@*',
      onlyif  => 'test -f /etc/systemd/system/ptp4l@.service',
      require => Exec['ptpinstance-systemctl-daemon-reload'],
    }
    -> exec { 'disable-phc2sys-instance':
      command => '/usr/bin/systemctl disable phc2sys@*',
      onlyif  => 'test -f /etc/systemd/system/phc2sys@.service',
    }
    -> exec { 'disable-ts2phc-instance':
      command => '/usr/bin/systemctl disable ts2phc@*',
      onlyif  => 'test -f /etc/systemd/system/ts2phc@.service',
    }
    -> exec { 'stop-ptp4l-instance':
      command => '/usr/bin/systemctl stop ptp4l@*',
    }
    -> exec { 'stop-phc2sys-instance':
      command => '/usr/bin/systemctl stop phc2sys@*',
    }
    -> exec { 'stop-ts2phc-instance':
      command => '/usr/bin/systemctl stop ts2phc@*',
    }
  }
}

class platform::ptpinstance::runtime {
  class { 'platform::ptpinstance': runtime => true }
  class { 'platform::ptpinstance::nic_clock': }
  -> exec {'Ensure collectd is restarted':
    command => '/usr/local/sbin/pmon-restart collectd'
  }
}


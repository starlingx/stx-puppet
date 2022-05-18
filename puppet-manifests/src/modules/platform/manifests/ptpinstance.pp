define ptp_config_files(
  $_name,
  $service,
  $global_parameters,
  $interfaces,
  $ensure,
  $enable,
  $cmdline_opts,
  $id,
  $pmc_gm_settings
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
    require    => Exec['ptpinstance-systemctl-daemon-reload'],
    before     => Exec['set-ice-gnss-thread-niceness']
  }
  -> exec { "enable-${_name}":
    command => "/usr/bin/systemctl enable \
    ${service}@${_name}",
  }
}

define set_ptp4l_pmc_parameters(
  $_name,
  $service,
  $global_parameters,
  $interfaces,
  $ensure,
  $enable,
  $cmdline_opts,
  $id,
  $pmc_gm_settings
) {
  if ($service == 'ptp4l') and ($pmc_gm_settings != '') {
    exec { "${_name}_set_initial_pmc_paramters":
      # This command always returns 0 even if it fails, but it is always running the same
      # valid command so failure is not expected.
      command => "/sbin/pmc -u -b 0 -f /etc/ptpinstance/${service}-${_name}.conf \
                  'set GRANDMASTER_SETTINGS_NP \
                  clockClass ${pmc_gm_settings['clockClass']} \
                  clockAccuracy ${pmc_gm_settings['clockAccuracy']} \
                  offsetScaledLogVariance ${pmc_gm_settings['offsetScaledLogVariance']} \
                  currentUtcOffset ${pmc_gm_settings['currentUtcOffset']} \
                  leap61 ${pmc_gm_settings['leap61']} \
                  leap59 ${pmc_gm_settings['leap59']} \
                  currentUtcOffsetValid ${pmc_gm_settings['currentUtcOffsetValid']} \
                  ptpTimescale ${pmc_gm_settings['ptpTimescale']} \
                  timeTraceable ${pmc_gm_settings['timeTraceable']} \
                  frequencyTraceable ${pmc_gm_settings['frequencyTraceable']} \
                  timeSource ${pmc_gm_settings['timeSource']}'",
      require => Service["instance-${_name}"]
    }
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
      onlyif   => "grep 000[e-f] /sys/class/net/${base_port}/device/subsystem_device",
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
    onlyif   => "grep 000[e-f] /sys/class/net/${base_port}/device/subsystem_device"
  }
  exec { "${ifname}_clear_UFL2":
    command  => "PTP=$(basename /sys/class/net/${base_port}/device/ptp/ptp*);\
      echo 0 2 > /sys/class/net/${base_port}/device/ptp/\$PTP/pins/U.FL2",
    provider => shell,
    onlyif   => "grep 000[e-f] /sys/class/net/${base_port}/device/subsystem_device"
  }
  exec { "${ifname}_clear_SMA1":
    command  => "PTP=$(basename /sys/class/net/${base_port}/device/ptp/ptp*);\
      echo 0 1 > /sys/class/net/${base_port}/device/ptp/\$PTP/pins/SMA1",
    provider => shell,
    onlyif   => "grep 000[e-f] /sys/class/net/${base_port}/device/subsystem_device"
  }
  exec { "${ifname}_clear_SMA2":
    command  => "PTP=$(basename /sys/class/net/${base_port}/device/ptp/ptp*);\
      echo 0 2 > /sys/class/net/${base_port}/device/ptp/\$PTP/pins/SMA2",
    provider => shell,
    onlyif   => "grep 000[e-f] /sys/class/net/${base_port}/device/subsystem_device"
  }
  exec { "${ifname}_clear_rclka":
    command => "echo 0 0 > /sys/class/net/${name}/device/phy/synce",
    onlyif  => "grep 000[e-f] /sys/class/net/${name}/device/subsystem_device"
  }
  exec { "${ifname}_clear_rclkb":
    command => "echo 0 1 > /sys/class/net/${name}/device/phy/synce",
    onlyif  => "grep 000[e-f] /sys/class/net/${name}/device/subsystem_device"
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
  -> tidy { 'purge_conf':
    path    => '/etc/ptpinstance',
    matches => [ '[^clock]*.conf' ],
    recurse => true,
    rmdirs  => false
  }
  -> file{'/etc/sysconfig/ptpinstance':
    ensure =>  directory,
    mode   =>  '0755',
  }
  -> tidy { 'purge_sysconf':
    path    => '/etc/sysconfig/ptpinstance/',
    matches => [ '*-instance-*' ],
    recurse => true,
    rmdirs  => false
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
  -> exec { 'stop-ptp4l-instances':
    command => '/usr/bin/systemctl stop ptp4l*',
  }
  -> exec { 'disable-ptp4l-single-instance':
    command => '/usr/bin/systemctl disable ptp4l.service',
    onlyif  => 'test -f /etc/systemd/system/ptp4l.service',
  }
  -> exec { 'disable-ptp4l-multi-instances':
    command => '/usr/bin/systemctl disable ptp4l@*',
    onlyif  => 'test -f /etc/systemd/system/ptp4l@.service',
  }
  -> exec { 'stop-phc2sys-instances':
    command => '/usr/bin/systemctl stop phc2sys*',
  }
  -> exec { 'disable-phc2sys-single-instance':
    command => '/usr/bin/systemctl disable phc2sys.service',
    onlyif  => 'test -f /etc/systemd/system/phc2sys.service',
  }
  -> exec { 'disable-phc2sys-multi-instances':
    command => '/usr/bin/systemctl disable phc2sys@*',
    onlyif  => 'test -f /etc/systemd/system/phc2sys@.service',
  }
  -> exec { 'stop-ts2phc-instance':
    command => '/usr/bin/systemctl stop ts2phc@*',
  }
  -> exec { 'disable-ts2phc-instance':
    command => '/usr/bin/systemctl disable ts2phc@*',
    onlyif  => 'test -f /etc/systemd/system/ts2phc@.service',
  }
  -> exec { 'ptpinstance-systemctl-daemon-reload':
    command => '/usr/bin/systemctl daemon-reload',
  }
  -> exec { 'ptpinstance-systemctl-reset-failed-ptp4l':
    command => '/usr/bin/systemctl reset-failed ptp4l*',
  }
  -> exec { 'ptpinstance-systemctl-reset-failed-phc2sys':
    command => '/usr/bin/systemctl reset-failed phc2sys*',
  }
  -> exec { 'ptpinstance-systemctl-reset-failed-ts2phc':
    command => '/usr/bin/systemctl reset-failed ts2phc@*',
  }

  if $enabled {
    create_resources('ptp_config_files', $config, $ptp_state)
    create_resources('set_ptp4l_pmc_parameters', $config, $ptp_state)
  }

  exec { 'set-ice-gnss-thread-niceness':
  # The niceness value of -10 should match what is being set in affine-platform.sh
  command  => "renice -n -10 -p \$(ps -e -p 2 | grep \"ice-gnss-\" \
             | awk '{ printf \$1; printf \" \" }')",
  provider => shell,
  }
}

class platform::ptpinstance::runtime {
  class { 'platform::ptpinstance': runtime => true }
  class { 'platform::ptpinstance::nic_clock': }
  -> exec {'Ensure collectd is restarted':
    command => '/usr/local/sbin/pmon-restart collectd'
  }
}

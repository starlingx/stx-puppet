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
    path    => "/etc/ptpinstance/${service}-${_name}.conf",
    mode    => '0644',
    content => template('platform/ptpinstance.conf.erb'),
    require => File['/etc/ptpinstance']
  }
  -> file { "${_name}-sysconfig":
    ensure  => file,
    path    => "/etc/sysconfig/ptpinstance/${service}-instance-${_name}",
    mode    => '0644',
    content => template("platform/${service}-instance.erb"),
    require => File['/etc/sysconfig/ptpinstance']
  }
  -> service { $_name:
    ensure     => $ensure,
    enable     => $enable,
    name       => "${service}@${_name}",
    hasstatus  => true,
    hasrestart => true,
  }
  if $enable {
    exec { "enable-${_name}":
      command => "/usr/bin/systemctl enable \
      ${service}@${_name}",
    }
  } else {
    exec { "disable-${_name}":
      command => "/usr/bin/systemctl disable \
                 ${service}@${_name}",
      require => Exec['systemctl-daemon-reload'],
    }
    -> exec { "stop-${_name}":
      command => "/usr/bin/systemctl stop \
                 ${service}@${_name}",
    }
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
  -> file { 'ptp4l_service':
    ensure  => file,
    path    => '/etc/systemd/system/ptp4l@.service',
    mode    => '0644',
    content => template('platform/ptp4l-instance.service.erb')
  }
  -> file { 'phc2sys_service':
    ensure  => file,
    path    => '/etc/systemd/system/phc2sys@.service',
    mode    => '0644',
    content => template('platform/phc2sys-instance.service.erb'),
    }
  -> file { 'ts2phc_service':
    ensure  => file,
    path    => '/etc/systemd/system/ts2phc@.service',
    mode    => '0644',
    content => template('platform/ts2phc-instance.service.erb'),
    }
  -> exec { 'systemctl-daemon-reload':
    command => '/usr/bin/systemctl daemon-reload',
  }

  if $enabled {
    create_resources('ptp_config_files', $config, $ptp_state)
  } else {
    exec { 'disable-ptp4l':
      command => '/usr/bin/systemctl disable ptp4l@*',
      require => Exec['systemctl-daemon-reload'],
    }
    -> exec { 'disable-phc2sys':
      command => '/usr/bin/systemctl disable phc2sys@*',
    }
    -> exec { 'disable-ts2phc':
      command => '/usr/bin/systemctl disable ts2phc@*',
    }
    -> exec { 'stop-ptp4l':
      command => '/usr/bin/systemctl stop ptp4l@*',
    }
    -> exec { 'stop-phc2sys':
      command => '/usr/bin/systemctl stop phc2sys@*',
    }
    -> exec { 'stop-ts2phc':
      command => '/usr/bin/systemctl stop ts2phc@*',
    }
  }
}

class platform::ptp::runtime {
  class { 'platform::ptp': runtime => true }
}


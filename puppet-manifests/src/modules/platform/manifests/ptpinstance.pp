define ptp_config_files(
  $_name,
  $service,
  $global_parameters,
  $interfaces,
  $ensure,
  $enable,
  $cmdline_opts,
  $id,
  $ptp_conf_dir,
  $ptp_options_dir,
  $pmc_gm_settings = '',
  $device_parameters = ''
) {
  file { $_name:
    ensure  => file,
    notify  => Service["instance-${_name}"],
    path    => "${ptp_conf_dir}/ptpinstance/${service}-${_name}.conf",
    mode    => '0644',
    content => template('platform/ptpinstance.conf.erb'),
    require => File["${ptp_conf_dir}/ptpinstance"]
  }
  -> file { "${_name}-sysconfig":
    ensure  => file,
    notify  => Service["instance-${_name}"],
    path    => "${ptp_options_dir}/ptpinstance/${service}-instance-${_name}",
    mode    => '0644',
    content => template("platform/${service}-instance.erb"),
    require => File["${ptp_options_dir}/ptpinstance"]
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
  $ptp_conf_dir,
  $ptp_options_dir,
  $pmc_gm_settings = '',
  $device_parameters = ''
) {
  if ($service == 'ptp4l') and ($pmc_gm_settings != '') {
    exec { "${_name}_set_initial_pmc_paramters":
      # This command always returns 0 even if it fails, but it is always running the same
      # valid command so failure is not expected.
      command => "/sbin/pmc -u -b 0 \
                  -f ${ptp_conf_dir}/ptpinstance/${service}-${_name}.conf \
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
  $ptp_conf_dir,
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
    command => "echo ifname [${name}] >> ${ptp_conf_dir}/ptpinstance/clock-conf.conf",
    require => File['ensure_clock_conf_present']
  }
  -> exec { "${ifname}_${base_port}_heading":
    command  => "echo base_port [${base_port}] >> ${ptp_conf_dir}/ptpinstance/clock-conf.conf",
  }
  $parameters.each |String $parm, String $value| {
    exec { "${ifname}_${parm}":
      command  => "PTP=$(basename /sys/class/net/${base_port}/device/ptp/ptp*);\
        echo ${wpc_commands[$parm][$value]}",
      provider => shell,
      require  => [ Exec["${ifname}_heading"], Exec["${ifname}_${base_port}_heading"] ]
    }
    -> exec { "${ifname}_${parm}_to_file":
      command  => "echo ${parm} ${value} >> ${ptp_conf_dir}/ptpinstance/clock-conf.conf"
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
  }
  exec { "${ifname}_clear_UFL2":
    command  => "PTP=$(basename /sys/class/net/${base_port}/device/ptp/ptp*);\
      echo 0 2 > /sys/class/net/${base_port}/device/ptp/\$PTP/pins/U.FL2",
    provider => shell,
  }
  exec { "${ifname}_clear_SMA1":
    command  => "PTP=$(basename /sys/class/net/${base_port}/device/ptp/ptp*);\
      echo 0 1 > /sys/class/net/${base_port}/device/ptp/\$PTP/pins/SMA1",
    provider => shell,
  }
  exec { "${ifname}_clear_SMA2":
    command  => "PTP=$(basename /sys/class/net/${base_port}/device/ptp/ptp*);\
      echo 0 2 > /sys/class/net/${base_port}/device/ptp/\$PTP/pins/SMA2",
    provider => shell,
  }
  exec { "${ifname}_clear_rclka":
    command => "echo 0 0 > /sys/class/net/${name}/device/phy/synce",
  }
  exec { "${ifname}_clear_rclkb":
    command => "echo 0 1 > /sys/class/net/${name}/device/phy/synce",
  }
}

class platform::ptpinstance::params {
  if $::osfamily == 'Debian' {
    $ptp_conf_dir = '/etc/linuxptp'
    $ptp_options_dir = '/etc/default'
  }
  else {
    $ptp_conf_dir = '/etc'
    $ptp_options_dir = '/etc/sysconfig'
  }
}

class platform::ptpinstance::nic_clock (
  $nic_clock_config = {},
  $nic_clock_enabled = false,
) {
  include ::platform::ptpinstance::params
  $ptp_conf_dir = $::platform::ptpinstance::params::ptp_conf_dir
  $ptp_options_dir = $::platform::ptpinstance::params::ptp_options_dir

  require ::platform::ptpinstance::nic_clock::nic_reset

  file { 'ensure_clock_conf_present':
    ensure  => present,
    path    => "${ptp_conf_dir}/ptpinstance/clock-conf.conf",
    mode    => '0644',
    require => File["${ptp_conf_dir}/ptpinstance"]
  }
  if $nic_clock_enabled {
    create_resources('nic_clock_handler', $nic_clock_config, {'ptp_conf_dir' => $ptp_conf_dir})
  }
}

class platform::ptpinstance::nic_clock::nic_reset (
  $nic_clock_config = $platform::ptpinstance::nic_clock::nic_clock_config,
  $nic_clock_enabled = $platform::ptpinstance::nic_clock::nic_clock_enabled
) {
  include ::platform::ptpinstance::params
  $ptp_conf_dir = $::platform::ptpinstance::params::ptp_conf_dir

  if $nic_clock_enabled {
    create_resources('nic_clock_reset', $nic_clock_config)
  }
  exec { 'clear_clock_conf_file':
    command => "echo \"\" > ${ptp_conf_dir}/ptpinstance/clock-conf.conf",
    onlyif  => "stat ${ptp_conf_dir}/ptpinstance/clock-conf.conf"
  }
}

class platform::ptpinstance (
  $enabled = false,
  $runtime = false,
  $config = []
) {
  include ::platform::ptpinstance::params
  $ptp_conf_dir = $::platform::ptpinstance::params::ptp_conf_dir
  $ptp_options_dir = $::platform::ptpinstance::params::ptp_options_dir

  if $enabled {
    $ptp_state = {
      'ensure' => 'running',
      'enable' => true,
      'ptp_conf_dir' => $ptp_conf_dir,
      'ptp_options_dir' => $ptp_options_dir
    }
  }

  if $runtime {
    # During runtime we set first_step_threshold to 0. This ensures that there are
    # no large time changes to a running host
    $phc2sys_cmd_opts = '-F 0'
  } else {
    $phc2sys_cmd_opts = ''
  }

  file {"${ptp_conf_dir}/ptpinstance":
    ensure =>  directory,
    mode   =>  '0755',
  }
  -> tidy { 'purge_conf':
    path    => "${ptp_conf_dir}/ptpinstance",
    matches => [ '[^clock]*.conf' ],
    recurse => true,
    rmdirs  => false
  }
  -> file{"${ptp_options_dir}/ptpinstance":
    ensure =>  directory,
    mode   =>  '0755',
  }
  -> tidy { 'purge_sysconf':
    path    => "${ptp_options_dir}/ptpinstance/",
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
  -> file { 'synce4l_service_instance':
    ensure  => file,
    path    => '/etc/systemd/system/synce4l@.service',
    mode    => '0644',
    content => template('platform/synce4l-instance.service.erb'),
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
  -> exec { 'stop-synce4l-instance':
    command => '/usr/bin/systemctl stop synce4l@*',
  }
  -> exec { 'disable-sycne4l-instance':
    command => '/usr/bin/systemctl disable synce4l@*',
    onlyif  => 'test -f /etc/systemd/system/synce4l@.service',
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
  -> exec { 'ptpinstance-systemctl-reset-failed-synce4l':
    command => '/usr/bin/systemctl reset-failed synce4l*',
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
  -> class { 'platform::ptpinstance::nic_clock': }
  -> exec {'Ensure collectd is restarted':
    command => '/usr/local/sbin/pmon-restart collectd'
  }
}

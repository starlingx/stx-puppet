define platform::ptpinstance::ptp_config_files(
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
  $device_parameters = '',
  $gnss_uart_disable = '',
  $external_source = '',
) {
  file { $_name:
    ensure  => file,
    notify  => Service["instance-${_name}"],
    path    => "${ptp_conf_dir}/ptpinstance/${service}-${_name}.conf",
    mode    => '0644',
    content => template('platform/ptpinstance.conf.erb'),
    require => File["${ptp_conf_dir}/ptpinstance"],
  }
  -> file { "${_name}-sysconfig":
    ensure  => file,
    notify  => Service["instance-${_name}"],
    path    => "${ptp_options_dir}/ptpinstance/${service}-instance-${_name}",
    mode    => '0644',
    content => template("platform/${service}-instance.erb"),
    require => File["${ptp_options_dir}/ptpinstance"],
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

define platform::ptpinstance::set_ptp4l_pmc_parameters(
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
  $device_parameters = '',
  $gnss_uart_disable = '',
  $external_source = '',
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

define platform::ptpinstance::nic_clock_handler (
  $ifname,
  $parameters,
  $port_names,
  $uuid,
  $base_port,
  $ptp_conf_dir,
) {
  exec { "${ifname}_heading":
    command  => "echo ifname [${name}] >> ${ptp_conf_dir}/ptpinstance/clock-conf.conf",
    require  => File['ensure_clock_conf_present'],
    provider => shell,
  }
  -> exec { "${ifname}_${base_port}_heading":
    command  => "echo base_port [${base_port}] >> ${ptp_conf_dir}/ptpinstance/clock-conf.conf",
    provider => shell,
  }
  $parameters.each |String $parm, String $value| {
    platform::ptpinstance::config_param { "${name}_${parm}_${value}":
      iface   => $name,
      param   => $parm,
      value   => $value,
      require => [Exec["${ifname}_heading"], Exec["${ifname}_${base_port}_heading"]],
    }
    -> exec { "${ifname}_${parm}_to_file":
      command  => "echo ${parm} ${value} >> ${ptp_conf_dir}/ptpinstance/clock-conf.conf",
      provider => shell,
    }
  }
}

define platform::ptpinstance::nic_clock_reset (
  $ifname,
  $parameters,
  $port_names,
  $uuid,
  $base_port,
) {
  $parameters.each |String $parm, String $value| {
    platform::ptpinstance::config_param { "${name}_${parm}_default":
      iface => $name,
      param => $parm,
      value => 'default',
    }
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

  file { "${ptp_conf_dir}/ptpinstance":
    ensure => directory,
    mode   => '0755',
  }
  -> tidy { 'purge_conf':
    path    => "${ptp_conf_dir}/ptpinstance",
    matches => ['[^clock]*.conf'],
    recurse => true,
    rmdirs  => false,
  }
  -> file { 'ensure_clock_conf_present':
    ensure  => present,
    path    => "${ptp_conf_dir}/ptpinstance/clock-conf.conf",
    mode    => '0644',
    require => File["${ptp_conf_dir}/ptpinstance"],
  }
  if $nic_clock_enabled {
    create_resources('platform::ptpinstance::nic_clock_handler', $nic_clock_config, { 'ptp_conf_dir' => $ptp_conf_dir })
    $iface_keys = keys($nic_clock_config)
    $iface_keys.each|Integer $index, String $iface_cfg| {
      if $index > 0 {
        # Defining an order for the instances that will be created with create_resources
        Platform::Ptpinstance::Nic_clock_handler[$iface_keys[$index - 1]] -> Platform::Ptpinstance::Nic_clock_handler[$iface_cfg]
      }
    }
  }
}

class platform::ptpinstance::nic_clock::nic_reset (
  $nic_clock_config = $platform::ptpinstance::nic_clock::nic_clock_config,
  $nic_clock_enabled = $platform::ptpinstance::nic_clock::nic_clock_enabled
) {
  $ptp_conf_dir = $::platform::ptpinstance::params::ptp_conf_dir
  $clock_conf_values = read_clock_conf("${ptp_conf_dir}/ptpinstance/clock-conf.conf")

  if $nic_clock_enabled {
    create_resources('platform::ptpinstance::nic_clock_reset', $clock_conf_values)
    $iface_keys = keys($clock_conf_values)
    $iface_keys.each|Integer $index, String $iface_cfg| {
      if $index > 0 {
        # Defining an order for the instances that will be created with create_resources
        Platform::Ptpinstance::Nic_clock_reset[$iface_keys[$index - 1]] -> Platform::Ptpinstance::Nic_clock_reset[$iface_cfg]
      }
    }
  }
  exec { 'clear_clock_conf_file':
    command => "echo \"\" > ${ptp_conf_dir}/ptpinstance/clock-conf.conf",
    onlyif  => "stat ${ptp_conf_dir}/ptpinstance/clock-conf.conf",
  }
}

define platform::ptpinstance::disable_e810_gnss_uart_interfaces (
  $_name,
  $global_parameters,
  $service,
  $gnss_uart_disable,
  $cmdline_opts = '',
  $device_parameters = '',
  $id = '',
  $interfaces = '',
  $pmc_gm_settings = '',
  $external_source = '',
) {
  $gnss_device = $global_parameters['ts2phc.nmea_serialport']

  if empty($gnss_device) {
    notice("ts2phc.nmea_serialport not set for ${_name}")
  }
  elsif $service == 'ts2phc' and $gnss_uart_disable {
    # These values were obtained from Intel's User Guide for the E810 NIC
    $uart1_cmd = '\xb5\x62\x06\x8a\x09\x00\x00\x05\x00\x00\x05\x00\x52\x10\x00\x05\x80'
    $uart2_cmd = '\xb5\x62\x06\x8a\x09\x00\x00\x05\x00\x00\x05\x00\x53\x10\x00\x06\x83'

    notice("Trying to disable UART devices for serial port ${gnss_device}")

    exec { "${_name}_disable_gnss_uart1":
      command => "echo -ne \"${uart1_cmd}\" > ${gnss_device}",
      timeout => 3,
      onlyif  => "/usr/bin/test -c ${gnss_device}",
    }
    exec { "${_name}_disable_gnss_uart2":
      command => "echo -ne \"${uart2_cmd}\" > ${gnss_device}",
      timeout => 3,
      onlyif  => "/usr/bin/test -c ${gnss_device}",
    }
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

    if $enabled {
      # Older E810 cards have unconnected UART interfaces enabled and this can cause noise
      # and GNNS errors. To avoid this we try to disable the UART interfaces during startup.
      create_resources('platform::ptpinstance::disable_e810_gnss_uart_interfaces', $config)
    }
  }

  file { "${ptp_options_dir}/ptpinstance":
    ensure => directory,
    mode   => '0755',
  }
  -> tidy { 'purge_sysconf':
    path    => "${ptp_options_dir}/ptpinstance/",
    matches => ['*-instance-*'],
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
    create_resources('platform::ptpinstance::ptp_config_files', $config, $ptp_state)
    create_resources('platform::ptpinstance::set_ptp4l_pmc_parameters', $config, $ptp_state)
  }

  exec { 'set-ice-gnss-thread-niceness':
  # The niceness value of -10 should match what is being set in affine-platform.sh
  command  => "renice -n -10 -p \$(ps -e -p 2 | grep \"ice-gnss-\" \
             | awk '{ printf \$1; printf \" \" }')",
  provider => shell,
  }
}

class platform::ptpinstance::runtime {
  class { 'platform::ptpinstance::nic_clock': }
  -> class { 'platform::ptpinstance': runtime => true }
  -> exec { 'Ensure collectd is restarted':
    command => '/usr/local/sbin/pmon-restart collectd'
  }
}

define platform::ptpinstance::net_tspll_cfg (
  $iface,
  $tspll_freq,
  $clk_src,
  $src_tmr_mode,
) {
  exec { "${iface}_tspll_cfg_${tspll_freq}_${clk_src}_${src_tmr_mode}":
    command  => "echo ${tspll_freq} ${clk_src} ${src_tmr_mode} > /sys/class/net/${iface}/device/tspll_cfg",
    provider => shell,
  }
}

define platform::ptpinstance::phy_synce (
  $iface,
  $enable,
  $pin,
) {
  exec { "${iface}_synce_${enable}_${pin}":
    command  => "echo ${enable} ${pin} > /sys/class/net/${iface}/device/phy/synce",
    provider => shell,
  }
}

define platform::ptpinstance::phy_tx_clk (
  $iface,
  $ref_clk,
) {
  exec { "${iface}_tx_clk_${ref_clk}":
    command  => "echo ${ref_clk} > /sys/class/net/${iface}/device/phy/tx_clk",
    provider => shell,
  }
}

define platform::ptpinstance::ptp_extts_enable (
  $iface,
  $enable,
) {
  exec { "${iface}_extts_enable_${enable}":
    command  => "PTPNAME=$(basename /sys/class/net/${iface}/device/ptp/ptp*);\
      CHANNEL=$(cat /sys/class/net/${iface}/device/ptp/\$PTP/pins/${pin} | awk '{print \$2}');\
      echo \$CHANNEL ${enable} > /sys/class/net/${iface}/device/ptp/\$PTP/extts_enable",
    provider => shell,
  }
}

define platform::ptpinstance::ptp_period (
  $iface,
  $start_time_s = 0,
  $start_time_ns = 0,
  $period_s = 0,
  $period_ns = 0,
) {
  exec { "${iface}_period_${start_time_s}_${start_time_ns}_${period_s}_${period_ns}}":
    command  => "PTP=$(basename /sys/class/net/${iface}/device/ptp/ptp*);\
      CHANNEL=$(cat /sys/class/net/${iface}/device/ptp/\$PTP/pins/${pin} | awk '{print \$2}');\
      echo \$CHANNEL ${start_time_s} ${start_time_ns} ${period_s} ${period_ns} > /sys/class/net/${iface}/device/ptp/\$PTP/period",
    provider => shell,
  }
}

define platform::ptpinstance::ptp_pin (
  $iface,
  $pin,
  $function,
) {
  exec { "${iface}_${pin}_${function}":
    command  => "PTP=$(basename /sys/class/net/${iface}/device/ptp/ptp*);\
      CHANNEL=$(cat /sys/class/net/${iface}/device/ptp/\$PTP/pins/${pin} | awk '{print \$2}');\
      echo ${function} \$CHANNEL > /sys/class/net/${iface}/device/ptp/\$PTP/pins/${pin}",
    provider => shell,
  }
}

define platform::ptpinstance::config_param (
  $iface,
  $param,
  $value,
) {
  $cmds = {
    'tspll_cfg' => {
      'resource' => 'platform::ptpinstance::net_tspll_cfg',
      'default'        => { 'iface' => $iface, 'tspll_freq' => 4, 'clk_src' => 0, 'src_tmr_mode' => 0 },
      'timeref_25'     => { 'iface' => $iface, 'tspll_freq' => 0, 'clk_src' => 1, 'src_tmr_mode' => 0 },
      'timeref_156.25' => { 'iface' => $iface, 'tspll_freq' => 4, 'clk_src' => 1, 'src_tmr_mode' => 0 },
    },
    'synce_rclka' => {
      'resource' => 'platform::ptpinstance::phy_synce',
      'default' => { 'iface' => $iface, 'enable' => 0, 'pin' => 0 },
      'enabled' => { 'iface' => $iface, 'enable' => 1, 'pin' => 0 },
    },
    'synce_rclkb' => {
      'resource' => 'platform::ptpinstance::phy_synce',
      'default' => { 'iface' => $iface, 'enable' => 0, 'pin' => 1 },
      'enabled' => { 'iface' => $iface, 'enable' => 1, 'pin' => 1 },
    },
    'tx_clk' => {
      'resource' => 'platform::ptpinstance::phy_tx_clk',
      'default' => { 'iface' => $iface, 'ref_clk' => 0 },
      'enabled' => { 'iface' => $iface, 'ref_clk' => 1 },
    },
    'extts_enable' => {
      'resource' => 'platform::ptpinstance::ptp_extts_enable',
      'default' => { 'iface' => $iface, 'enable' => 0 },
      'enabled' => { 'iface' => $iface, 'enable' => 1 },
    },
    'period' => {
      'resource' => 'platform::ptpinstance::ptp_period',
      'default'  => { 'iface' => $iface, 'start_time_s' => 0, 'start_time_ns' => 0, 'period_s' => 0, 'period_ns' => 0 },
      'out_1pps' => { 'iface' => $iface, 'start_time_s' => 0, 'start_time_ns' => 0, 'period_s' => 1, 'period_ns' => 0 },
    },
    'sdp0' => {
      'resource' => 'platform::ptpinstance::ptp_pin',
      'default' => { 'iface' => $iface, 'pin' => 'SDP0', 'function' => 0 },
      'output'  => { 'iface' => $iface, 'pin' => 'SDP0', 'function' => 2 },
    },
    'sdp1' => {
      'resource' => 'platform::ptpinstance::ptp_pin',
      'default' => { 'iface' => $iface, 'pin' => 'SDP1', 'function' => 0 },
      'input'   => { 'iface' => $iface, 'pin' => 'SDP1', 'function' => 1 },
    },
    'sdp2' => {
      'resource' => 'platform::ptpinstance::ptp_pin',
      'default' => { 'iface' => $iface, 'pin' => 'SDP2', 'function' => 0 },
      'output'  => { 'iface' => $iface, 'pin' => 'SDP2', 'function' => 2 },
    },
    'sdp3' => {
      'resource' => 'platform::ptpinstance::ptp_pin',
      'default' => { 'iface' => $iface, 'pin' => 'SDP3', 'function' => 0 },
      'input'   => { 'iface' => $iface, 'pin' => 'SDP3', 'function' => 1 },
    },
    'sma1' => {
      'resource' => 'platform::ptpinstance::ptp_pin',
      'default' => { 'iface' => $iface, 'pin' => 'SMA1', 'function' => 0 },
      'input'   => { 'iface' => $iface, 'pin' => 'SMA1', 'function' => 1 },
      'output'  => { 'iface' => $iface, 'pin' => 'SMA1', 'function' => 2 },
    },
    'sma2' => {
      'resource' => 'platform::ptpinstance::ptp_pin',
      'default' => { 'iface' => $iface, 'pin' => 'SMA2', 'function' => 0 },
      'input'   => { 'iface' => $iface, 'pin' => 'SMA2', 'function' => 1 },
      'output'  => { 'iface' => $iface, 'pin' => 'SMA2', 'function' => 2 },
    },
    'u.fl1' => {
      'resource' => 'platform::ptpinstance::ptp_pin',
      'default' => { 'iface' => $iface, 'pin' => 'U.FL1', 'function' => 0 },
      'output'  => { 'iface' => $iface, 'pin' => 'U.FL1', 'function' => 2 },
    },
    'u.fl2' => {
      'resource' => 'platform::ptpinstance::ptp_pin',
      'default' => { 'iface' => $iface, 'pin' => 'U.FL2', 'function' => 0 },
      'input'   => { 'iface' => $iface, 'pin' => 'U.FL2', 'function' => 1 },
    },
  }

  if !$cmds[$param] {
    notice("Skipped invalid clock parameter: ${param}.")
  } elsif !$cmds[$param][$value] {
    notice("Skipped invalid clock parameter value: ${param}: ${value}.")
  } else {
    create_resources($cmds[$param]['resource'], { "${iface}_${param}_${value}" => $cmds[$param][$value] })
  }
}

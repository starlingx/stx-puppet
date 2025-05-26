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
      iface     => $name,
      base_port => $base_port,
      param     => $parm,
      value     => $value,
      require   => [Exec["${ifname}_heading"], Exec["${ifname}_${base_port}_heading"]],
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
      iface     => $name,
      base_port => $base_port,
      param     => $parm,
      value     => 'default',
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

  if $nic_clock_enabled and find_file("${ptp_conf_dir}/ptpinstance/clock-conf.conf") {
    $clock_conf_values = read_clock_conf("${ptp_conf_dir}/ptpinstance/clock-conf.conf")
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
) {
  unless defined(Exec["${iface}_tspll_cfg_${tspll_freq}_${clk_src}"]) {
    exec { "${iface}_tspll_cfg_${tspll_freq}_${clk_src}":
      command  => "echo ${tspll_freq} ${clk_src} > /sys/class/net/${iface}/device/tspll_cfg",
      provider => shell,
    }
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
  unless defined(Exec["${iface}_tx_clk_${ref_clk}"]) {
    exec { "${iface}_tx_clk_${ref_clk}":
      command  => "echo ${ref_clk} > /sys/class/net/${iface}/device/phy/tx_clk",
      provider => shell,
    }
  }
}

define platform::ptpinstance::ptp_extts_enable (
  $iface,
  $pin,
  $enable,
  $channel,
) {
  exec { "${iface}_${channel}_extts_enable_${enable}":
    command  => "PTP=\$(basename /sys/class/net/${iface}/device/ptp/ptp*);\
      echo ${channel} ${enable} > /sys/class/net/${iface}/device/ptp/\$PTP/extts_enable",
    provider => shell,
  }

  # Function 1 is input and function 0 is default, we need to know this to
  # identify if this is the default operation or if we are applying a new value.
  $function = $enable ? {
    1 => 1,
    0 => 0,
  }

  if $function != 0 {
    # When we are setting a new value to the extts config, the pin
    # input function needs to be set first, this dependecy ensures that.
    Exec["${iface}_${pin}_${function}"] -> Exec["${iface}_${channel}_extts_enable_${enable}"]
  } else {
    # When we are setting the default value to the extts config, the pin
    # input function needs to be set after that, this dependecy ensures that.
    Exec["${iface}_${channel}_extts_enable_${enable}"] -> Exec["${iface}_${pin}_${function}"]
  }
}

define platform::ptpinstance::ptp_period (
  $iface,
  $pin,
  $start_time_s,
  $start_time_ns,
  $period_s,
  $period_ns,
  $channel,
) {
  exec { "${iface}_period_${channel}_${start_time_s}_${start_time_ns}_${period_s}_${period_ns}":
    command  => "PTP=\$(basename /sys/class/net/${iface}/device/ptp/ptp*);\
      echo ${channel} ${start_time_s} ${start_time_ns} ${period_s} ${period_ns} > /sys/class/net/${iface}/device/ptp/\$PTP/period",
    provider => shell,
  }

  # Function 2 is output and function 0 is default, we need to know this to
  # identify if this is the default operation or if we are applying a new value.
  $function = ($period_s != 0 or $period_ns != 0) ? {
    true  => 2,
    false => 0,
  }

  if $function != 0 {
    # When we are setting a new value to the period config, the pin
    # output function needs to be set first, this dependecy ensures that.
    Exec["${iface}_${pin}_${function}"] -> Exec["${iface}_period_${channel}_${start_time_s}_${start_time_ns}_${period_s}_${period_ns}"]
  } else {
    # When we are setting the default value to the period config, the pin
    # output function needs to be set after that, this dependecy ensures that.
    Exec["${iface}_period_${channel}_${start_time_s}_${start_time_ns}_${period_s}_${period_ns}"] -> Exec["${iface}_${pin}_${function}"]
  }
}

define platform::ptpinstance::external_ptp_pin (
  $iface,
  $pin,
  $function,
) {
  exec { "${iface}_${pin}_${function}":
    command  => "echo ${function} > /sys/class/net/${iface}/device/${pin}",
    provider => shell,
  }
}

define platform::ptpinstance::ptp_pin (
  $iface,
  $pin,
  $function,
  $channel,
) {
  exec { "${iface}_${pin}_${function}":
    command  => "PTP=$(basename /sys/class/net/${iface}/device/ptp/ptp*);\
      echo ${function} ${channel} > /sys/class/net/${iface}/device/ptp/\$PTP/pins/${pin}",
    provider => shell,
  }
}

define platform::ptpinstance::config_param (
  $iface,
  $base_port,
  $param,
  $value,
) {
  $cmds = {
    'tspll_cfg' => {
      'resource'       => 'platform::ptpinstance::net_tspll_cfg',
      'default'        => { 'iface' => $base_port, 'tspll_freq' => 4, 'clk_src' => 0 },
      'osc_25'         => { 'iface' => $base_port, 'tspll_freq' => 0, 'clk_src' => 0 },
      'osc_122.88'     => { 'iface' => $base_port, 'tspll_freq' => 1, 'clk_src' => 0 },
      'osc_125'        => { 'iface' => $base_port, 'tspll_freq' => 2, 'clk_src' => 0 },
      'osc_153.6'      => { 'iface' => $base_port, 'tspll_freq' => 3, 'clk_src' => 0 },
      'osc_156.25'     => { 'iface' => $base_port, 'tspll_freq' => 4, 'clk_src' => 0 },
      'osc_245.76'     => { 'iface' => $base_port, 'tspll_freq' => 5, 'clk_src' => 0 },
      'timeref_25'     => { 'iface' => $base_port, 'tspll_freq' => 0, 'clk_src' => 1 },
      'timeref_122.88' => { 'iface' => $base_port, 'tspll_freq' => 1, 'clk_src' => 1 },
      'timeref_125'    => { 'iface' => $base_port, 'tspll_freq' => 2, 'clk_src' => 1 },
      'timeref_153.6'  => { 'iface' => $base_port, 'tspll_freq' => 3, 'clk_src' => 1 },
      'timeref_156.25' => { 'iface' => $base_port, 'tspll_freq' => 4, 'clk_src' => 1 },
      'timeref_245.76' => { 'iface' => $base_port, 'tspll_freq' => 5, 'clk_src' => 1 },
    },
    'synce_rclka' => {
      'resource' => 'platform::ptpinstance::phy_synce',
      'default'  => { 'iface' => $iface, 'enable' => 0, 'pin' => 0 },
      'enabled'  => { 'iface' => $iface, 'enable' => 1, 'pin' => 0 },
    },
    'synce_rclkb' => {
      'resource' => 'platform::ptpinstance::phy_synce',
      'default'  => { 'iface' => $iface, 'enable' => 0, 'pin' => 1 },
      'enabled'  => { 'iface' => $iface, 'enable' => 1, 'pin' => 1 },
    },
    'tx_clk' => {
      'resource' => 'platform::ptpinstance::phy_tx_clk',
      'default' => { 'iface' => $iface, 'ref_clk' => 0 },
      'enet'    => { 'iface' => $iface, 'ref_clk' => 0 },
      'synce'   => { 'iface' => $iface, 'ref_clk' => 1 },
      'eref0'   => { 'iface' => $iface, 'ref_clk' => 2 },
    },
    'extts_sdp1' => {
      'resource' => 'platform::ptpinstance::ptp_extts_enable',
      'default'  => { 'iface' => $base_port, 'pin' => 'SDP1', 'channel' => 1, 'enable' => 0},
      'enabled'  => { 'iface' => $base_port, 'pin' => 'SDP1', 'channel' => 1, 'enable' => 1},
    },
    'extts_sdp3' => {
      'resource' => 'platform::ptpinstance::ptp_extts_enable',
      'default'  => { 'iface' => $base_port, 'pin' => 'SDP3', 'channel' => 2, 'enable' => 0},
      'enabled'  => { 'iface' => $base_port, 'pin' => 'SDP3', 'channel' => 2, 'enable' => 1},
    },
    'extts_sdp21' => {
      'resource' => 'platform::ptpinstance::ptp_extts_enable',
      'default'  => { 'iface' => $base_port, 'pin' => 'SDP21', 'channel' => 1, 'enable' => 0},
      'enabled'  => { 'iface' => $base_port, 'pin' => 'SDP21', 'channel' => 1, 'enable' => 1},
    },
    'extts_sdp23' => {
      'resource' => 'platform::ptpinstance::ptp_extts_enable',
      'default'  => { 'iface' => $base_port, 'pin' => 'SDP23', 'channel' => 2, 'enable' => 0},
      'enabled'  => { 'iface' => $base_port, 'pin' => 'SDP23', 'channel' => 2, 'enable' => 1},
    },
    'period_sdp0' => {
      'resource' => 'platform::ptpinstance::ptp_period',
      'default'  => { 'iface' => $base_port, 'pin' => 'SDP0', 'channel' => 1,
                      'start_time_s' => 0, 'start_time_ns' => 0, 'period_s' => 0, 'period_ns' => 0 },
      '1pps'     => { 'iface' => $base_port, 'pin' => 'SDP0', 'channel' => 1,
                      'start_time_s' => 0, 'start_time_ns' => 0, 'period_s' => 1, 'period_ns' => 0 },
      '10mhz'    => { 'iface' => $base_port, 'pin' => 'SDP0', 'channel' => 1,
                      'start_time_s' => 0, 'start_time_ns' => 0, 'period_s' => 0, 'period_ns' => 100 },
      '1khz'     => { 'iface' => $base_port, 'pin' => 'SDP0', 'channel' => 1,
                      'start_time_s' => 0, 'start_time_ns' => 0, 'period_s' => 0, 'period_ns' => 1000000 },
    },
    'period_sdp2' => {
      'resource' => 'platform::ptpinstance::ptp_period',
      'default'  => { 'iface' => $base_port, 'pin' => 'SDP2', 'channel' => 2,
                      'start_time_s' => 0, 'start_time_ns' => 0, 'period_s' => 0, 'period_ns' => 0 },
      '1pps'     => { 'iface' => $base_port, 'pin' => 'SDP2', 'channel' => 2,
                      'start_time_s' => 0, 'start_time_ns' => 0, 'period_s' => 1, 'period_ns' => 0 },
      '10mhz'    => { 'iface' => $base_port, 'pin' => 'SDP2', 'channel' => 2,
                      'start_time_s' => 0, 'start_time_ns' => 0, 'period_s' => 0, 'period_ns' => 100 },
      '1khz'     => { 'iface' => $base_port, 'pin' => 'SDP2', 'channel' => 2,
                      'start_time_s' => 0, 'start_time_ns' => 0, 'period_s' => 0, 'period_ns'=> 1000000 },
    },
    'period_sdp20' => {
      'resource' => 'platform::ptpinstance::ptp_period',
      'default'  => { 'iface' => $base_port, 'pin' => 'SDP20', 'channel' => 1,
                      'start_time_s' => 0, 'start_time_ns' => 0, 'period_s' => 0, 'period_ns' => 0 },
      '1pps'     => { 'iface' => $base_port, 'pin' => 'SDP20', 'channel' => 1,
                      'start_time_s' => 0, 'start_time_ns' => 0, 'period_s' => 1, 'period_ns' => 0 },
      '10mhz'    => { 'iface' => $base_port, 'pin' => 'SDP20', 'channel' => 1,
                      'start_time_s' => 0, 'start_time_ns' => 0, 'period_s' => 0, 'period_ns' => 100 },
      '1khz'     => { 'iface' => $base_port, 'pin' => 'SDP20', 'channel' => 1,
                      'start_time_s' => 0, 'start_time_ns' => 0, 'period_s' => 0, 'period_ns' => 1000000 },
    },
    'period_sdp22' => {
      'resource' => 'platform::ptpinstance::ptp_period',
      'default'  => { 'iface' => $base_port, 'pin' => 'SDP22', 'channel' => 2,
                      'start_time_s' => 0, 'start_time_ns' => 0, 'period_s' => 0, 'period_ns' => 0 },
      '1pps'     => { 'iface' => $base_port, 'pin' => 'SDP22', 'channel' => 2,
                      'start_time_s' => 0, 'start_time_ns' => 0, 'period_s' => 1, 'period_ns' => 0 },
      '10mhz'    => { 'iface' => $base_port, 'pin' => 'SDP22', 'channel' => 2,
                      'start_time_s' => 0, 'start_time_ns' => 0, 'period_s' => 0, 'period_ns' => 100 },
      '1khz'     => { 'iface' => $base_port, 'pin' => 'SDP22', 'channel' => 2,
                      'start_time_s' => 0, 'start_time_ns' => 0, 'period_s' => 0, 'period_ns' => 1000000 },
    },
    'sdp0' => {
      'resource' => 'platform::ptpinstance::ptp_pin',
      'default'  => { 'iface' => $base_port, 'pin' => 'SDP0', 'function' => 0, 'channel' => 1 },
      'output'   => { 'iface' => $base_port, 'pin' => 'SDP0', 'function' => 2, 'channel' => 1 },
    },
    'sdp1' => {
      'resource' => 'platform::ptpinstance::ptp_pin',
      'default'  => { 'iface' => $base_port, 'pin' => 'SDP1', 'function' => 0, 'channel' => 1 },
      'input'    => { 'iface' => $base_port, 'pin' => 'SDP1', 'function' => 1, 'channel' => 1 },
    },
    'sdp2' => {
      'resource' => 'platform::ptpinstance::ptp_pin',
      'default'  => { 'iface' => $base_port, 'pin' => 'SDP2', 'function' => 0, 'channel' => 2 },
      'output'   => { 'iface' => $base_port, 'pin' => 'SDP2', 'function' => 2, 'channel' => 2 },
    },
    'sdp3' => {
      'resource' => 'platform::ptpinstance::ptp_pin',
      'default' => { 'iface' => $base_port, 'pin' => 'SDP3', 'function' => 0, 'channel' => 2 },
      'input'   => { 'iface' => $base_port, 'pin' => 'SDP3', 'function' => 1, 'channel' => 2 },
    },
    'sdp20' => {
      'resource' => 'platform::ptpinstance::ptp_pin',
      'default'  => { 'iface' => $base_port, 'pin' => 'SDP20', 'function' => 0, 'channel' => 1 },
      'output'   => { 'iface' => $base_port, 'pin' => 'SDP20', 'function' => 2, 'channel' => 1 },
    },
    'sdp21' => {
      'resource' => 'platform::ptpinstance::ptp_pin',
      'default'  => { 'iface' => $base_port, 'pin' => 'SDP21', 'function' => 0, 'channel' => 1 },
      'input'    => { 'iface' => $base_port, 'pin' => 'SDP21', 'function' => 1, 'channel' => 1 },
    },
    'sdp22' => {
      'resource' => 'platform::ptpinstance::ptp_pin',
      'default'  => { 'iface' => $base_port, 'pin' => 'SDP22', 'function' => 0, 'channel' => 2 },
      'output'   => { 'iface' => $base_port, 'pin' => 'SDP22', 'function' => 2, 'channel' => 2 },
    },
    'sdp23' => {
      'resource' => 'platform::ptpinstance::ptp_pin',
      'default' => { 'iface' => $base_port, 'pin' => 'SDP23', 'function' => 0, 'channel' => 2 },
      'input'   => { 'iface' => $base_port, 'pin' => 'SDP23', 'function' => 1, 'channel' => 2 },
    },
    'sma1' => {
      'resource' => 'platform::ptpinstance::external_ptp_pin',
      'default' => { 'iface' => $base_port, 'pin' => 'SMA1', 'function' => 0 },
      'input'   => { 'iface' => $base_port, 'pin' => 'SMA1', 'function' => 1 },
      'output'  => { 'iface' => $base_port, 'pin' => 'SMA1', 'function' => 2 },
    },
    'sma2' => {
      'resource' => 'platform::ptpinstance::external_ptp_pin',
      'default' => { 'iface' => $base_port, 'pin' => 'SMA2', 'function' => 0 },
      'input'   => { 'iface' => $base_port, 'pin' => 'SMA2', 'function' => 1 },
      'output'  => { 'iface' => $base_port, 'pin' => 'SMA2', 'function' => 2 },
    },
    'u.fl1' => {
      'resource' => 'platform::ptpinstance::external_ptp_pin',
      'default' => { 'iface' => $base_port, 'pin' => 'U.FL1', 'function' => 0 },
      'output'  => { 'iface' => $base_port, 'pin' => 'U.FL1', 'function' => 2 },
    },
    'u.fl2' => {
      'resource' => 'platform::ptpinstance::external_ptp_pin',
      'default' => { 'iface' => $base_port, 'pin' => 'U.FL2', 'function' => 0 },
      'input'   => { 'iface' => $base_port, 'pin' => 'U.FL2', 'function' => 1 },
    },
  }

  if $cmds[$param][$value] {
    $final_value = $cmds[$param][$value]
  } elsif ($param in ['period_sdp0', 'period_sdp2', 'period_sdp20', 'period_sdp22']) and !$cmds[$param][$value] {
    # This logic deals with periods set in nanoseconds, we don't have a fixed argument to
    # those so this logic makes sure that the value is converted to seconds if needed.
    # The minimum value is 100ns, and the maximum is 4s.
    $period_s  = Integer($value) / 1000000000
    $period_ns = Integer($value) % 1000000000
    $channel = $param ? {
      'period_sdp0'  => 1,
      'period_sdp2'  => 2,
      'period_sdp20' => 1,
      'period_sdp22' => 2,
    }
    $final_value = {
      'iface'         => $iface,
      'pin'           => $pin,
      'channel'       => $channel,
      'start_time_s'  => 0,
      'start_time_ns' => 0,
      'period_s'      => $period_s,
      'period_ns'     => $period_ns,
    }
  } elsif !$cmds[$param][$value] {
    $final_value = undef
  }

  if !$cmds[$param] {
    notice("Skipped invalid clock parameter: ${param}.")
  } elsif $final_value == undef {
    notice("Skipped invalid clock parameter value: ${param}: ${value}.")
  } else {
    create_resources($cmds[$param]['resource'], { "${iface}_${param}_${value}" => $final_value })
  }
}

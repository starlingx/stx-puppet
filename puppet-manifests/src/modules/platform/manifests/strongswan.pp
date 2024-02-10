class platform::strongswan::params (
  $aikgen = {},
  $attest = {},
  $charon = {},
  $charon_mm = {},
  $charon_systemd = {},
  $imv_policy_manager = {},
  $libimcs = {},
  $libtls = {},
  $libtnccs = {},
  $manager = {},
  $medcli = {},
  $medsrv = {},
  $pki = {},
  $pool = {},
  $pt_tls_client = {},
  $sec_updater = {},
  $sw_collector = {},
  $starter = {},
  $swanctl = {},
  $authorities = {},
  $connections = {},
  $secrets = {},
  $pools = {},
  $strongswan_include = 'strongswan.d/*.conf',
  $charon_logging = {},
  $strongswan = {},
) {
}

class platform::strongswan::config
  inherits ::platform::strongswan::params {

  $strongswan_override_dir = '/etc/systemd/system/strongswan-starter.service.d'
  $initial_config_file = find_file('/etc/platform/.initial_config_complete')

  # Restart charon
  if $initial_config_file {
    $ipsec_restart_cmd = '/usr/local/sbin/pmon-restart charon'
  } else {
    $ipsec_restart_cmd =  '/usr/bin/systemctl restart ipsec'
  }

  # Create systemd override directory
  file { $strongswan_override_dir:
    ensure => 'directory',
    owner  => 'root',
    group  => 'root',
    mode   => '0755',
  }

  # Add strongswan-starter service override
  -> file { "${strongswan_override_dir}/strongswan-stx-override.conf":
    content => template('platform/strongswan.systemd.override.conf.erb'),
    owner   => 'root',
    group   => 'root',
    mode    => '0644',
  }

  # Reload systemd
  -> exec { 'perform systemctl daemon reload for strongswan-starter override':
    command   => '/usr/bin/systemctl daemon-reload',
    logoutput => true,
  }

  # set strongswan-starter monitored by pmond
  -> file { '/etc/pmon.d/strongswan-starter.conf':
    ensure  => file,
    content => template('platform/strongswan-starter-pmond-conf.erb'),
    owner   => 'root',
    group   => 'root',
    mode    => '0644',
  }

  # Add charon log rotate configuration
  -> file { '/etc/logrotate.d/charon.conf':
    ensure  => present,
    content => template('platform/charon-logrotate.erb'),
    owner   => 'root',
    group   => 'root',
    mode    => '0644',
  }

  # Update strongswan configuration
  -> class { 'strongswan':
    charon             => $::platform::strongswan::params::strongswan,
    strongswan_include => $strongswan_include,
  }

  # Update charon_logging configuration
  -> class { '::strongswan::charon_logging':
    charon_logging => $::platform::strongswan::params::charon_logging,
  }

  # Update charon configuration
  -> class { '::strongswan::charon':
    charon_options => $::platform::strongswan::params::charon,
  }

  # Update swanctl configuration
  -> class { '::strongswan::swanctl':
    connections => $::platform::strongswan::params::swanctl,
  }

  # Restart charon
  -> exec { 'Restart charon to take updated configs':
    command => $ipsec_restart_cmd,
  }
}

class platform::strongswan
  inherits ::platform::strongswan::params {

  include ::platform::strongswan::config
}

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
  $swanctl_active = {},
  $authorities = {},
  $connections = {},
  $secrets = {},
  $pools = {},
  $strongswan_include = 'strongswan.d/*.conf',
  $charon_logging = {},
  $strongswan = {},
  $is_active_controller = false,
) {
}

class platform::strongswan::swanctl_config (
  $connections = {},
  $connections_active = {},
  $is_active_controller = undef,
) {
  file { '/etc/swanctl/swanctl.conf':
    owner   => 'root',
    mode    => '0600',
    content => strongswan::hash_to_strongswan_config({
        connections => $connections,
    }),
  }

  # If connections_active is not empty, the node is a controller.
  # For controller node, the swanctl.conf will be a symlink to
  # one of swanctl_active.conf and swanctl_standby.conf, depending
  # on their role (active or standby) at the time it is configed.
  # During swact, the symlink will be updated accordingly.
  if !empty($connections_active) {
    $swanctl_dir='/etc/swanctl'
    $swanctl_current_conf="${swanctl_dir}/swanctl.conf"
    $swanctl_active_conf="${swanctl_dir}/swanctl_active.conf"
    $swanctl_standby_conf="${swanctl_dir}/swanctl_standby.conf"

    file { $swanctl_active_conf:
      owner   => 'root',
      mode    => '0600',
      content => strongswan::hash_to_strongswan_config({
          connections => $connections_active,
      }),
    }

    # Symlink swanctl.conf based on the role of the controller
    if $is_active_controller {
      $swanctl_config=$swanctl_active_conf
    } else {
      $swanctl_config=$swanctl_standby_conf
    }

    exec { "Move ${swanctl_current_conf} to ${swanctl_standby_conf}":
      command => "/usr/bin/mv ${swanctl_current_conf} ${swanctl_standby_conf}",
      require => [
        File[$swanctl_current_conf],
        File[$swanctl_active_conf],
      ],
    }
    -> exec { "Symlink ${swanctl_current_conf}":
      command => "/usr/bin/ln -sf ${swanctl_config} ${swanctl_current_conf}",
    }
  }
}

class platform::strongswan::config
  inherits ::platform::strongswan::params {

  $strongswan_override_dir = '/etc/systemd/system/strongswan-starter.service.d'
  $pmon_config_file = '/etc/pmon.d/strongswan-starter.conf'

  # Restart charon
  if (find_file($pmon_config_file)) {
    $ipsec_restart_cmd = '/usr/local/sbin/pmon-restart charon'
  } else {
    $ipsec_restart_cmd = '/usr/bin/systemctl restart ipsec'
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
  -> class { '::platform::strongswan::swanctl_config':
    connections          => $::platform::strongswan::params::swanctl,
    connections_active   => $::platform::strongswan::params::swanctl_active,
    is_active_controller => $::platform::strongswan::params::is_active_controller,
  }

  # Restart charon
  -> exec { 'Restart charon to take updated configs':
    command => $ipsec_restart_cmd,
  }

  # Generate pmon configuration file in /tmp directory.
  # The pmon config file is generated first in /tmp directory, then
  # moved to /etc/pmon.d. This is to avoid the issue where the puppet
  # generated file some times doesn't trigger an inode notification on
  # time for pmon to detect and register charon process for monitoring.
  -> file { '/tmp/strongswan-starter.conf':
    ensure  => file,
    content => template('platform/strongswan-starter-pmond-conf.erb'),
    owner   => 'root',
    group   => 'root',
    mode    => '0644',
  }
  # Move the pmon config file to /etc/pmon.d
  -> exec { 'Move pmon config file to its location':
    command => "/usr/bin/mv /tmp/strongswan-starter.conf ${pmon_config_file}",
  }

  # Run ipsec-cert-renew.sh daily
  cron { 'ipsec-cert-renew':
    ensure      => 'present',
    command     => '/usr/bin/ipsec-cert-renew.sh',
    environment => 'PATH=/bin:/usr/bin:/usr/sbin',
    minute      => '20',
    hour        => '*/24',
    user        => 'root',
  }
}

class platform::strongswan::apparmor {
  file { '/etc/apparmor.d/local/usr.sbin.swanctl':
    ensure  => present,
    mode    => '0644',
    content => template('platform/usr.sbin.swanctl.erb'),
    notify  => Exec['reload-apparmor-swanctl-profile'],
  }
  exec {'reload-apparmor-swanctl-profile':
    command => '/usr/sbin/apparmor_parser -vTr /etc/apparmor.d/usr.sbin.swanctl',
    onlyif  => 'cat /sys/module/apparmor/parameters/enabled | grep -q "Y"',
  }

  file { '/etc/apparmor.d/local/usr.lib.ipsec.charon':
    ensure  => present,
    mode    => '0644',
    content => template('platform/usr.lib.ipsec.charon.erb'),
    notify  => Exec['reload-apparmor-ipsec-profile'],
  }
  exec {'reload-apparmor-ipsec-profile':
    command => '/usr/sbin/apparmor_parser -vTr /etc/apparmor.d/usr.lib.ipsec.charon',
    onlyif  => 'cat /sys/module/apparmor/parameters/enabled | grep -q "Y"',
  }
}

class platform::strongswan
  inherits ::platform::strongswan::params {

  include ::platform::strongswan::config
}

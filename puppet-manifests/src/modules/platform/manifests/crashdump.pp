class platform::crashdump::params (
  $max_size = '5Gi',
  $max_files = '4',
  $max_used = 'unlimited',
  $min_available = 'default',
) { }

class platform::crashdump
  inherits ::platform::crashdump::params {

    file { '/etc/default/crash-dump-manager':
      ensure  => 'present',
      replace => true,
      owner   => 'root',
      group   => 'root',
      mode    => '0644',
      content => template('platform/crash-dump-manager.erb'),
    }
  }

class platform::crashdump::reload {
  # Restart systemd configuration
  exec { 'systemd-reload-daemon':
    command => '/usr/bin/systemctl daemon-reload',
  }
  # Restart crash-dump-manager
  -> exec { 'restart crash-dump-manager':
    command => '/usr/bin/systemctl restart crash-dump-manager',
  }
}

class platform::crashdump::runtime {
  include ::platform::crashdump

  class {'::platform::crashdump::reload':
    stage => post
  }
}

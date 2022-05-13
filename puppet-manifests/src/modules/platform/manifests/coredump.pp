class platform::coredump::params (
  $process_size_max = '2G',
  $external_size_max = '2G',
  $max_use = '',
  $keep_free = '1G',
) { }

class platform::coredump
  inherits ::platform::coredump::params {

    file { '/etc/systemd/coredump.conf.d/coredump.conf':
      ensure  => 'present',
      replace => true,
      content => template('platform/coredump.conf.erb'),
    }
  }

class platform::coredump::reload {
  exec {'restart-coredump-service':
    command => 'sysctl -p /etc/sysctl.d/50-coredump.conf'
  }
}

class platform::coredump::runtime {
  include ::platform::coredump

  class {'::platform::coredump::reload':
    stage => post
  }
}

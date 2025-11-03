class platform::lldp::params(
  $tx_interval = 30,
  $tx_hold = 4,
  $options = []
) {}


class platform::lldp
  inherits ::platform::lldp::params {
  include ::platform::params

  $hostname = $::platform::params::hostname
  $system = $::platform::params::system_name
  $version = $::platform::params::software_version
  $lldpd_override_dir = '/etc/systemd/system/lldpd.service.d'


  # override the configuration of
  file { $lldpd_override_dir:
    ensure => 'directory',
    owner  => 'root',
    group  => 'root',
    mode   => '0755',
  }
  -> file { "${lldpd_override_dir}/lldp-override.conf":
    ensure  => 'present',
    owner   => 'root',
    group   => 'root',
    mode    => '0644',
    content => template('platform/lldp-override.conf.erb'),
  }

  file { '/etc/lldpd.conf':
      ensure  => 'present',
      replace => true,
      content => template('platform/lldp.conf.erb'),
      notify  => Service['lldpd'],
  }

  file { '/etc/default/lldpd':
      ensure  => 'present',
      replace => true,
      content => template('platform/lldpd.default.erb'),
      notify  => Service['lldpd'],
  }

  service { 'lldpd':
    ensure     => 'running',
    enable     => true,
    hasrestart => true,
  }
}

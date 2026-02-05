class platform::ntp::apparmor {
  exec { 'apparmor-update-ntpd':
    command => "sed -i '/\\/etc\\/ntp.conf r,/a\\ \\ \\/etc\\/ntp_initial.conf r,' /etc/apparmor.d/usr.sbin.ntpd",
    unless  => "grep -q '/etc/ntp_initial.conf r,' /etc/apparmor.d/usr.sbin.ntpd",
    notify  => Exec['reload-apparmor-ntp-profile'],
  }

  exec { 'reload-apparmor-ntp-profile':
    command => '/usr/sbin/apparmor_parser -vTr /etc/apparmor.d/usr.sbin.ntpd',
    onlyif  => 'cat /sys/module/apparmor/parameters/enabled | grep -q "Y"',
  }
}
class platform::ntp (
  $ntpdate_timeout,
  $servers = [],
  $enabled = true,
)
{
  include platform::ntp::apparmor
  # Setting ntp service name
  $ntp_service_name = 'ntp'
  $ntp_pmon_conf_template = 'platform/ntp_debian.pmon.conf.erb'

  if $enabled {
    $pmon_ensure = 'link'
  } else {
    $pmon_ensure = 'absent'
  }

  File['ntp_config']
  -> Class['platform::ntp::apparmor']
  -> File['ntp_config_initial']
  -> file { 'ntp_pmon_config':
    ensure  => file,
    path    => '/etc/ntp.pmon.conf',
    mode    => '0644',
    content => template($ntp_pmon_conf_template),
  }
  -> exec { 'systemd-daemon-reload':
    command => '/usr/bin/systemctl daemon-reload',
  }
  -> exec { "stop-${ntp_service_name}":
    command => "/usr/bin/systemctl stop ${ntp_service_name}.service",
    returns => [ 0, 1 ],
  }
  -> file { 'ntp_pmon_link':
    ensure => $pmon_ensure,
    path   => "/etc/pmon.d/${ntp_service_name}.conf",
    target => '/etc/ntp.pmon.conf',
    owner  => 'root',
    group  => 'root',
    mode   => '0600',
  }

  if $enabled {
    exec { "enable-${ntp_service_name}":
      require => File['ntp_pmon_link'],
      command => "/usr/bin/systemctl enable ${ntp_service_name}.service",
    }
    -> exec { 'ntp-initial-config':
      command => "timeout ${ntpdate_timeout} /usr/sbin/ntpd -g -q -n -c /etc/ntp_initial.conf && /usr/sbin/hwclock --systohc",
      returns => [ 0, 1, 124 ],
      onlyif  => "test ! -f /etc/platform/simplex || grep -q '^server' /etc/ntp.conf",
    }
    -> service { $ntp_service_name:
      ensure     => 'running',
      enable     => true,
      name       => $ntp_service_name,
      hasstatus  => true,
      hasrestart => true,
    }

    if $::personality == 'controller' {
      Class['::platform::dns']
      -> Exec["enable-${ntp_service_name}"]
    } else {
      Anchor['platform::networking']
      -> Exec["enable-${ntp_service_name}"]
    }

  } else {
    exec { "disable-${ntp_service_name}":
      require => File['ntp_pmon_link'],
      command => "/usr/bin/systemctl disable ${ntp_service_name}.service",
    }
  }
}

class platform::ntp::server {

  if $::personality == 'controller' {
    include ::platform::ntp

    include ::platform::params
    $peer_server = $::platform::params::mate_hostname
    $system_mode = $::platform::params::system_mode

    file { 'ntp_config':
      ensure  => file,
      path    => '/etc/ntp.conf',
      mode    => '0640',
      content => template('platform/ntp.conf.server.erb'),
    }

    file { 'ntp_config_initial':
      ensure  => file,
      path    => '/etc/ntp_initial.conf',
      mode    => '0640',
      content => template('platform/ntp_initial.conf.server.erb'),
    }

    file { '/etc/default/ntp':
      ensure  => file,
      mode    => '0644',
      content => 'NTPD_OPTS="-U 0"',
    }
  }
}

class platform::ntp::client {

  if $::personality != 'controller' {
    include ::platform::ntp

    file { 'ntp_config':
      ensure  => file,
      path    => '/etc/ntp.conf',
      mode    => '0644',
      content => template('platform/ntp.conf.client.erb'),
    }

    file { 'ntp_config_initial':
      ensure  => file,
      path    => '/etc/ntp_initial.conf',
      mode    => '0644',
      content => template('platform/ntp_initial.conf.client.erb'),
    }
  }
}

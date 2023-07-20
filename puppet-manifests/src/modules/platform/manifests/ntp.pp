class platform::ntp (
  $ntpdate_timeout,
  $servers = [],
  $enabled = true,
)
{
  # Setting ntp service name
  case $::osfamily {
    'RedHat': {
      $ntp_service_name = 'ntpd'
      $ntp_pmon_conf_template = 'platform/ntp.pmon.conf.erb'
    }
    'Debian': {
      $ntp_service_name = 'ntp'
      $ntp_pmon_conf_template = 'platform/ntp_debian.pmon.conf.erb'
    }
    default: {
      fail("unsuported osfamily ${::osfamily}, currently Debian and Redhat are the only supported platforms")
    }
  }

  if $enabled {
    $pmon_ensure = 'link'
  } else {
    $pmon_ensure = 'absent'
  }

  File['ntp_config']
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
      command => "timeout ${ntpdate_timeout} /usr/sbin/ntpd -g -q -n -c /etc/ntp_initial.conf",
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

class platform::collectd::params (
  $interval = undef,
  $timeout = undef,
  $read_threads = undef,
  $write_threads = undef,
  $write_queue_limit_high = undef,
  $write_queue_limit_low = undef,
  $max_read_interval = undef,

  $network_servers = [],
  $default_server_port = undef,

  # python plugin controls
  $module_path = undef,
  $plugins = [],
  $log_traces = undef,
  $encoding = undef,

  $collectd_d_dir = undef,
  $plugin_dir = $::osfamily ? {
    'RedHat' => '/usr/lib64/collectd',
    'Debian' => '/usr/lib/collectd',
    default   => '/usr/lib64/collectd',
  },

) {}


class platform::collectd
  inherits ::platform::collectd::params {

  #Get port or set default one
  $server_ports = $network_servers.map |$elem| {
    if(split($elem, ':').size() > 2) {
      if(']:' in $elem) {
        split($elem, ':')[-1]
      } else {
        $default_server_port
      }
    } else {
      if(':' in $elem) {
        split($elem, ':')[-1]
      } else {
        $default_server_port
      }
    }
  }
  #Get address
  $server_ips = $network_servers.map | $i, $elem| {
    $address = regsubst($elem.delete(":${server_ports[$i]}"),'[\[\]]','','G')
  }

  case $::osfamily {
    'RedHat': {
      $config_file = '/etc/collectd.conf'
    }
    'Debian': {
      $config_file = '/etc/collectd/collectd.conf'
      #using encoding will break collectd if used in Debian, due python3 incompatibility
      $encoding = undef
    }
    default: {
      fail("unsupported osfamily ${::osfamily}, currently Debian and Redhat are the only supported platforms")
    }
  } # Case $::osfamily

  file { $config_file:
    ensure  => 'present',
    replace => true,
    content => template('platform/collectd.conf.erb'),
  } # now start collectd

  -> exec { 'collectd-enable':
      command => 'systemctl enable collectd',
      unless  => 'systemctl is-enabled collectd'
  }

  # ensure pmon soft link for process monitoring
  -> file { '/etc/pmon.d/collectd.conf':
    ensure => 'link',
    target => '/opt/collectd/extensions/config/collectd.conf.pmon',
    owner  => 'root',
    group  => 'root',
    mode   => '0600',
  }

  # Crontab entry for monitoring rss daily Memory log.
  cron { 'memory-logs':
    ensure      => 'present',
    environment => 'PATH=/bin:/usr/bin:/usr/sbin',
    minute      => '00',
    hour        => '1',
    user        => 'root',
    command     => @(EOL/L),
        date --rfc-3339=s >> /var/log/rss-memory.log; \
        ps -e -o ppid,pid,nlwp,rss:10,vsz:10,comm,cmd --sort=-rss \
        >> /var/log/rss-memory.log; \
        /bin/chmod 0640 /var/log/rss-memory.log
        |- EOL
  }

  # Install custom toprc for root user;
  # gives fields: P, NU, CGNAME, and command args
  file { [ '/root/.config', '/root/.config/procps' ]:
    ensure => 'directory',
    owner  => 'root',
    group  => 'root',
    mode   => '0700',
  }
  -> file { '/root/.config/procps/toprc':
    ensure  => 'present',
    replace => true,
    content => template('platform/toprc.erb'),
    owner   => 'root',
    group   => 'root',
    mode    => '0644',
  }

  # Install custom toprc for sysadmin user
  # gives fields: P, NU, CGNAME, and command args
  file { [ '/home/sysadmin/.config', '/home/sysadmin/.config/procps' ]:
    ensure => 'directory',
    owner  => 'sysadmin',
    group  => 'sys_protected',
    mode   => '0700',
  }
  -> file { '/home/sysadmin/.config/procps/toprc':
    ensure  => 'present',
    replace => true,
    content => template('platform/toprc.erb'),
    owner   => 'sysadmin',
    group   => 'sys_protected',
    mode    => '0644',
  }
}

class platform::collectd::runtime {
  include ::platform::collectd
}

# restart target
class platform::collectd::restart {
  include ::platform::collectd
  exec { 'collectd-restart':
      command => '/usr/local/sbin/pmon-restart collectd'
  }
}

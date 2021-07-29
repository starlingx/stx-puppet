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

  file { '/etc/collectd.conf':
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

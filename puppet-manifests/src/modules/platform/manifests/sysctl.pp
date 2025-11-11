class platform::sysctl::params (
  $low_latency    = false,
  $tuned_devices  = '',
  $json_string    = '{}',  # Default to an empty JSON object string
  $config_dir     = '/etc/sysctl.d',
  $volatile_dir   = '/var/run',
  $default_config = "${config_dir}/80-puppet.conf",
) inherits platform::params {}

class platform::sysctl::vm_min_free_kbytes (
  $minimum_kb = 131072,
  $per_every_gb = 25,
  $reserve_mb = 128,
) inherits platform::sysctl::params {
  # Try to keep reserve_mb free per_every_gb of memory
  $want_min_free_kbytes = (floor($::memorysize_mb) / ($per_every_gb * 1024)) * $reserve_mb * 1024
  $min_free_kbytes = max($want_min_free_kbytes, $minimum_kb)
  sysctl::value { 'vm.min_free_kbytes':
    value  => String($min_free_kbytes),
    target => $default_config,
  }
}

class platform::sysctl inherits platform::sysctl::params {
  include platform::sysctl::tuned
  include platform::network::mgmt::params

  $ip_version = $platform::network::mgmt::params::subnet_version

  # Set sched_nr_migrate to standard linux default
  # Please notice that we'd better swap that in place of using bash if the newer
  # versions of puppet offer a native sysctl::value approach for the new path.
  exec { 'Set sched_nr_migrate to standard linux default':
    command => "bash -c 'echo 8 2>/dev/null >/sys/kernel/debug/sched/nr_migrate'",
  }

  # Enable br_netfilter (required to allow setting bridge-nf-call-arptables)
  exec { 'modprobe br_netfilter':
    command => 'modprobe br_netfilter',
  }

  # Set bridge-nf-call-arptables for containerized neutron
  -> sysctl::value { 'net.bridge.bridge-nf-call-arptables':
    value  => '1',
    target => $default_config,
  }

  # Ensure address space layout randomization is enabled
  -> sysctl::value { 'kernel.randomize_va_space':
    value  => '2',
    target => $default_config,
  }

  # Ensure ptrace_scope is restricted
  -> sysctl::value { 'kernel.yama.ptrace_scope':
    value  => '1',
    target => $default_config,
  }

  # Tuning options for low latency compute
  if $low_latency {
    # Increase VM stat interval
    sysctl::value { 'vm.stat_interval':
      value  => '10',
      target => $default_config,
    }

    # Disable timer migration
    sysctl::value { 'kernel.timer_migration':
      value  => '0',
      target => $default_config,
    }

    # Disable RT throttling
    sysctl::value { 'kernel.sched_rt_runtime_us':
      value  => '-1',
      target => $default_config,
    }

    exec { 'Set low-latency tuned profile for low-latency worker':
      command => 'tuned-adm profile starlingx-realtime',
    }

    # Enable check for raising timer interrupt only if one is pending.
    # This allows nohz full mode to operate properly on isolated cores.
    # Without it, ktimersoftd interferes with only one job being
    # on the run queue on that core, causing it to drop out of nohz.
    # If the check option doesn't exist in the kernel, silently fail.
    exec { 'Enable ktimer_lockless_check mode if it exists':
      command => "bash -c 'echo 1 2>/dev/null >/sys/kernel/ktimer_lockless_check; exit 0'",
    }
  } else {
    # Disable NUMA balancing
    sysctl::value { 'kernel.numa_balancing':
      value  => '0',
      target => $default_config,
    }
  }

  if $ip_version == $platform::params::ipv6 {
    sysctl::value { 'net.ipv6.conf.all.forwarding':
      value  => '1',
      target => $default_config,
    }
  } else {
    sysctl::value { 'net.ipv4.ip_forward':
      value  => '1',
      target => $default_config,
    }
  }
}

class platform::sysctl::tuned inherits platform::sysctl::params {
  # Populate devices to disable APM using device_path
  # Eg.: devices_udev_regex=(ID_PATH=pci-0000:00:17.0-ata-1.0)|(ID_PATH=pci-0000:00:17.0-ata-2.0)
  file_line { 'tuned_populate_devices':
    path  => '/etc/tuned/starlingx/tuned.conf',
    line  => "devices_udev_regex=${tuned_devices}",
    match => '^[\s]*#?devices_udev_regex=',
  }
  -> exec { 'systemctl-restart-tuned':
    command => '/usr/bin/systemctl restart tuned.service',
  }
}

class platform::sysctl::controller::reserve_ports inherits platform::sysctl::params {
  # Reserve ports in the ephemeral port range:
  #
  # Incorporate the reserved keystone port (35357) from
  # /usr/lib/sysctl.d/openstack-keystone.conf
  #
  # libvirt v4.7.0 hardcodes the ports 49152-49215 as its default port range
  # for migrations (qemu.conf). Reserve them from the ephemeral port range.
  # This will avoid potential port conflicts that will cause migration
  # failures when the port is assigned to another service
  sysctl::value { 'net.ipv4.ip_local_reserved_ports':
    value  => '35357,49152-49215',
    target => $default_config,
  }
}

class platform::sysctl::controller inherits platform::sysctl::params {
  include platform::sysctl
  include platform::sysctl::controller::reserve_ports
  include platform::sysctl::vm_min_free_kbytes
  include platform::sysctl::config_update

  # Engineer VM page cache tunables to prevent significant IO delays that may
  # occur if we flush a buildup of dirty pages.  Engineer VM settings to make
  # writebacks more regular. Note that Linux default proportion of page cache that
  # can be dirty is rediculously large for systems > 8GB RAM, and can result in
  # many seconds of IO wait, especially if GBs of dirty pages are written at once.
  # Note the following settings are currently only applied to controller,
  # though these are intended to be applicable to all blades. For unknown reason,
  # there was negative impact to VM traffic on computes.

  # dirty_background_bytes limits magnitude of pending IO, so
  # choose setting of 3 seconds dirty holding x 200 MB/s write speed (SSD)
  sysctl::value { 'vm.dirty_background_bytes':
    value  => '600000000',
    target => $default_config,
  }

  # dirty_ratio should be larger than dirty_background_bytes, set 1.3x larger
  sysctl::value { 'vm.dirty_bytes':
    value  => '800000000',
    target => $default_config,
  }

  # prefer reclaim of dentries and inodes, set larger than default of 100
  sysctl::value { 'vm.vfs_cache_pressure':
    value  => '500',
    target => $default_config,
  }

  # reduce dirty expiry to 10s from default 30s
  sysctl::value { 'vm.dirty_expire_centisecs':
    value  => '1000',
    target => $default_config,
  }

  # reduce dirty writeback to 1s from default 5s
  sysctl::value { 'vm.dirty_writeback_centisecs':
    value  => '100',
    target => $default_config,
  }

  # Setting max to 160 MB to support more connections
  # When increasing postgres connections, add 7.5 MB for every 100 connections
  sysctl::value { 'kernel.shmmax':
    value  => '167772160',
    target => $default_config,
  }
}

class platform::sysctl::compute {
  include platform::sysctl
  include platform::sysctl::compute::reserve_ports
  include platform::sysctl::vm_min_free_kbytes
  include platform::sysctl::config_update
}

class platform::sysctl::compute::reserve_ports inherits platform::sysctl::params {
  # Reserve ports in the ephemeral port range:
  #
  # libvirt v4.7.0 hardcodes the ports 49152-49215 as its default port range
  # for migrations (qemu.conf). Reserve them from the ephemeral port range.
  # This will avoid potential port conflicts that will cause migration
  # failures when the port is assigned to another service
  sysctl::value { 'net.ipv4.ip_local_reserved_ports':
    value  => '49152-49215',
    target => $default_config,
  }
}

class platform::sysctl::storage {
  include platform::sysctl
  include platform::sysctl::config_update

  class { 'platform::sysctl::vm_min_free_kbytes':
    minimum_kb   => 262144,
    per_every_gb => 16,
    reserve_mb   => 256,
  }
}

class platform::sysctl::controller::runtime {
  include platform::sysctl::controller
}

class platform::sysctl::bootstrap {
  include platform::sysctl::tuned
  include platform::sysctl::controller::reserve_ports
}

# Set the kubernetes sysctl kernel runtime parameters
class platform::sysctl::k8s::config_update inherits platform::sysctl::params {
  $config_file = "${config_dir}/80-k8s.conf"
  $config_settings = {
    'net.bridge.bridge-nf-call-ip6tables'   => '1',
    'net.bridge.bridge-nf-call-iptables'    => '1',
    'net.ipv4.ip_forward'                   => '1',
    'net.ipv6.conf.all.forwarding'          => '1',
  }
  # Update iptables config. This is required based on:
  # https://kubernetes.io/docs/tasks/tools/install-kubeadm
  file { $config_file:
    ensure  => file,
    owner   => 'root',
    group   => 'root',
    mode    => '0644',
    content => template('platform/config.conf.erb'),
  }
  -> exec { 'update kubernetes sysctl kernel parameters':
    command => 'sysctl --system',
  }
}

# Implements user overrides for kernel runtime parameters.
# The default sysctl config file is used to persist original settings
# that are restored when the user deletes their override.
# Sysctl config files:
# /etc/sysctl.d/100-custom-user.conf    -> /var/run/100-custom-user.conf
# /etc/sysctl.d/05-default-sysctl.conf  -> /var/run/05-default-sysctl.conf
class platform::sysctl::config_update inherits platform::sysctl::params {
  $default_sysctl         = "${volatile_dir}/05-default-sysctl.conf"
  $default_sysctl_linked  = "${config_dir}/05-default-sysctl.conf"
  $config_file            = "${volatile_dir}/100-custom-user.conf"
  $config_file_linked     = "${config_dir}/100-custom-user.conf"

  $config_settings = parsejson($json_string)
  if $config_settings =~ Hash {
    $config_settings.each |$param, $value| {
      $check_cmd  = "grep -q '^${param}' ${volatile_dir}/*.conf --exclude=${config_file}"
      $append_cmd = "sysctl ${param} >> ${default_sysctl}"
      # Check if the original parameter value is already saved; if not, append it
      exec { "check_and_append_${param}":
        command => "${check_cmd} || ${append_cmd}",
        unless  => $check_cmd,
      }
    }
    $exec_deps = keys($config_settings).map |$param| { "check_and_append_${param}" }
    file { $default_sysctl:
      ensure  => file,
      owner   => 'root',
      group   => 'root',
      mode    => '0644',
      require => Exec[$exec_deps],
    }
    file { $config_file:
      ensure  => file,
      owner   => 'root',
      group   => 'root',
      mode    => '0644',
      content => template('platform/config.conf.erb'),
      require => Exec[$exec_deps],
    }
    # Create symlinks in /etc/sysctl.d to the files in /var/run
    -> file { $default_sysctl_linked:
      ensure  => link,
      target  => $default_sysctl,
      require => File[$default_sysctl],
      force   => true,
    }
    -> file { $config_file_linked:
      ensure  => link,
      target  => $config_file,
      require => File[$config_file],
      force   => true,
    }
    # Apply the updated sysctl settings
    -> exec { 'update user sysctl kernel parameters':
      command     => 'sysctl --system',
      refreshonly => true,
      subscribe   => File[$config_file],
    }
  }
}

# runtime manifest that updates sysctl kernel config
class platform::sysctl::config_update::runtime {
  include platform::sysctl::config_update
}

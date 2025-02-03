class platform::sysctl::params (
  $low_latency = false,
  $tuned_devices  = ''
) inherits ::platform::params {}

class platform::sysctl::vm_min_free_kbytes (
  $minimum_kb = 131072,
  $per_every_gb = 25,
  $reserve_mb = 128,
) inherits ::platform::sysctl::params {

  # Try to keep reserve_mb free per_every_gb of memory
  $want_min_free_kbytes = (floor($::memorysize_mb) / ($per_every_gb * 1024)) * $reserve_mb * 1024
  $min_free_kbytes = max($want_min_free_kbytes, $minimum_kb)
  sysctl::value { 'vm.min_free_kbytes':
    value => String($min_free_kbytes)
  }
}

class platform::sysctl
  inherits ::platform::sysctl::params {

  include ::platform::sysctl::tuned
  include ::platform::network::mgmt::params

  $ip_version = $::platform::network::mgmt::params::subnet_version

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
    value => '1',
  }

  # Ensure address space layout randomization is enabled
  -> sysctl::value { 'kernel.randomize_va_space':
    value => '2',
  }

  # Ensure ptrace_scope is restricted
  -> sysctl::value { 'kernel.yama.ptrace_scope':
    value => '1',
  }

  # Tuning options for low latency compute
  if $low_latency {
    # Increase VM stat interval
    sysctl::value { 'vm.stat_interval':
      value => '10',
    }

    # Disable timer migration
    sysctl::value { 'kernel.timer_migration':
      value => '0',
    }

    # Disable RT throttling
    sysctl::value { 'kernel.sched_rt_runtime_us':
      value => '-1',
    }

    exec { 'Set low-latency tuned profile for low-latency worker':
      command => 'tuned-adm profile starlingx-realtime'
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
      value => '0',
    }
  }

  if $ip_version == $::platform::params::ipv6 {
    sysctl::value { 'net.ipv6.conf.all.forwarding':
      value => '1'
    }

  } else {
    sysctl::value { 'net.ipv4.ip_forward':
      value => '1'
    }
  }
}

class platform::sysctl::tuned
  inherits ::platform::sysctl::params {

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


class platform::sysctl::controller::reserve_ports
  inherits ::platform::sysctl::params {

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
    value => '35357,49152-49215'
  }
}


class platform::sysctl::controller
  inherits ::platform::sysctl::params {

  include ::platform::sysctl
  include ::platform::sysctl::controller::reserve_ports
  include ::platform::sysctl::vm_min_free_kbytes

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
    value => '600000000'
  }

  # dirty_ratio should be larger than dirty_background_bytes, set 1.3x larger
  sysctl::value { 'vm.dirty_bytes':
    value => '800000000'
  }

  # prefer reclaim of dentries and inodes, set larger than default of 100
  sysctl::value { 'vm.vfs_cache_pressure':
    value => '500'
  }

  # reduce dirty expiry to 10s from default 30s
  sysctl::value { 'vm.dirty_expire_centisecs':
    value => '1000'
  }

  # reduce dirty writeback to 1s from default 5s
  sysctl::value { 'vm.dirty_writeback_centisecs':
    value => '100'
  }

  # Setting max to 160 MB to support more connections
  # When increasing postgres connections, add 7.5 MB for every 100 connections
  sysctl::value { 'kernel.shmmax':
    value => '167772160'
  }
}


class platform::sysctl::compute {
  include ::platform::sysctl
  include ::platform::sysctl::compute::reserve_ports
  include ::platform::sysctl::vm_min_free_kbytes

}

class platform::sysctl::compute::reserve_ports
  inherits ::platform::sysctl::params {

  # Reserve ports in the ephemeral port range:
  #
  # libvirt v4.7.0 hardcodes the ports 49152-49215 as its default port range
  # for migrations (qemu.conf). Reserve them from the ephemeral port range.
  # This will avoid potential port conflicts that will cause migration
  # failures when the port is assigned to another service
  sysctl::value { 'net.ipv4.ip_local_reserved_ports':
    value => '49152-49215'
  }
}

class platform::sysctl::storage {
  include ::platform::sysctl

  class { 'platform::sysctl::vm_min_free_kbytes':
    minimum_kb   => 262144,
    per_every_gb => 16,
    reserve_mb   => 256,
  }
}


class platform::sysctl::controller::runtime {
  include ::platform::sysctl::controller
}


class platform::sysctl::bootstrap {
  include ::platform::sysctl::tuned
  include ::platform::sysctl::controller::reserve_ports
}

class platform::compute::params (
  $worker_cpu_list = '',
  $platform_cpu_list = '',
  $reserved_vswitch_cores = '',
  $reserved_platform_cores = '',
  $worker_base_reserved = '',
  $compute_vswitch_reserved = '',
  $max_cpu_mhz_configured = undef
) { }

class platform::compute::config
  inherits ::platform::compute::params {
  include ::platform::collectd::restart
  include ::platform::kubernetes::params

  $power_management = 'power-management=enabled' in $::platform::kubernetes::params::host_labels

  file { '/etc/platform/worker_reserved.conf':
      ensure  => 'present',
      replace => true,
      content => template('platform/worker_reserved.conf.erb')
  }
  -> Exec['collectd-restart']

  if $::platform::params::system_type != 'All-in-one' {
    file { '/etc/systemd/system.conf.d/platform-cpuaffinity.conf':
        ensure  => 'present',
        replace => true,
        content => template('platform/systemd-system-cpuaffinity.conf.erb')
    }
  }

  if (!$power_management and $max_cpu_mhz_configured != undef) {
    exec { 'Update host max CPU frequency':
      command   => "/usr/bin/cpupower frequency-set -u ${max_cpu_mhz_configured}MHz",
      logoutput => true,
    }
  }
}

class platform::compute::config::runtime {
  include ::platform::compute::config
}

class platform::compute::grub::params (
  $n_cpus = '',
  $cpu_options = '',
  $m_hugepages = 'hugepagesz=2M hugepages=0',
  $g_hugepages = '',
  $default_pgsz = '',
  $g_audit = '',
  $g_audit_backlog_limit = 'audit_backlog_limit=8192',
  $g_intel_pstate = '',
  $g_out_of_tree_drivers = '',
  $bios_cstate = false,
  $ignore_recovery = false,
  $keys = [
    'kvm-intel.eptad',
    'default_hugepagesz',
    'hugepagesz',
    'hugepages',
    'isolcpus',
    'nohz_full',
    'rcu_nocbs',
    'kthread_cpus',
    'irqaffinity',
    'audit',
    'audit_backlog_limit',
    'intel_pstate',
    'out-of-tree-drivers',
    'intel_idle.max_cstate',
  ],
) {
  include platform::sysctl::params

  if str2bool($platform::sysctl::params::low_latency) {
    $nmi_watchdog = 'nmi_watchdog=0 softlockup_panic=0'
    $skew_tick = 'skew_tick=1'
  }
  else {
    $nmi_watchdog = 'nmi_watchdog=panic,1 softlockup_panic=1'
    $skew_tick = ''
  }

  include ::platform::kubernetes::params

  if $::is_broadwell_processor {
    $eptad = 'kvm-intel.eptad=0'
  } else {
    $eptad = ''
  }

  $power_management = 'power-management=enabled' in $::platform::kubernetes::params::host_labels

  if (!$power_management and $bios_cstate) {
    $intel_idle_cstate = 'intel_idle.max_cstate=0'
  } else {
    $intel_idle_cstate = ''
  }
  $updated_audit = "audit=${g_audit}"

  if ! empty($g_out_of_tree_drivers) {
    $oot_drivers_switch = "out-of-tree-drivers=${g_out_of_tree_drivers}"
  } else {
    $oot_drivers_switch = ''
  }

  if ! empty($g_intel_pstate) {
    $intel_pstate = "intel_pstate=${g_intel_pstate}"
  } else {
    $intel_pstate = ''
  }

  $grub_updates = strip(
    # lint:ignore:140chars
    "${eptad} ${g_hugepages} ${m_hugepages} ${default_pgsz} ${cpu_options} ${updated_audit} ${g_audit_backlog_limit} ${intel_idle_cstate} ${intel_pstate} ${nmi_watchdog} ${skew_tick} ${oot_drivers_switch}"
    # lint:endignore:140chars
    )
}

class platform::compute::grub::update
  inherits ::platform::compute::grub::params {

  notice('Updating grub configuration')

  # Remove nohz_full grub parameter if platform plugin is disabling it
  $truncated_grub_updates = strip(regsubst($grub_updates, /nohz_full=disabled/, ''))

  $to_be_removed = join($keys, ' ')
  if $::osfamily == 'RedHat' {
    exec { 'Remove the cpu arguments':
      command => "grubby --update-kernel=ALL --remove-args='${to_be_removed}'",
    }
    -> exec { 'Remove the cpu arguments from /etc/default/grub':
      command   => "/usr/local/bin/puppet-update-default-grub.sh --remove ${to_be_removed}",
      logoutput => true,
    }
    -> exec { 'Add the cpu arguments':
      command => "grubby --update-kernel=ALL --args='${truncated_grub_updates}'",
    }
    -> exec { 'Add the cpu arguments to /etc/default/grub':
      command   => "/usr/local/bin/puppet-update-default-grub.sh --add ${truncated_grub_updates}",
      logoutput => true,
    }
  } elsif($::osfamily == 'Debian') {
    notice("Removing kernel args: ${to_be_removed}")
    notice("Adding kernel args: ${truncated_grub_updates}")
    exec { 'Remove the cpu arguments from /boot/efi/EFI/BOOT/boot.env':
      command   => "/usr/local/bin/puppet-update-grub-env.py --remove-kernelparams '${to_be_removed}'",
    }
    -> exec { 'Add the cpu arguments to /boot/efi/EFI/BOOT/boot.env':
      command   => "/usr/local/bin/puppet-update-grub-env.py --add-kernelparams '${truncated_grub_updates}'",
    }
  }
}

class platform::compute::grub::recovery {

  notice('Update Grub and Reboot')

  class {'platform::compute::grub::update': } -> Exec['reboot-recovery']

  exec { 'reboot-recovery':
    command => 'reboot',
  }
}

class platform::compute::grub::audit
  inherits ::platform::compute::grub::params {

  notice('Audit CPU and Grub Configuration')

  $cmd_ok = check_grub_config($grub_updates)

  # Handle controller in standard mode (non-worker)
  if !str2bool($::is_worker_subfunction) {
    notice('Handling non-worker node.')
    if $cmd_ok {
      notice('Boot Argument audit passed.')
    } else {
      notice('Kernel Boot Argument Mismatch')
      include ::platform::compute::grub::recovery
    }
  } else {
    $expected_n_cpus = Integer($::number_of_logical_cpus)
    $n_cpus_ok = ($n_cpus == $expected_n_cpus)

    if $cmd_ok and $n_cpus_ok {
      $ensure = present
      notice('CPU and Boot Argument audit passed.')
    } else {
      if !$cmd_ok {
        if ($ignore_recovery) {
          $ensure = present
          notice('Ignoring Grub cmdline recovery')
          include ::platform::compute::grub::update
        } else {
          notice('Kernel Boot Argument Mismatch')
          $ensure = absent
          include ::platform::compute::grub::recovery
        }
      } else {
        notice("Mismatched CPUs: Found=${n_cpus}, Expected=${expected_n_cpus}")
        $ensure = absent
      }
    }

    file { '/var/run/worker_goenabled':
      ensure => $ensure,
      owner  => 'root',
      group  => 'root',
      mode   => '0644',
    }
  }
}

class platform::compute::grub::runtime {
  include ::platform::compute::grub::update
}

# Mounts virtual hugetlbfs filesystems for each supported page size
class platform::compute::hugetlbf {

  if str2bool($::is_hugetlbfs_enabled) {

    $fs_list = generate('/bin/bash', '-c', 'ls -1d /sys/kernel/mm/hugepages/hugepages-*')
    $array = split($fs_list, '\n')
    $array.each | String $val | {
      $page_name = generate('/bin/bash', '-c', "basename ${val}")
      $page_size = strip(regsubst($page_name, 'hugepages-', ''))
      $hugemnt ="/mnt/huge-${page_size}"
      $options = "pagesize=${page_size}"

      # TODO: Once all the code is switched over to use the /dev
      # mount point  we can get rid of this mount point.
      notice("Mounting hugetlbfs at: ${hugemnt}")
      exec { "create ${hugemnt}":
        command => "mkdir -p ${hugemnt}",
        onlyif  => "test ! -d ${hugemnt}",
      }
      -> mount { $hugemnt:
        ensure   => 'mounted',
        device   => 'none',
        fstype   => 'hugetlbfs',
        name     => $hugemnt,
        options  => $options,
        atboot   => 'yes',
        remounts => true,
      }

      # The libvirt helm chart expects hugepages to be mounted
      # under /dev so let's do that.
      $hugemnt2 ="/dev/huge-${page_size}"
      notice("Mounting hugetlbfs at: ${hugemnt2}")
      file { $hugemnt2:
        ensure => 'directory',
        owner  => 'root',
        group  => 'root',
        mode   => '0755',
      }
      -> mount { $hugemnt2:
        ensure   => 'mounted',
        device   => 'none',
        fstype   => 'hugetlbfs',
        name     => $hugemnt2,
        options  => $options,
        atboot   => 'yes',
        remounts => true,
      }
    }

    # The libvirt helm chart also assumes that the default hugepage size
    # will be mounted at /dev/hugepages so let's make that happen too.
    # Once we upstream a fix to the helm chart to automatically determine
    # the mountpoint then we can remove this.
    include ::platform::compute::grub::params
    $default_pgsz_str = $::platform::compute::grub::params::default_pgsz
    $page_size = strip(regsubst($default_pgsz_str, 'default_hugepagesz=', ''))
    $hugemnt ='/dev/hugepages'
    $options = "pagesize=${page_size}"

    notice("Mounting hugetlbfs at: ${hugemnt}")
    exec { "create ${hugemnt}":
      command => "mkdir -p ${hugemnt}",
      onlyif  => "test ! -d ${hugemnt}",
    }
    -> mount { $hugemnt:
      ensure   => 'mounted',
      device   => 'none',
      fstype   => 'hugetlbfs',
      name     => $hugemnt,
      options  => $options,
      atboot   => 'yes',
      remounts => true,
    }
  }
}

# lint:ignore:variable_is_lowercase
class platform::compute::hugepage::params (
  $nr_hugepages_2M = undef,
  $nr_hugepages_1G = undef,
  $vswitch_2M_pages = '',
  $vswitch_1G_pages = '',
  $vm_4K_pages = '',
  $vm_2M_pages = '',
  $vm_1G_pages = '',
) {}


define platform::compute::allocate_pages (
  $path,
  $page_count,
) {
  exec { "Allocate ${page_count} ${path}":
    command => "echo ${page_count} > ${path}",
    onlyif  => "test -f ${path}",
  }
}

# Allocates HugeTLB memory according to the attributes specified in the
# nr_hugepages_2M and nr_hugepages_1G
class platform::compute::allocate
  inherits ::platform::compute::hugepage::params {

  # determine the node file system
  if str2bool($::is_per_numa_supported) {
    $nodefs = '/sys/devices/system/node'
  } else {
    $nodefs = '/sys/kernel/mm'
  }

  if $nr_hugepages_2M != undef {
    $nr_hugepages_2M_array = regsubst($nr_hugepages_2M, '[\(\)\"]', '', 'G').split(' ')
    $nr_hugepages_2M_array.each | String $val | {
      $per_node_2M = $val.split(':')
      if size($per_node_2M)== 3 {
        $node = $per_node_2M[0]
        $page_size = $per_node_2M[1]
        platform::compute::allocate_pages { "Start ${node} ${page_size}":
          path       => "${nodefs}/${node}/hugepages/hugepages-${page_size}/nr_hugepages",
          page_count => $per_node_2M[2],
        }
      }
    }
  }

  if $nr_hugepages_1G  != undef {
    $nr_hugepages_1G_array = regsubst($nr_hugepages_1G , '[\(\)\"]', '', 'G').split(' ')
    $nr_hugepages_1G_array.each | String $val | {
      $per_node_1G = $val.split(':')
      if size($per_node_1G)== 3 {
        $node = $per_node_1G[0]
        $page_size = $per_node_1G[1]
        platform::compute::allocate_pages { "Start ${node} ${page_size}":
          path       => "${nodefs}/${node}/hugepages/hugepages-${page_size}/nr_hugepages",
          page_count => $per_node_1G[2],
        }
      }
    }
  }
}
# lint:endignore:variable_is_lowercase

# Mount resctrl to allow Cache Allocation Technology per VM
class platform::compute::resctrl {

  if str2bool($::is_resctrl_supported) {
    mount { '/sys/fs/resctrl':
      ensure   => 'mounted',
      device   => 'resctrl',
      fstype   => 'resctrl',
      name     => '/sys/fs/resctrl',
      atboot   => 'yes',
      remounts => true,
    }
  }
}

# Set systemd machine.slice cgroup cpuset to be used with VMs,
# and configure this cpuset to span all logical cpus and numa nodes.
# NOTES:
# - The parent directory cpuset spans all online cpus and numa nodes.
# - Setting the machine.slice cpuset prevents this from inheriting
#   kubernetes libvirt pod's cpuset, since machine.slice cgroup will be
#   created when a VM is launched if it does not already exist.
# - systemd automatically mounts cgroups and controllers, so don't need
#   to do that here.
class platform::compute::machine {
  $parent_dir = '/sys/fs/cgroup/cpuset'
  $parent_mems = "${parent_dir}/cpuset.mems"
  $parent_cpus = "${parent_dir}/cpuset.cpus"
  $machine_dir = "${parent_dir}/machine.slice"
  $machine_mems = "${machine_dir}/cpuset.mems"
  $machine_cpus = "${machine_dir}/cpuset.cpus"
  notice("Create ${machine_dir}")
  file { $machine_dir :
    ensure => directory,
    owner  => 'root',
    group  => 'root',
    mode   => '0700',
  }
  -> exec { "Create ${machine_mems}" :
    command => "/bin/cat ${parent_mems} > ${machine_mems}",
  }
  -> exec { "Create ${machine_cpus}" :
    command => "/bin/cat ${parent_cpus} > ${machine_cpus}",
  }
}

class platform::compute::kvm_timer_advance(
  $enabled = False,
  $vcpu_pin_set = undef
) {
  if $enabled {
    # include the declaration of the kubelet service
    include ::platform::kubernetes::worker

    file { '/etc/kvm-timer-advance/kvm-timer-advance.conf':
      ensure  => 'present',
      replace => true,
      content => template('platform/kvm_timer_advance.conf.erb')
    }
    -> service { 'kvm_timer_advance_setup':
      ensure => 'running',
      enable => true,
      before => Service['kubelet'],
    }
    # A separate enable is required since we have modified the service resource
    # to never enable/disable services in puppet.
    -> exec { 'Enable kvm_timer_advance_setup':
      command => '/usr/bin/systemctl enable kvm_timer_advance_setup.service',
    }
  } else {
    # A disable is required since we have modified the service resource
    # to never enable/disable services in puppet and stop has no effect.
    exec { 'Disable kvm_timer_advance_setup':
      command => '/usr/bin/systemctl disable kvm_timer_advance_setup.service',
    }
  }
}

# Controls, based on the openstack_compute node label
# the conditional loading of the non-open-source NVIDIA vGPU
# drivers for commercial scenarios where they are built into
# the StarlingX ISO.
class platform::compute::nvidia_vgpu_drivers(
  $openstack_enabled = false,
  $install_script = '/usr/share/nvidia/install.sh',
  $uninstall_script = '/usr/share/nvidia/uninstall.sh'
) {
  if $openstack_enabled {
    exec { 'Install nvidia vgpu driver':
      command => $install_script,
      path    => ['/usr/share/nvidia', '/bin', '/usr/bin', '/usr/sbin'],
      onlyif  => "test -e ${install_script}",
    }
  } else {
    exec { 'Uninstall nvidia vgpu driver':
      command => $uninstall_script,
      path    => ['/usr/share/nvidia', '/bin', '/usr/bin', '/usr/sbin'],
      onlyif  => "test -e ${uninstall_script}",
    }
  }
}

class platform::compute::iscsi_setup
  inherits ::platform::compute::params {

  if $platform_cpu_list != '' {
    exec { 'Create config directory':
      command => 'mkdir -p /sys/kernel/config',
      unless  => 'test -d /sys/kernel/config',
    }
    -> exec { 'Mount configfs':
      command => 'mount -t configfs none /sys/kernel/config',
      unless  => 'mount | grep /sys/kernel/config',
    }
    -> exec { 'Load iscsi_target_mod module':
      command => 'modprobe iscsi_target_mod',
      unless  => 'lsmod | grep iscsi_target_mod',
    }
    -> exec { 'Create iscsi directory':
      command => 'mkdir /sys/kernel/config/target/iscsi',
      unless  => 'test -d /sys/kernel/config/target/iscsi',
    }
    -> exec { 'Set CPUs allowed list':
      command => "echo ${platform_cpu_list} > /sys/kernel/config/target/iscsi/cpus_allowed_list",
    }
  }
}

class platform::compute {

  Class[$name] -> Class['::platform::vswitch']

  require ::platform::compute::hugetlbf
  require ::platform::compute::allocate
  require ::platform::compute::resctrl
  require ::platform::compute::machine
  require ::platform::compute::config
  require ::platform::compute::nvidia_vgpu_drivers
  require ::platform::compute::iscsi_setup

  # Not included in Debian until libvirt gets included
  if $::osfamily == 'RedHat' {
    require ::platform::compute::kvm_timer_advance
  }
}

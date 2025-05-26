class platform::kubernetes::params (
  $enabled = true,
  # K8S version we are upgrading to (None if not in an upgrade)
  $upgrade_to_version = undef,
  # K8S version running on a host
  $version = undef,
  $kubeadm_version = undef,
  $kubelet_version = undef,
  $node_ip = undef,
  $node_ip_secondary = undef,
  $service_domain = undef,
  $apiserver_cluster_ip = undef,
  $dns_service_ip = undef,
  $host_labels = [],
  $k8s_cpushares = 10240,
  $k8s_cpuset = undef,
  $k8s_nodeset = undef,
  $k8s_platform_cpuset = undef,
  $k8s_reserved_mem = undef,
  $k8s_all_reserved_cpuset = undef,
  $k8s_cpu_mgr_policy = 'static',
  $k8s_memory_mgr_policy = 'None',
  $k8s_topology_mgr_policy = 'best-effort',
  $k8s_cni_bin_dir = '/var/opt/cni/bin',
  $k8s_vol_plugin_dir = '/var/opt/libexec/kubernetes/kubelet-plugins/volume/exec/',
  $k8s_pod_max_pids = '65535',
  $join_cmd = undef,
  $oidc_issuer_url = undef,
  $oidc_client_id = undef,
  $oidc_username_claim = undef,
  $oidc_groups_claim = undef,
  $admission_plugins = undef,
  $audit_policy_file = undef,
  $etcd_cafile = undef,
  $etcd_certfile = undef,
  $etcd_keyfile = undef,
  $etcd_servers = undef,
  $rootca_certfile = '/etc/kubernetes/pki/ca.crt',
  $rootca_keyfile = '/etc/kubernetes/pki/ca.key',
  $rootca_cert = undef,
  $rootca_key = undef,
  $admin_cert = undef,
  $admin_key = undef,
  $super_admin_cert = undef,
  $super_admin_key = undef,
  $apiserver_cert = undef,
  $apiserver_key = undef,
  $apiserver_kubelet_cert = undef,
  $apiserver_kubelet_key = undef,
  $scheduler_cert = undef,
  $scheduler_key = undef,
  $controller_manager_cert = undef,
  $controller_manager_key = undef,
  $kubelet_cert = undef,
  $kubelet_key = undef,
  $etcd_cert_file = undef,
  $etcd_key_file = undef,
  $etcd_ca_cert = undef,
  $etcd_endpoints = undef,
  $etcd_snapshot_file = '/opt/backups/k8s-control-plane/etcd/stx_etcd.snap',
  $static_pod_manifests_initial = '/opt/backups/k8s-control-plane/static-pod-manifests',
  $static_pod_manifests_abort = '/opt/backups/k8s-control-plane/static-pod-manifests-abort',
  $kube_config_backup_path = '/opt/backups/k8s-control-plane/k8s-config',
  $etcd_name = 'controller',
  $etcd_initial_cluster = 'controller=http://localhost:2380',
  # The file holding the root CA cert/key to update to
  $rootca_certfile_new = '/etc/kubernetes/pki/ca_new.crt',
  $rootca_keyfile_new = '/etc/kubernetes/pki/ca_new.key',
  $kubelet_image_gc_low_threshold_percent = 75,
  $kubelet_image_gc_high_threshold_percent = 79,
  $kubelet_eviction_hard_imagefs_available = '2Gi',
  $k8s_reserved_memory = '',
) { }

define platform::kubernetes::pull_images_from_registry (
  $resource_title,
  $command,
  $before_exec,
  $local_registry_auth,
) {
  file { '/tmp/puppet/registry_credentials':
    ensure  => file,
    content => template('platform/registry_credentials.erb'),
    owner   => 'root',
    group   => 'root',
    mode    => '0640',
  }

  if ($before_exec == undef) {
    exec { $resource_title:
      command   => $command,
      logoutput => true,
      require   => File['/tmp/puppet/registry_credentials'],
    }
  } else {
    exec { $resource_title:
      command   => $command,
      logoutput => true,
      require   => File['/tmp/puppet/registry_credentials'],
      before    => Exec[$before_exec],
    }
  }

  exec { 'destroy credentials file':
    command => '/bin/rm -f /tmp/puppet/registry_credentials',
    onlyif  => 'test -e /tmp/puppet/registry_credentials',
  }
}

# Define for kubelet to be monitored by pmond
define platform::kubernetes::pmond_kubelet_file(
  $custom_title = 'default',  # Default title
) {
  # Create the file if not present
  file { '/etc/pmon.d/kubelet.conf':
    ensure  => file,
    replace => 'no',
    content => template('platform/kubelet-pmond-conf.erb'),
    owner   => 'root',
    group   => 'root',
    mode    => '0644',
  }
}

class platform::kubernetes::configuration {

  # Check to ensure that this code is not executed
  # during install and reinstall.  We want to
  # only execute this block for lock and unlock
  if ! str2bool($::is_initial_k8s_config) {
    # Add kubelet service override
    file { '/etc/systemd/system/kubelet.service.d/kube-stx-override.conf':
      ensure  => file,
      content => template('platform/kube-stx-override.conf.erb'),
      owner   => 'root',
      group   => 'root',
      mode    => '0644',
    }
  }

  if ($::personality == 'controller') {
    # Cron job to cleanup stale CNI cache files that are more than
    # 1 day old and are not associated with any currently running pod.
    cron { 'k8s-cni-cache-cleanup':
      ensure      => 'present',
      command     => '/usr/local/sbin/k8s-cni-cache-cleanup -o 24 -d',
      environment => 'PATH=/bin:/usr/bin:/usr/sbin:/usr/local/sbin',
      minute      => '30',
      hour        => '*/24',
      user        => 'root',
    }
  }
}

class platform::kubernetes::symlinks {
  include ::platform::kubernetes::params

  $kubeadm_version = $::platform::kubernetes::params::kubeadm_version
  $kubelet_version = $::platform::kubernetes::params::kubelet_version

  # We are using symlinks here, we tried bind mounts originally but
  # the Puppet mount class does not deal well with bind mounts
  # and it was causing robustness issues if there was anything
  # running in one of the mounts when we wanted to change it.

  notice("setting stage1 symlink, kubeadm_version is ${kubeadm_version}")
  file { '/var/lib/kubernetes/stage1':
    ensure => link,
    target => "/usr/local/kubernetes/${kubeadm_version}/stage1",
  }

  notice("setting stage2 symlink, kubelet_version is ${kubelet_version}")
  file { '/var/lib/kubernetes/stage2':
    ensure => link,
    target => "/usr/local/kubernetes/${kubelet_version}/stage2",
  }
}

class platform::kubernetes::cgroup::params (
  $cgroup_root = '/sys/fs/cgroup',
  $cgroup_name = 'k8s-infra',
  $controllers = ['cpuset', 'cpu', 'cpuacct', 'memory', 'systemd', 'pids'],
) {}

class platform::kubernetes::cgroup
  inherits ::platform::kubernetes::cgroup::params {
  include ::platform::kubernetes::params

  $k8s_cpuset = $::platform::kubernetes::params::k8s_cpuset
  $k8s_nodeset = $::platform::kubernetes::params::k8s_nodeset
  $k8s_cpushares = $::platform::kubernetes::params::k8s_cpushares

  # Default to float across all cpus and numa nodes
  if !defined('$k8s_cpuset') {
    $k8s_cpuset = generate('/bin/cat', '/sys/devices/system/cpu/online')
    notice("System default cpuset ${k8s_cpuset}.")
  }
  if !defined('$k8s_nodeset') {
    $k8s_nodeset = generate('/bin/cat', '/sys/devices/system/node/online')
    notice("System default nodeset ${k8s_nodeset}.")
  }

  # Create kubelet cgroup for the minimal set of required controllers.
  # NOTE: The kubernetes cgroup_manager_linux func Exists() checks that
  # specific subsystem cgroup paths actually exist on the system. The
  # particular cgroup cgroupRoot must exist for the following controllers:
  # "cpu", "cpuacct", "cpuset", "memory", "systemd", "pids".
  # Reference:
  #  https://github.com/kubernetes/kubernetes/blob/master/pkg/kubelet/cm/cgroup_manager_linux.go
  # systemd automatically mounts cgroups and controllers, so don't need
  # to do that here.
  notice("Create ${cgroup_root}/${controllers}/${cgroup_name}")
  $controllers.each |String $controller| {
    $cgroup_dir = "${cgroup_root}/${controller}/${cgroup_name}"
    file { $cgroup_dir :
      ensure => directory,
      owner  => 'root',
      group  => 'root',
      mode   => '0700',
    }

    # Modify k8s cpuset resources to reflect platform configured cores.
    # NOTE: Using 'exec' here instead of 'file' resource type with 'content'
    # tag to update contents under /sys, since puppet tries to create files
    # with temp names in the same directory, and the kernel only allows
    # specific filenames to be created in these particular directories.
    # This causes puppet to fail if we use the 'content' tag.
    # NOTE: Child cgroups cpuset must be subset of parent. In the case where
    # child directories already exist and we change the parent's cpuset to
    # be a subset of what the children have, will cause the command to fail
    # with "-bash: echo: write error: device or resource busy".
    if $controller == 'cpuset' {
      $cgroup_mems = "${cgroup_dir}/cpuset.mems"
      $cgroup_cpus = "${cgroup_dir}/cpuset.cpus"
      $cgroup_tasks = "${cgroup_dir}/tasks"

      notice("Set ${cgroup_name} nodeset: ${k8s_nodeset}, cpuset: ${k8s_cpuset}")
      File[ $cgroup_dir ]
      -> exec { "Create ${cgroup_mems}" :
        command => "/bin/echo ${k8s_nodeset} > ${cgroup_mems} || :",
      }
      -> exec { "Create ${cgroup_cpus}" :
        command => "/bin/echo ${k8s_cpuset} > ${cgroup_cpus} || :",
      }
      -> file { $cgroup_tasks :
        ensure => file,
        owner  => 'root',
        group  => 'root',
        mode   => '0644',
      }
    }
    if $::platform::params::distributed_cloud_role != 'systemcontroller' and $controller == 'cpu' {
      $cgroup_cpushares = "${cgroup_dir}/cpu.shares"
      File[ $cgroup_dir ]
      -> exec { "Create ${cgroup_cpushares}" :
        command => "/bin/echo ${k8s_cpushares} > ${cgroup_cpushares} || :",
      }
    }
  }
}

define platform::kubernetes::kube_command (
  $command,
  $logname,
  $environment = undef,
  $timeout = undef,
  $onlyif = undef
) {
  # Execute kubernetes command with instrumentation.
  # Note that puppet captures no command output on timeout.
  # Workaround:
  # - use 'stdbuf' to flush line buffer for stdout and stderr
  # - redirect stderr to stdout
  # - use 'tee' so we write output to both stdout and file
  # The symlink /var/log/puppet/latest points to new directory created
  # by puppet-manifest-apply.sh command.

  exec { "${title}": # lint:ignore:only_variable_string
    environment => [ $environment ],
    provider    => shell,
    command     => "stdbuf -oL -eL ${command} |& tee /var/log/puppet/latest/${logname}",
    timeout     => $timeout,
    onlyif      => $onlyif,
    logoutput   => true,
  }
}

class platform::kubernetes::kubeadm {

  include ::platform::docker::params
  include ::platform::kubernetes::params
  include ::platform::params

  # Update kubeadm/kubelet symlinks if needed.
  require platform::kubernetes::symlinks

  $node_ip = $::platform::kubernetes::params::node_ip
  $node_ip_secondary = $::platform::kubernetes::params::node_ip_secondary
  $host_labels = $::platform::kubernetes::params::host_labels
  $k8s_platform_cpuset = $::platform::kubernetes::params::k8s_platform_cpuset
  $k8s_reserved_mem = $::platform::kubernetes::params::k8s_reserved_mem
  $k8s_all_reserved_cpuset = $::platform::kubernetes::params::k8s_all_reserved_cpuset
  $k8s_cni_bin_dir = $::platform::kubernetes::params::k8s_cni_bin_dir
  $k8s_vol_plugin_dir = $::platform::kubernetes::params::k8s_vol_plugin_dir
  $k8s_cpu_mgr_policy = $::platform::kubernetes::params::k8s_cpu_mgr_policy
  $k8s_topology_mgr_policy = $::platform::kubernetes::params::k8s_topology_mgr_policy
  $k8s_pod_max_pids = $::platform::kubernetes::params::k8s_pod_max_pids
  $k8s_memory_mgr_policy = $::platform::kubernetes::params::k8s_memory_mgr_policy
  $k8s_reserved_memory = $::platform::kubernetes::params::k8s_reserved_memory


  $iptables_file = @("IPTABLE"/L)
    net.bridge.bridge-nf-call-ip6tables = 1
    net.bridge.bridge-nf-call-iptables = 1
    net.ipv4.ip_forward = 1
    net.ipv6.conf.all.forwarding = 1
    | IPTABLE

  # Configure kubelet cpumanager options
  $opts_sys_res = join(['--system-reserved=',
                        "memory=${k8s_reserved_mem}Mi"])

  if ($::personality == 'controller' and
      $::platform::params::distributed_cloud_role == 'systemcontroller') {
    $opts = '--cpu-manager-policy=none'
    $k8s_cpu_manager_opts = join([$opts,
                                  $opts_sys_res], ' ')
  } else {
    if !$::platform::params::virtual_system {
      if str2bool($::is_worker_subfunction)
        and !('openstack-compute-node=enabled' in $host_labels) {

        $opts = join(["--cpu-manager-policy=${k8s_cpu_mgr_policy}",
                      "--topology-manager-policy=${k8s_topology_mgr_policy}"], ' ')

        if $k8s_cpu_mgr_policy == 'none' {
          $k8s_reserved_cpus = $k8s_platform_cpuset
        } else {
          # The union of platform, isolated, and vswitch
          $k8s_reserved_cpus = $k8s_all_reserved_cpuset
        }

        $opts_res_cpus = "--reserved-cpus=${k8s_reserved_cpus}"

        if ( $k8s_memory_mgr_policy == 'None' ){
          $k8s_cpu_manager_opts = join([$opts,
                                        $opts_sys_res,
                                        $opts_res_cpus], ' ')
        } else {
          $opts_reserved_memory = join(["--memory-manager-policy=${k8s_memory_mgr_policy}",
                                        '--reserved-memory ',$k8s_reserved_memory], ' ')
          $k8s_cpu_manager_opts = join([$opts,
                                      $opts_sys_res,
                                      $opts_res_cpus,
                                      $opts_reserved_memory], ' ')
        }
      } else {
        $opts = '--cpu-manager-policy=none'
        $k8s_cpu_manager_opts = join([$opts,
                                      $opts_sys_res], ' ')

      }
    } else {
      $k8s_cpu_manager_opts = '--cpu-manager-policy=none'
    }
  }

  # Enable kubelet extra parameters that are node specific such as
  # cpumanager
  $kubelet_path = $::osfamily ? {
    'Debian' => '/etc/default/kubelet',
    default => '/etc/sysconfig/kubelet',
  }
  file { $kubelet_path:
    ensure  => file,
    content => template('platform/kubelet.conf.erb'),
  }
  # The cpu_manager_state file is regenerated when cpumanager starts or
  # changes allocations so it is safe to remove before kubelet starts.
  # This file persists so cpumanager's DefaultCPUSet becomes inconsistent
  # when we offline/online CPUs or change the number of reserved cpus.
  -> exec { 'remove cpu_manager_state':
    command => 'rm -f /var/lib/kubelet/cpu_manager_state || true',
  }

  # The memory_manager_state file is regenerated when memory manager starts or
  # changes allocations so it is safe to remove before kubelet starts.
  -> exec { 'remove memory_manager_state':
    command => 'rm -f /var/lib/kubelet/memory_manager_state || true',
  }

  # Update iptables config. This is required based on:
  # https://kubernetes.io/docs/tasks/tools/install-kubeadm
  # This probably belongs somewhere else - initscripts package?
  file { '/etc/sysctl.d/k8s.conf':
    ensure  => file,
    content => $iptables_file,
    owner   => 'root',
    group   => 'root',
    mode    => '0644',
  }
  -> exec { 'update kernel parameters for iptables':
    command => 'sysctl --system',
  }

  # Create manifests directory required by kubelet
  -> file { '/etc/kubernetes/manifests':
    ensure => directory,
    owner  => 'root',
    group  => 'root',
    mode   => '0700',
  }
  # Turn off --allocate-node-cidrs as pods' CIDRs address allocation is done
  # by calico (it does not uses the ones allocated by kube-controller-mgr).
  # When the cluster-pod network (used in --cluster-cidr) is the same size of
  # --node-cidr-mask-size (default is 64 for IPv6 and 24 for IPv4) it has
  # enough range to only allocate for controller-0 and starts generating
  # the event CIDRNotAvailable for the other k8s nodes.
  -> exec { 'Turn off allocate-node-cidrs in kube-controller-manager':
    command => "/bin/sed -i \\
                -e 's|allocate-node-cidrs=true|allocate-node-cidrs=false|' \\
                /etc/kubernetes/manifests/kube-controller-manager.yaml",
    onlyif  => 'test -f /etc/kubernetes/manifests/kube-controller-manager.yaml'
  }

  # A seperate enable is required since we have modified the service resource
  # to never enable services.
  -> exec { 'enable-kubelet':
    command => '/usr/bin/systemctl enable kubelet.service',
  }
  # Start kubelet if it is standard controller.
  if !str2bool($::is_worker_subfunction) {
    File['/etc/kubernetes/manifests']
    -> service { 'kubelet':
      enable => true,
    }
  }
}

class platform::kubernetes::set_crt_permissions {
  exec { 'set_permissions_on_crt_files':
    command => 'find /etc/kubernetes/pki -type f -name "*.crt" -exec chmod 600 {} +',
    onlyif  => 'find /etc/kubernetes/pki -type f -name "*.crt" ! -perm 600 | grep .',
    path    => ['/bin', '/usr/bin'],
  }
}

class platform::kubernetes::master::init
  inherits ::platform::kubernetes::params {

  include ::platform::params
  include ::platform::docker::params
  include ::platform::dockerdistribution::params
  include ::platform::k8splatform::params

  if str2bool($::is_initial_k8s_config) {
    # This allows subsequent node installs
    # Notes regarding ::is_initial_k8s_config check:
    # - Ensures block is only run for new node installs (e.g. controller-1)
    #  or reinstalls. This part is needed only once;
    # - Ansible configuration is independently configuring Kubernetes. A retry
    #   in configuration by puppet leads to failed manifest application.
    #   This flag is created by Ansible on controller-0;
    # - Ansible replay is not impacted by flag creation.

    $software_version = $::platform::params::software_version
    $local_registry_auth = "${::platform::dockerdistribution::params::registry_username}:${::platform::dockerdistribution::params::registry_password}" # lint:ignore:140chars
    $creds_command = '$(cat /tmp/puppet/registry_credentials)'

    if versioncmp(regsubst($version, '^v', ''), '1.29.0') >= 0 {
      $generate_super_conf = true
    } else {
      $generate_super_conf = false
    }

    $resource_title = 'pre pull k8s images'
    $command = "kubeadm --kubeconfig=/etc/kubernetes/admin.conf config images list --kubernetes-version ${version} | xargs -i crictl pull --creds ${creds_command} registry.local:9001/{}" # lint:ignore:140chars

    platform::kubernetes::pull_images_from_registry { 'pull images from private registry':
      resource_title      => $resource_title,
      command             => $command,
      before_exec         => undef,
      local_registry_auth => $local_registry_auth,
    }

    -> exec { 'configure master node':
      command   => $join_cmd,
      logoutput => true,
    }

    # Update ownership/permissions for file created by "kubeadm init".
    # We want it readable by sysinv and sysadmin.
    -> file { '/etc/kubernetes/admin.conf':
      ensure => file,
      owner  => 'root',
      group  => 'root',
      mode   => '0640',
    }
    -> exec { 'set_acl_on_admin_conf':
      command   => 'setfacl -m g:sys_protected:r /etc/kubernetes/admin.conf',
      logoutput => true,
    }
    # Fresh installation with Kubernetes 1.29 generates the super-admin.conf
    # only in controller-0 and not in controller-1. The following command
    # generates the super-admin.conf in controller-1.
    -> exec { 'generate the /etc/kubernetes/super-admin.conf':
      command   => 'kubeadm init phase kubeconfig super-admin',
      onlyif    => "test ${generate_super_conf} = true",
      logoutput => true,
    }

    # Add a bash profile script to set a k8s env variable
    -> file {'bash_profile_k8s':
      ensure => present,
      path   => '/etc/profile.d/kubeconfig.sh',
      mode   => '0644',
      source => "puppet:///modules/${module_name}/kubeconfig.sh"
    }

    # Remove the "master" taint from AIO master nodes. (Can be removed once the "control-plane" taint is the default.)
    -> exec { 'remove master taint from master node':
      command   => "kubectl --kubeconfig=/etc/kubernetes/admin.conf taint node ${::platform::params::hostname} node-role.kubernetes.io/master- || true", # lint:ignore:140chars
      logoutput => true,
      onlyif    => "test '${::platform::params::system_type }' == 'All-in-one'",
    }

    # Remove the "control-plane" taint from AIO control-plane nodes
    -> exec { 'remove control-plane taint from control-plane node':
      command   => "kubectl --kubeconfig=/etc/kubernetes/admin.conf taint node ${::platform::params::hostname} node-role.kubernetes.io/control-plane- || true", # lint:ignore:140chars
      logoutput => true,
      onlyif    => "test '${::platform::params::system_type }' == 'All-in-one'",
    }

    # Add kubelet service override
    -> file { '/etc/systemd/system/kubelet.service.d/kube-stx-override.conf':
      ensure  => file,
      content => template('platform/kube-stx-override.conf.erb'),
      owner   => 'root',
      group   => 'root',
      mode    => '0644',
    }

    -> file { '/etc/systemd/system/kubelet.service.d/kubelet-cpu-shares.conf':
      ensure  => file,
      content => template('platform/kubelet-cpu-shares.conf.erb'),
      owner   => 'root',
      group   => 'root',
      mode    => '0644',
    }

    # Reload systemd
    -> exec { 'perform systemctl daemon reload for kubelet override':
      command   => 'systemctl daemon-reload',
      logoutput => true,
    }
    # Mitigate systemd hung behaviour after daemon-reload
    # TODO(jgauld): Remove workaround after base OS issue resolved
    -> exec { 'verify-systemd-running - kubernetes master init':
      command   => '/usr/local/bin/verify-systemd-running.sh',
      logoutput => true,
    }
    # NOTE: --no-block is used to mitigate systemd hung behaviour
    -> exec { 'restart kubelet with overrides - kubernetes master init':
      command   => 'systemctl --no-block try-restart kubelet.service',
      logoutput => true,
    }

    # Update plugin directory for upgrade from 21.12 to 22.12 release
    # This has no impact on 22.06 to 22.12 upgrade as the directory
    # has been updated in 22.06
    # There is a separate change to update kubeadm-config configmap
    -> exec { 'Update plugin directory to /var/opt/libexec/':
      command => '/bin/sed -i "s|/usr/libexec/|/var/opt/libexec/|g" /etc/kubernetes/manifests/kube-controller-manager.yaml',
      onlyif  => "test '${software_version}' == '22.12'",
    }

    # Initial kubernetes config done on node
    -> file { '/etc/platform/.initial_k8s_config_complete':
      ensure => present,
    }
  } else {
    # K8s control plane upgrade from 1.28 to 1.29 changes the ownership/permission
    # of kube config file. We are resetting it after the control plane upgrade.
    # In case of any failure before resetting it, this sets the correct ownership/permission
    # to kube config during the host reboots after the initial install.
    file { '/etc/kubernetes/admin.conf':
      owner => 'root',
      group => 'root',
      mode  => '0640',
    }
    -> exec { 'set_acl_on_admin_conf':
      command   => 'setfacl -m g:sys_protected:r /etc/kubernetes/admin.conf',
      logoutput => true,
    }

    # Regenerate CPUShares since we may reconfigure number of platform cpus
    file { '/etc/systemd/system/kubelet.service.d/kubelet-cpu-shares.conf':
      ensure  => file,
      content => template('platform/kubelet-cpu-shares.conf.erb'),
      owner   => 'root',
      group   => 'root',
      mode    => '0644',
    }
    # Reload systemd to pick up overrides
    -> exec { 'perform systemctl daemon reload for kubelet override':
      command   => 'systemctl daemon-reload',
      logoutput => true,
    }
    # Mitigate systemd hung behaviour after daemon-reload
    # TODO(jgauld): Remove workaround after base OS issue resolved
    -> exec { 'verify-systemd-running - kubernetes master init':
      command   => '/usr/local/bin/verify-systemd-running.sh',
      logoutput => true,
    }
    # NOTE: --no-block is used to mitigate systemd hung behaviour
    -> exec { 'restart kubelet with overrides - kubernetes master init':
      command   => 'systemctl --no-block try-restart kubelet.service',
      logoutput => true,
    }

  }

  # TODO(sshathee) move this to if block for stx-10 to stx-11 upgrade
  # set kubelet to be monitored by pmond
  platform::kubernetes::pmond_kubelet_file { 'kubelet_monitoring': }

  # Run kube-cert-rotation daily
  cron { 'kube-cert-rotation':
    ensure      => 'present',
    command     => '/usr/bin/kube-cert-rotation.sh',
    environment => 'PATH=/bin:/usr/bin:/usr/sbin',
    minute      => '10',
    hour        => '*/24',
    user        => 'root',
  }

  -> class { 'platform::kubernetes::set_crt_permissions': }
}

class platform::kubernetes::master
  inherits ::platform::kubernetes::params {

  include ::platform::k8splatform

  contain ::platform::kubernetes::kubeadm
  contain ::platform::kubernetes::cgroup
  contain ::platform::kubernetes::master::init
  contain ::platform::kubernetes::coredns
  contain ::platform::kubernetes::firewall
  contain ::platform::kubernetes::configuration

  Class['::platform::sysctl::controller::reserve_ports'] -> Class[$name]
  Class['::platform::k8splatform'] -> Class[$name]
  Class['::platform::etcd'] -> Class[$name]
  Class['::platform::docker::config'] -> Class[$name]
  Class['::platform::containerd::config'] -> Class[$name]
  # Ensure DNS is configured as name resolution is required when
  # kubeadm init is run.
  Class['::platform::dns'] -> Class[$name]
  Class['::platform::kubernetes::configuration']
  -> Class['::platform::kubernetes::kubeadm']
  -> Class['::platform::kubernetes::cgroup']
  -> Class['::platform::kubernetes::master::init']
  -> Class['::platform::kubernetes::coredns']
  -> Class['::platform::kubernetes::firewall']
}

class platform::kubernetes::worker::init
  inherits ::platform::kubernetes::params {
  include ::platform::dockerdistribution::params
  include ::platform::k8splatform::params

  Class['::platform::k8splatform'] -> Class[$name]
  Class['::platform::docker::config'] -> Class[$name]
  Class['::platform::containerd::config'] -> Class[$name]
  Class['::platform::filesystem::kubelet'] -> Class[$name]

  if str2bool($::is_initial_config) {
    # Pull pause image tag from kubeadm required images list for this version
    # kubeadm config images list does not use the --kubeconfig argument
    # and admin.conf will not exist on a pure worker, and kubelet.conf will not
    # exist until after a join.
    $local_registry_auth = "${::platform::dockerdistribution::params::registry_username}:${::platform::dockerdistribution::params::registry_password}" # lint:ignore:140chars
    $creds_command = '$(cat /tmp/puppet/registry_credentials)'

    $resource_title = 'load k8s pause image by containerd'
    $command = "kubeadm config images list --kubernetes-version ${version} 2>/dev/null | grep pause: | xargs -i crictl pull --creds ${creds_command} registry.local:9001/{}" # lint:ignore:140chars
    $before_exec = 'configure worker node'

    platform::kubernetes::pull_images_from_registry { 'pull images from private registry':
      resource_title      => $resource_title,
      command             => $command,
      before_exec         => $before_exec,
      local_registry_auth => $local_registry_auth,
    }

  }

  # Configure the worker node. Only do this once, so check whether the
  # kubelet.conf file has already been created (by the join).
  exec { 'configure worker node':
    command   => $join_cmd,
    logoutput => true,
    unless    => 'test -f /etc/kubernetes/kubelet.conf',
  }

  # Add kubelet service override
  -> file { '/etc/systemd/system/kubelet.service.d/kube-stx-override.conf':
    ensure  => file,
    content => template('platform/kube-stx-override.conf.erb'),
    owner   => 'root',
    group   => 'root',
    mode    => '0644',
  }

  # Regenerate CPUShares since we may reconfigure number of platform cpus
  -> file { '/etc/systemd/system/kubelet.service.d/kubelet-cpu-shares.conf':
    ensure  => file,
    content => template('platform/kubelet-cpu-shares.conf.erb'),
    owner   => 'root',
    group   => 'root',
    mode    => '0644',
  }

  # set kubelet to be monitored by pmond
  platform::kubernetes::pmond_kubelet_file { 'kubelet_monitoring': }

  # Reload systemd to pick up overrides
  -> exec { 'perform systemctl daemon reload for kubelet override':
    command   => 'systemctl daemon-reload',
    logoutput => true,
  }
  # Mitigate systemd hung behaviour after daemon-reload
  # TODO(jgauld): Remove workaround after base OS issue resolved
  -> exec { 'verify-systemd-running - kubernetes worker init':
    command   => '/usr/local/bin/verify-systemd-running.sh',
    logoutput => true,
  }
  # NOTE: --no-block is used to mitigate systemd hung behaviour
  -> exec { 'restart kubelet with overrides - kubernetes worker init':
    command   => 'systemctl --no-block try-restart kubelet.service',
    logoutput => true,
  }
}

class platform::kubernetes::worker::pci
(
  $pcidp_resources = undef,
) {
  include ::platform::kubernetes::params

  file { '/etc/pcidp':
    ensure => 'directory',
    owner  => 'root',
    group  => 'root',
    mode   => '0700',
  }
  -> file { '/etc/pcidp/config.json':
    ensure  => present,
    owner   => 'root',
    group   => 'root',
    mode    => '0644',
    content => template('platform/pcidp.conf.erb'),
  }
}

class platform::kubernetes::worker::pci::runtime {
  include ::platform::kubernetes::worker::pci
  include ::platform::kubernetes::worker::sriovdp
}

class platform::kubernetes::worker::sriovdp {
  include ::platform::kubernetes::params
  include ::platform::params
  $host_labels = $::platform::kubernetes::params::host_labels
  if ($::personality == 'controller') and
      str2bool($::is_worker_subfunction)
      and ('sriovdp=enabled' in $host_labels) {
    exec { 'Delete sriov device plugin pod if present':
      path      => '/usr/bin:/usr/sbin:/bin',
      command   => 'kubectl --kubeconfig=/etc/kubernetes/admin.conf delete pod -n kube-system --selector=app=sriovdp --field-selector spec.nodeName=$(hostname) --timeout=360s', # lint:ignore:140chars
      onlyif    => 'kubectl --kubeconfig=/etc/kubernetes/admin.conf get pods -n kube-system --selector=app=sriovdp --field-selector spec.nodeName=$(hostname) | grep kube-sriov-device-plugin', # lint:ignore:140chars
      logoutput => true,
    }
  }
}

class platform::kubernetes::worker
  inherits ::platform::kubernetes::params {

  # Worker configuration is not required on AIO hosts, since the master
  # will already be configured and includes support for running pods.
  if $::personality != 'controller' {
    contain ::platform::kubernetes::kubeadm
    contain ::platform::kubernetes::cgroup
    contain ::platform::kubernetes::worker::init
    contain ::platform::kubernetes::configuration

    Class['::platform::kubernetes::configuration']
    -> Class['::platform::kubernetes::kubeadm']
    -> Class['::platform::kubernetes::cgroup']
    -> Class['::platform::kubernetes::worker::init']
  }

  # Enable kubelet on AIO and worker nodes.
  Class['::platform::compute::allocate']
  -> service { 'kubelet':
    enable => true,
  }

  # TODO: The following exec is a workaround. Once kubernetes becomes the
  # default installation, /etc/pmon.d/libvirtd.conf needs to be removed from
  # the load.
  exec { 'Update PMON libvirtd.conf':
    command => "/bin/sed -i 's#mode  = passive#mode  = ignore #' /etc/pmon.d/libvirtd.conf",
    onlyif  => '/usr/bin/test -e /etc/pmon.d/libvirtd.conf'
  }

  contain ::platform::kubernetes::worker::pci
}

class platform::kubernetes::aio
  inherits ::platform::kubernetes::params {

  include ::platform::params
  include ::platform::kubernetes::master
  include ::platform::kubernetes::worker

  if $::platform::params::distributed_cloud_role != 'systemcontroller' {
    $kubelet_max_procs = $::platform::params::eng_workers

    # Set kubelet GOMAXPROCS environment variable
    file { '/etc/systemd/system/kubelet.service.d/kubelet-max-procs.conf':
      ensure  => file,
      content => template('platform/kubelet-max-procs.conf.erb'),
      owner   => 'root',
      group   => 'root',
      mode    => '0644',
    }
  }

  Class['::platform::kubernetes::master']
  -> Class['::platform::kubernetes::worker']
  -> Class[$name]
}

class platform::kubernetes::gate {
  if $::platform::params::system_type != 'All-in-one' {
    Class['::platform::kubernetes::master'] -> Class[$name]
  } else {
    Class['::platform::kubernetes::aio'] -> Class[$name]
  }
}

class platform::kubernetes::coredns::duplex {
  # For duplex and multi-node system, restrict the dns pod to control-plane nodes
  exec { 'restrict coredns to control-plane nodes':
    command   => 'kubectl --kubeconfig=/etc/kubernetes/admin.conf -n kube-system patch deployment coredns -p \'{"spec":{"template":{"spec":{"nodeSelector":{"node-role.kubernetes.io/control-plane":""}}}}}\'', # lint:ignore:140chars
    logoutput => true,
  }

  -> exec { 'Use anti-affinity for coredns pods':
    command   => 'kubectl --kubeconfig=/etc/kubernetes/admin.conf -n kube-system patch deployment coredns -p \'{"spec":{"template":{"spec":{"affinity":{"podAntiAffinity":{"requiredDuringSchedulingIgnoredDuringExecution":[{"labelSelector":{"matchExpressions":[{"key":"k8s-app","operator":"In","values":["kube-dns"]}]},"topologyKey":"kubernetes.io/hostname"}]}}}}}}\'', # lint:ignore:140chars
    logoutput => true,
  }
}

class platform::kubernetes::coredns::simplex {
  # For simplex system, 1 coredns is enough
  exec { '1 coredns for simplex mode':
    command   => 'kubectl --kubeconfig=/etc/kubernetes/admin.conf -n kube-system scale --replicas=1 deployment coredns',
    logoutput => true,
  }
}

class platform::kubernetes::coredns {

  include ::platform::params

  if str2bool($::is_initial_k8s_config) {
    if $::platform::params::system_mode != 'simplex' {
      contain ::platform::kubernetes::coredns::duplex
    } else {
      contain ::platform::kubernetes::coredns::simplex
    }
  }
}

# TODO: remove port 9001 once we have a public docker image registry using standard ports.
# add 5000 as the default port for private registry
# Ports are not being included in the iptables rules created.
class platform::kubernetes::firewall::params (
  $transport = 'all',
  $table = 'nat',
  $dports = [80, 443, 9001, 5000],
  $chain = 'POSTROUTING',
  $jump = 'SNAT',
) {}

class platform::kubernetes::firewall
  inherits ::platform::kubernetes::firewall::params {

  include ::platform::params
  include ::platform::network::oam::params
  include ::platform::network::mgmt::params
  include ::platform::docker::params

  # add http_proxy and https_proxy port to k8s firewall
  # in order to allow worker node access public network via proxy
  if $::platform::docker::params::http_proxy {
    $http_proxy_str_array = split($::platform::docker::params::http_proxy, ':')
    $http_proxy_port = $http_proxy_str_array[length($http_proxy_str_array) - 1]
    if $http_proxy_port =~ /^\d+$/ {
      $http_proxy_port_val = $http_proxy_port
    }
  }

  if $::platform::docker::params::https_proxy {
    $https_proxy_str_array = split($::platform::docker::params::https_proxy, ':')
    $https_proxy_port = $https_proxy_str_array[length($https_proxy_str_array) - 1]
    if $https_proxy_port =~ /^\d+$/ {
      $https_proxy_port_val = $https_proxy_port
    }
  }

  if defined('$http_proxy_port_val') {
    if defined('$https_proxy_port_val') and ($http_proxy_port_val != $https_proxy_port_val) {
      $dports = $dports << $http_proxy_port_val << $https_proxy_port_val
    } else {
      $dports = $dports << $http_proxy_port_val
    }
  } elsif defined('$https_proxy_port_val') {
    $dports = $dports << $https_proxy_port_val
  }

  $system_mode = $::platform::params::system_mode
  $oam_float_ip = $::platform::network::oam::params::controller_address
  $oam_interface = $::platform::network::oam::params::interface_name
  $mgmt_subnet = $::platform::network::mgmt::params::subnet_network
  $mgmt_prefixlen = $::platform::network::mgmt::params::subnet_prefixlen

  $s_mgmt_subnet = "${mgmt_subnet}/${mgmt_prefixlen}"
  $d_mgmt_subnet = "! ${s_mgmt_subnet}"

  if $system_mode != 'simplex' {
    platform::firewall::rule { 'kubernetes-nat':
      service_name => 'kubernetes',
      table        => $table,
      chain        => $chain,
      proto        => $transport,
      jump         => $jump,
      host         => $s_mgmt_subnet,
      destination  => $d_mgmt_subnet,
      outiface     => $oam_interface,
      tosource     => $oam_float_ip,
    }
  }
}

class platform::kubernetes::pre_pull_control_plane_images
  inherits ::platform::kubernetes::params {
  include ::platform::dockerdistribution::params

  $local_registry_auth = "${::platform::dockerdistribution::params::registry_username}:${::platform::dockerdistribution::params::registry_password}" # lint:ignore:140chars
  $creds_command = '$(cat /tmp/puppet/registry_credentials)'

  $resource_title = 'pre pull images'
  $command = "/usr/local/kubernetes/${kubeadm_version}/stage1/usr/bin/kubeadm --kubeconfig=/etc/kubernetes/admin.conf config images list --kubernetes-version ${kubeadm_version} | xargs -i crictl pull --creds ${creds_command} registry.local:9001/{}" # lint:ignore:140chars

  # Disable garbage collection so that we don't accidentally lose any of the images we're about to download.
  exec { 'disable image garbage collection':
    command   => 'bash /usr/share/puppet/modules/platform/files/disable_image_gc.sh',
  }

  -> platform::kubernetes::pull_images_from_registry { 'pull images from private registry':
    resource_title      => $resource_title,
    command             => $command,
    before_exec         => undef,
    local_registry_auth => $local_registry_auth,
  }
}

define platform::kubernetes::patch_coredns_kubeproxy_serviceaccount($current_version) {
  if versioncmp(regsubst($current_version, '^v', ''), '1.30.0') >= 0 {
    exec { 'Patch pull secret into kube-proxy service account':
      command   => 'kubectl --kubeconfig=/etc/kubernetes/admin.conf -n kube-system patch serviceaccount kube-proxy -p \'{"imagePullSecrets": [{"name": "registry-local-secret"}]}\'', # lint:ignore:140chars
      logoutput => true,
      }
    -> exec { 'Patch pull secret into coredns service account':
        command   => 'kubectl --kubeconfig=/etc/kubernetes/admin.conf -n kube-system patch serviceaccount coredns -p \'{"metadata": {"labels": {"kubernetes.io/cluster-service": "true","addonmanager.kubernetes.io/mode": "Reconcile"}},"imagePullSecrets": [{"name": "default-registry-key"}]}\'', # lint:ignore:140chars
        logoutput => true,
      }
    -> exec { 'Restart the coredns and kube-proxy pods':
        command   => 'kubectl --kubeconfig=/etc/kubernetes/admin.conf rollout restart deployment coredns -n kube-system && kubectl --kubeconfig=/etc/kubernetes/admin.conf rollout restart daemonset kube-proxy -n kube-system', # lint:ignore:140chars
        logoutput => true,
      }
  }
}

class platform::kubernetes::upgrade_first_control_plane
  inherits ::platform::kubernetes::params {

  include ::platform::params

  # Update kubeadm symlink if needed.
  require platform::kubernetes::symlinks

  # The kubeadm command below doesn't have the credentials to download the
  # images from local registry when they are not present in the cache, so we
  # assure here that the images are downloaded.
  require platform::kubernetes::pre_pull_control_plane_images

  # The --allow-*-upgrades options allow us to upgrade to any k8s release if necessary
  # The -v6 gives verbose debug output includes health, GET response, delay.
  # Since we hit default 300 second timeout under load (i.e., upgrade 250 subclouds
  # in parallel), specify larger timeout.
  platform::kubernetes::kube_command { 'upgrade first control plane':
    command     => "kubeadm -v6 upgrade apply ${version} \
                    --allow-experimental-upgrades --allow-release-candidate-upgrades -y",
    logname     => 'kubeadm-upgrade-apply.log',
    environment => 'KUBECONFIG=/etc/kubernetes/admin.conf',
    timeout     => 210,
  }
  -> exec { 'purge all kubelet-config except most recent':
      environment => [ 'KUBECONFIG=/etc/kubernetes/admin.conf' ],
      command     => 'kubectl -n kube-system get configmaps -oname --sort-by=.metadata.creationTimestamp | grep -e kubelet-config | head -n -1 | xargs -r -i kubectl -n kube-system delete {}', # lint:ignore:140chars
      logoutput   => true,
  }
  # Control plane upgrade from 1.28 to 1.29 changed the ownership and permission
  # of kube config file. Setting the ownership & permission to the old state.
  # This issue not present in the fresh install with K8s 1.29.
  -> file { '/etc/kubernetes/admin.conf':
    owner => 'root',
    group => 'root',
    mode  => '0640',
  }
  -> exec { 'set_acl_on_admin_conf':
    command   => 'setfacl -m g:sys_protected:r /etc/kubernetes/admin.conf',
    logoutput => true,
  }

  if $::platform::params::system_mode != 'simplex' {
    # For duplex and multi-node system, restrict the coredns pod to control-plane nodes
    exec { 'restrict coredns to control-plane nodes':
      command   => 'kubectl --kubeconfig=/etc/kubernetes/admin.conf -n kube-system patch deployment coredns -p \'{"spec":{"template":{"spec":{"nodeSelector":{"node-role.kubernetes.io/control-plane":""}}}}}\'', # lint:ignore:140chars
      logoutput => true,
      require   => Exec['upgrade first control plane']
    }
    -> exec { 'Use anti-affinity for coredns pods':
      command   => 'kubectl --kubeconfig=/etc/kubernetes/admin.conf -n kube-system patch deployment coredns -p \'{"spec":{"template":{"spec":{"affinity":{"podAntiAffinity":{"requiredDuringSchedulingIgnoredDuringExecution":[{"labelSelector":{"matchExpressions":[{"key":"k8s-app","operator":"In","values":["kube-dns"]}]},"topologyKey":"kubernetes.io/hostname"}]}}}}}}\'', # lint:ignore:140chars
      logoutput => true,
    }
  } else {
    # For simplex system, 1 coredns is enough
    exec { '1 coredns for simplex mode':
      command   => 'kubectl --kubeconfig=/etc/kubernetes/admin.conf -n kube-system scale --replicas=1 deployment coredns',
      logoutput => true,
      require   => Exec['upgrade first control plane']
    }
  }
  # Upgrading the K8s control plane from version 1.29 to 1.30
  # resets the configurations of the CoreDNS and kube-proxy service accounts.
  # The following change will restore the configurations for these service accounts.
  -> platform::kubernetes::patch_coredns_kubeproxy_serviceaccount { 'patch_serviceaccount':
      current_version => $version
  }
}

class platform::kubernetes::upgrade_control_plane
  inherits ::platform::kubernetes::params {

  # Update kubeadm symlink if needed.
  require platform::kubernetes::symlinks

  # The kubeadm command below doesn't have the credentials to download the
  # images from local registry when they are not present in the cache, so we
  # assure here that the images are downloaded.
  require platform::kubernetes::pre_pull_control_plane_images

  if versioncmp(regsubst($version, '^v', ''), '1.29.0') >= 0 {
    $generate_conf = true
  } else {
    $generate_conf = false
  }

  # control plane is only upgraded on a controller
  # The -v6 gives verbose debug output includes health, GET response, delay.
  platform::kubernetes::kube_command { 'upgrade_control_plane':
    command     => 'kubeadm -v6 upgrade node',
    logname     => 'kubeadm-upgrade-node.log',
    environment => 'KUBECONFIG=/etc/kubernetes/admin.conf:/etc/kubernetes/kubelet.conf',
    timeout     => 210,
  }

  # K8s control plane upgrade from 1.28 to 1.29 generates the super-admin.conf
  # only on the active controller, not on the standby controller. The following
  # command creates the super-admin.conf on the standby controller.
  -> exec { 'generate super-admin.conf during kubernetes upgrade':
    command   => 'kubeadm init phase kubeconfig super-admin',
    onlyif    => "test ${generate_conf} = true && test ! -f /etc/kubernetes/super-admin.conf",
    logoutput => true,
  }

  # Upgrading the K8s control plane from version 1.29 to 1.30
  # resets the configurations of the CoreDNS and kube-proxy service accounts.
  # The following change will restore the configurations for these service accounts.
  -> platform::kubernetes::patch_coredns_kubeproxy_serviceaccount { 'patch_serviceaccount':
      current_version => $version
  }
}

# Define for unmasking and starting a service
define platform::kubernetes::unmask_start_service($service_name, $onlyif = undef) {
  # Unmask the service and start it now
  exec { "unmask ${service_name}":
    command => "/usr/bin/systemctl unmask --runtime ${service_name}",
    onlyif  => $onlyif,
  }
  # Tell pmon to start monitoring the service
  -> exec { "start ${service_name} for upgrade":
    command => "/usr/local/sbin/pmon-start ${service_name}",
    onlyif  => $onlyif,
  }
  # Start the service if not running
  -> exec { "start ${service_name} if not running":
    command => "/usr/bin/systemctl start ${service_name}",
    unless  => "systemctl is-active ${service_name} | grep -wq active",
    onlyif  => "systemctl is-enabled ${service_name} | grep -wq enabled",
  }
}

# Define for masking and stopping a service
define platform::kubernetes::mask_stop_service($service_name, $onlyif = undef) {
  # Mask the service and stop it now
  exec { "mask ${service_name}":
    command => "/usr/bin/systemctl mask --runtime --now ${service_name}",
    onlyif  => $onlyif,
  }
  # Tell pmon to stop the service so it doesn't try to restart it
  -> exec { "stop ${service_name} for upgrade":
    command => "/usr/local/sbin/pmon-stop ${service_name}",
    onlyif  => $onlyif,
  }
}

class platform::kubernetes::mask_stop_kubelet {
  # Mask and stop isolcpu_plugin service first if it is configured to run
  # on this node
  platform::kubernetes::mask_stop_service { 'isolcpu_plugin':
    service_name => 'isolcpu_plugin',
    onlyif       => 'systemctl is-enabled isolcpu_plugin.service | grep -wq enabled',
  }

  # Mask restarting kubelet and stop it now so that we can update the symlink.
  -> platform::kubernetes::mask_stop_service { 'kubelet':
    service_name => 'kubelet',
  }
}

class platform::kubernetes::containerd_pause_image (
  String $kubeadm_version = $::platform::kubernetes::params::kubeadm_version
) {

  exec { 'set containerd sandbox pause image':
    command   => "/usr/local/kubernetes/${kubeadm_version}/stage1/usr/bin/kubeadm config images list --kubernetes-version ${kubeadm_version} 2>/dev/null | grep pause: | xargs -I '{}' sed -i -e '/sandbox_image =/ s|= .*|= \"registry.local:9001/{}\"|' /etc/containerd/config.toml", # lint:ignore:140chars
    logoutput => true
  }
}

class platform::kubernetes::unmask_start_kubelet
  inherits ::platform::kubernetes::params {

  # Update kubelet symlink if needed.
  include platform::kubernetes::symlinks

  $kubelet_version = $::platform::kubernetes::params::kubelet_version
  $short_upgrade_to_version = regsubst($upgrade_to_version, '^v(.*)', '\1')

  # Reload configs since /etc/systemd/system/kubelet.service.d/kubeadm.conf
  # is a symlink to a versioned file.  (In practice it rarely changes.)
  exec { 'Reload systemd configs for master upgrade':
    command => '/usr/bin/systemctl daemon-reload',
    require => File['/var/lib/kubernetes/stage2'],
  }
  # Mitigate systemd hung behaviour after daemon-reload
  # TODO(jgauld): Remove workaround after base OS issue resolved
  -> exec { 'verify-systemd-running - unmask start kubelet':
    command   => '/usr/local/bin/verify-systemd-running.sh',
    logoutput => true,
  }


  # In case we're upgrading K8s, remove any image GC override and revert to defaults.
  # We only want to do this here for duplex systems, for simplex we'll do it at the uncordon.
  # NOTE: we'll need to modify this when we bring in optimised multi-version K8s upgrades for duplex.
  -> exec { 're-enable default image garbage collect':
      command => '/usr/bin/sed -i "s/--image-gc-high-threshold 100 //" /var/lib/kubelet/kubeadm-flags.env',
      onlyif  => "test '${kubelet_version}' = '${short_upgrade_to_version}'"
  }

  # Unmask and start kubelet after the symlink is updated.
  -> platform::kubernetes::unmask_start_service { 'kubelet':
    service_name => 'kubelet',
    require      => File['/var/lib/kubernetes/stage2'],
  }

  # Unmask and start isolcpu_plugin service last
  -> platform::kubernetes::unmask_start_service { 'isolcpu_plugin':
    service_name => 'isolcpu_plugin',
    onlyif       => 'systemctl is-enabled isolcpu_plugin | grep -wq masked',
  }
}

class platform::kubernetes::master::upgrade_kubelet
  inherits ::platform::kubernetes::params {
    include platform::kubernetes::containerd_pause_image
    include platform::kubernetes::mask_stop_kubelet
    include platform::kubernetes::unmask_start_kubelet



    Class['platform::kubernetes::mask_stop_kubelet']
    -> Class['platform::kubernetes::containerd_pause_image']
    -> Class['platform::kubernetes::unmask_start_kubelet']
}

class platform::kubernetes::worker::upgrade_kubelet
  inherits ::platform::kubernetes::params {
  include ::platform::dockerdistribution::params
  include platform::kubernetes::containerd_pause_image
  include platform::kubernetes::mask_stop_kubelet
  include platform::kubernetes::unmask_start_kubelet

  # workers use kubelet.conf rather than admin.conf
  $kubelet_version = $::platform::kubernetes::params::kubelet_version
  $kubeadm_version = $::platform::kubernetes::params::kubeadm_version # lint:ignore:140chars
  $local_registry_auth = "${::platform::dockerdistribution::params::registry_username}:${::platform::dockerdistribution::params::registry_password}" # lint:ignore:140chars
  $creds_command = '$(cat /tmp/puppet/registry_credentials)'

  $resource_title = 'pull pause image'
  # Use the upgrade version of kubeadm and kubelet to ensure we get the proper image versions.
  $command = "/usr/local/kubernetes/${kubeadm_version}/stage1/usr/bin/kubeadm --kubeconfig=/etc/kubernetes/kubelet.conf config images list --kubernetes-version ${kubelet_version} 2>/dev/null | grep pause: | xargs -i crictl pull --creds ${creds_command} registry.local:9001/{}" # lint:ignore:140chars
  $before_exec = 'upgrade kubelet for worker'

  platform::kubernetes::pull_images_from_registry { 'pull images from private registry':
    resource_title      => $resource_title,
    command             => $command,
    before_exec         => $before_exec,
    local_registry_auth => $local_registry_auth,
  }

  platform::kubernetes::kube_command { 'upgrade kubelet for worker':
    # Use the upgrade version of kubeadm in case the kubeadm configmap format has changed.
    # The -v6 gives verbose debug output includes health, GET response, delay.
    command     => "/usr/local/kubernetes/${kubeadm_version}/stage1/usr/bin/kubeadm -v6 upgrade node",
    logname     => 'kubeadm-upgrade-node.log',
    environment => 'KUBECONFIG=/etc/kubernetes/kubelet.conf',
    timeout     => 300,
  }
  -> Class['platform::kubernetes::mask_stop_kubelet']
  -> Class['platform::kubernetes::containerd_pause_image']
  -> Class['platform::kubernetes::unmask_start_kubelet']

}

class platform::kubernetes::master::change_apiserver_parameters (
  $etcd_cafile = $platform::kubernetes::params::etcd_cafile,
  $etcd_certfile = $platform::kubernetes::params::etcd_certfile,
  $etcd_keyfile = $platform::kubernetes::params::etcd_keyfile,
  $etcd_servers = $platform::kubernetes::params::etcd_servers,
) inherits ::platform::kubernetes::params {
  include ::platform::params
  include ::platform::network::cluster_host::params

  if $::platform::params::hostname == 'controller-0' {
    $cluster_host_addr = $::platform::network::cluster_host::params::controller0_address
  } else {
    $cluster_host_addr = $::platform::network::cluster_host::params::controller1_address
  }

  # Update ownership/permissions for files.
  # We want it readable by sysinv and sysadmin.
  file { '/tmp/puppet/hieradata/':
    ensure  => directory,
    owner   => 'root',
    group   => $::platform::params::protected_group_name,
    mode    => '0444',
    recurse => true,
  }

  file { '/etc/kubernetes/backup/':
    ensure  => directory,
    owner   => 'root',
    group   => $::platform::params::protected_group_name,
    mode    => '0444',
    recurse => true,
  }

  # Ensure backup is created first time
  exec { 'create configmap backup':
    command   => 'kubectl --kubeconfig=/etc/kubernetes/admin.conf get cm -n kube-system kubeadm-config -o=yaml > /etc/kubernetes/backup/configmap.yaml', # lint:ignore:140chars
    logoutput => true,
    unless    => 'test -e /etc/kubernetes/backup/configmap.yaml',
  }

  exec { 'create cluster_config backup':
    command   => 'kubectl --kubeconfig=/etc/kubernetes/admin.conf get cm -n kube-system kubeadm-config -o=jsonpath={.data.ClusterConfiguration} > /etc/kubernetes/backup/cluster_config.yaml', # lint:ignore:140chars
    logoutput => true,
    unless    => 'test -e /etc/kubernetes/backup/cluster_config.yaml',
  }

  if $etcd_cafile and $etcd_certfile and $etcd_keyfile and $etcd_servers {
    exec { 'update configmap and apply changes to control plane components':
      command => "python /usr/share/puppet/modules/platform/files/change_k8s_control_plane_params.py --etcd_cafile ${etcd_cafile} --etcd_certfile ${etcd_certfile} --etcd_keyfile ${etcd_keyfile} --etcd_servers ${etcd_servers} ${cluster_host_addr} ${::is_controller_active}",  # lint:ignore:140chars
      timeout => 600}
  } else {
    exec { 'update configmap and apply changes to control plane components':
      command => "python /usr/share/puppet/modules/platform/files/change_k8s_control_plane_params.py ${cluster_host_addr} ${::is_controller_active}",  # lint:ignore:140chars
      timeout => 600}
  }
}

class platform::kubernetes::certsans::runtime
  inherits ::platform::kubernetes::params {
  include ::platform::params
  include ::platform::network::mgmt::params
  include ::platform::network::mgmt::ipv4::params
  include ::platform::network::mgmt::ipv6::params
  include ::platform::network::oam::params
  include ::platform::network::oam::ipv4::params
  include ::platform::network::oam::ipv6::params
  include ::platform::network::cluster_host::params
  include ::platform::network::cluster_host::ipv4::params
  include ::platform::network::cluster_host::ipv6::params

  $ipv4_val = $::platform::params::ipv4
  $ipv6_val = $::platform::params::ipv6

  $prim_mgmt_subnet_ver = $::platform::network::mgmt::params::subnet_version
  $ipv4_mgmt_subnet_ver = $::platform::network::mgmt::ipv4::params::subnet_version
  $ipv6_mgmt_subnet_ver = $::platform::network::mgmt::ipv6::params::subnet_version
  if $prim_mgmt_subnet_ver == $ipv6_val and $ipv4_mgmt_subnet_ver != undef {
    $sec_mgmt_subnet_ver = $ipv4_mgmt_subnet_ver
  } elsif $prim_mgmt_subnet_ver == $ipv4_val and $ipv6_mgmt_subnet_ver != undef {
    $sec_mgmt_subnet_ver = $ipv6_mgmt_subnet_ver
  } else {
    $sec_mgmt_subnet_ver = undef
  }

  $prim_cluster_host_subnet_ver = $::platform::network::cluster_host::params::subnet_version
  $ipv4_cluster_host_subnet_ver = $::platform::network::cluster_host::ipv4::params::subnet_version
  $ipv6_cluster_host_subnet_ver = $::platform::network::cluster_host::ipv6::params::subnet_version
  if $prim_cluster_host_subnet_ver == $ipv6_val and $ipv4_cluster_host_subnet_ver != undef {
    $sec_cluster_host_subnet_ver = $ipv4_cluster_host_subnet_ver
  } elsif $prim_cluster_host_subnet_ver == $ipv4_val and $ipv6_cluster_host_subnet_ver != undef {
    $sec_cluster_host_subnet_ver = $ipv6_cluster_host_subnet_ver
  } else {
    $sec_cluster_host_subnet_ver = undef
  }

  $prim_oam_subnet_ver = $::platform::network::oam::params::subnet_version
  $ipv4_oam_subnet_ver = $::platform::network::oam::ipv4::params::subnet_version
  $ipv6_oam_subnet_ver = $::platform::network::oam::ipv6::params::subnet_version
  if $prim_oam_subnet_ver == $ipv6_val and $ipv4_oam_subnet_ver != undef {
    $sec_oam_subnet_ver = $ipv4_oam_subnet_ver
  } elsif $prim_oam_subnet_ver == $ipv4_val and $ipv6_oam_subnet_ver != undef {
    $sec_oam_subnet_ver = $ipv6_oam_subnet_ver
  } else {
    $sec_oam_subnet_ver = undef
  }

  if $::platform::network::mgmt::params::subnet_version == $ipv6_val {
    $localhost_address = '::1'
  } else {
    $localhost_address = '127.0.0.1'
  }

  if $sec_mgmt_subnet_ver != undef {
    if $sec_mgmt_subnet_ver == $ipv4_val {
      $certsans_sec_localhost_array = ['127.0.0.1']
    } elsif $sec_mgmt_subnet_ver == $ipv6_val {
      $certsans_sec_localhost_array = ['::1']
    }
  } else {
    $certsans_sec_localhost_array = []
  }

  if $::platform::params::system_mode == 'simplex' {

    # primary addresses
    $primary_floating_array = [$::platform::network::cluster_host::params::controller_address,
                                $::platform::network::oam::params::controller_address,
                                $localhost_address]
    if ($::platform::network::cluster_host::params::controller0_address != undef) {
      $primary_unit_cluster_array = [$::platform::network::cluster_host::params::controller0_address]
    } else {
      $primary_unit_cluster_array = []
    }
    $certsans_prim_array = $primary_floating_array + $primary_unit_cluster_array

    # secondary addresses: OAM
    if $sec_oam_subnet_ver == $ipv4_val {
      $certsans_oam_sec_array = [$::platform::network::oam::ipv4::params::controller_address]
    } elsif $sec_oam_subnet_ver == $ipv6_val {
      $certsans_oam_sec_array = [$::platform::network::oam::ipv6::params::controller_address]
    } else {
      $certsans_oam_sec_array = []
    }

    if $sec_cluster_host_subnet_ver == $ipv4_val {

      $sec_cluster_float_array = [$::platform::network::cluster_host::ipv4::params::controller_address]
      if ($::platform::network::cluster_host::ipv4::params::controller0_address != undef) {
        $sec_cluster_unit_array = [$::platform::network::cluster_host::ipv4::params::controller0_address]
      } else {
        $sec_cluster_unit_array = []
      }
      $certsans_cluster_sec_array = $sec_cluster_float_array + $sec_cluster_unit_array

    } elsif $sec_cluster_host_subnet_ver == $ipv6_val {

      $sec_cluster_float_array = [$::platform::network::cluster_host::ipv6::params::controller_address]
      if ($::platform::network::cluster_host::ipv6::params::controller0_address != undef) {
        $sec_cluster_unit_array = [$::platform::network::cluster_host::ipv6::params::controller0_address]
      } else {
        $sec_cluster_unit_array = []
      }
      $certsans_cluster_sec_array = $sec_cluster_float_array + $sec_cluster_unit_array

    } else {
      $certsans_cluster_sec_array = []
    }
    $certsans_sec_hosts_array = $certsans_oam_sec_array + $certsans_cluster_sec_array + $certsans_sec_localhost_array

  } else {
    $primary_floating_array = [$::platform::network::cluster_host::params::controller_address,
                                $::platform::network::oam::params::controller_address,
                                $localhost_address]

    # primary OAM unit addresses
    if ($::platform::network::oam::params::controller0_address != undef) and
        ($::platform::network::oam::params::controller1_address != undef) {
      $primary_unit_oam_array = [$::platform::network::oam::params::controller0_address,
                                  $::platform::network::oam::params::controller1_address]
    } elsif ($::platform::network::oam::params::controller0_address != undef) and
            ($::platform::network::oam::params::controller1_address == undef) {
      $primary_unit_oam_array = [$::platform::network::oam::params::controller0_address]
    } elsif ($::platform::network::oam::params::controller0_address == undef) and
            ($::platform::network::oam::params::controller1_address != undef) {
      $primary_unit_oam_array = [$::platform::network::oam::params::controller1_address]
    } else {
      $primary_unit_oam_array = []
    }

    # primary Cluster-host unit addresses
    if ($::platform::network::cluster_host::params::controller0_address != undef) and
        ($::platform::network::cluster_host::params::controller0_address != undef) {
      $primary_unit_cluster_array = [$::platform::network::cluster_host::params::controller0_address,
                                      $::platform::network::cluster_host::params::controller1_address]
    } elsif ($::platform::network::cluster_host::params::controller0_address != undef) and
            ($::platform::network::cluster_host::params::controller1_address == undef) {
      $primary_unit_cluster_array = [$::platform::network::cluster_host::params::controller0_address]
    } elsif ($::platform::network::cluster_host::params::controller0_address == undef) and
            ($::platform::network::cluster_host::params::controller1_address != undef) {
      $primary_unit_cluster_array = [$::platform::network::cluster_host::params::controller1_address]
    } else {
      $primary_unit_cluster_array = []
    }

    $certsans_prim_array = $primary_floating_array + $primary_unit_oam_array + $primary_unit_cluster_array

    # secondary OAM addresses
    if $sec_oam_subnet_ver == $ipv4_val {
      $secondary_oam_floating_array = [$::platform::network::oam::ipv4::params::controller_address]

      if ($::platform::network::oam::ipv4::params::controller0_address != undef) and
          ($::platform::network::oam::ipv4::params::controller1_address != undef) {
        $secondary_unit_oam_array = [$::platform::network::oam::ipv4::params::controller0_address,
                                      $::platform::network::oam::ipv4::params::controller1_address]
      } elsif ($::platform::network::oam::ipv4::params::controller0_address != undef) and
              ($::platform::network::oam::ipv4::params::controller1_address == undef) {
        $secondary_unit_oam_array = [$::platform::network::oam::ipv4::params::controller0_address]
      } elsif ($::platform::network::oam::ipv4::params::controller0_address == undef) and
              ($::platform::network::oam::ipv4::params::controller1_address != undef) {
        $secondary_unit_oam_array = [$::platform::network::oam::ipv4::params::controller1_address]
      } else {
        $secondary_unit_oam_array = []
      }
      $certsans_oam_sec_array = $secondary_oam_floating_array + $secondary_unit_oam_array

    } elsif $sec_oam_subnet_ver == $ipv6_val {
      $secondary_oam_floating_array = [$::platform::network::oam::ipv6::params::controller_address]

      if ($::platform::network::oam::ipv6::params::controller0_address != undef) and
          ($::platform::network::oam::ipv6::params::controller1_address != undef) {
        $secondary_unit_oam_array = [$::platform::network::oam::ipv6::params::controller0_address,
                                      $::platform::network::oam::ipv6::params::controller1_address]
      } elsif ($::platform::network::oam::ipv6::params::controller0_address != undef) and
              ($::platform::network::oam::ipv6::params::controller1_address == undef) {
        $secondary_unit_oam_array = [$::platform::network::oam::ipv6::params::controller0_address]
      } elsif ($::platform::network::oam::ipv6::params::controller0_address == undef) and
              ($::platform::network::oam::ipv6::params::controller1_address != undef) {
        $secondary_unit_oam_array = [$::platform::network::oam::ipv6::params::controller1_address]
      } else {
        $secondary_unit_oam_array = []
      }
      $certsans_oam_sec_array = $secondary_oam_floating_array + $secondary_unit_oam_array

    } else {
      $certsans_oam_sec_array = []
    }

    # secondary Cluster-host addresses
    if $sec_cluster_host_subnet_ver == $ipv4_val {

      $sec_cluster_host_floating_array = [$::platform::network::cluster_host::ipv4::params::controller_address]

      if ($::platform::network::cluster_host::ipv4::params::controller0_address != undef) and
          ($::platform::network::cluster_host::ipv4::params::controller1_address != undef) {
        $sec_unit_cluster_host_array = [$::platform::network::cluster_host::ipv4::params::controller0_address,
                                        $::platform::network::cluster_host::ipv4::params::controller1_address]
      } elsif ($::platform::network::cluster_host::ipv4::params::controller0_address != undef) and
              ($::platform::network::cluster_host::ipv4::params::controller1_address == undef) {
        $sec_unit_cluster_host_array = [$::platform::network::cluster_host::ipv4::params::controller0_address]
      } elsif ($::platform::network::cluster_host::ipv4::params::controller0_address == undef) and
              ($::platform::network::cluster_host::ipv4::params::controller1_address != undef) {
        $sec_unit_cluster_host_array = [$::platform::network::cluster_host::ipv4::params::controller1_address]
      } else {
        $sec_unit_cluster_host_array = []
      }
      $certsans_cluster_host_sec_array = $sec_cluster_host_floating_array + $sec_unit_cluster_host_array

    } elsif $sec_cluster_host_subnet_ver == $ipv6_val {

      $sec_cluster_host_floating_array = [$::platform::network::cluster_host::ipv6::params::controller_address]

      if ($::platform::network::cluster_host::ipv6::params::controller0_address != undef) and
          ($::platform::network::cluster_host::ipv6::params::controller1_address != undef) {
        $sec_unit_cluster_host_array = [$::platform::network::cluster_host::ipv6::params::controller0_address,
                                        $::platform::network::cluster_host::ipv6::params::controller1_address]
      } elsif ($::platform::network::cluster_host::ipv6::params::controller0_address != undef) and
              ($::platform::network::cluster_host::ipv6::params::controller1_address == undef) {
        $sec_unit_cluster_host_array = [$::platform::network::cluster_host::ipv6::params::controller0_address]
      } elsif ($::platform::network::cluster_host::ipv6::params::controller0_address == undef) and
              ($::platform::network::cluster_host::ipv6::params::controller1_address != undef) {
        $sec_unit_cluster_host_array = [$::platform::network::cluster_host::ipv6::params::controller1_address]
      } else {
        $sec_unit_cluster_host_array = []
      }
      $certsans_cluster_host_sec_array = $sec_cluster_host_floating_array + $sec_unit_cluster_host_array

    } else {
      $certsans_cluster_host_sec_array = []
    }

    $certsans_sec_hosts_array = $certsans_oam_sec_array + $certsans_cluster_host_sec_array + $certsans_sec_localhost_array
  }
  $certsans_array = $certsans_prim_array + $certsans_sec_hosts_array

  $certsans = join($certsans_array,',')

  exec { 'update kube-apiserver certSANs':
    provider => shell,
    command  => template('platform/kube-apiserver-update-certSANs.erb')
  }
}

# The duplex_migration class is applied as part of SX to DX migration
class platform::kubernetes::duplex_migration::runtime::post {
  file { '/var/run/.kubernetes_duplex_migration_complete':
    ensure => present,
  }
}

class platform::kubernetes::duplex_migration::runtime {
  contain ::platform::kubernetes::coredns::duplex

  # Update replicas to 2 for duplex
  Class['::platform::kubernetes::coredns::duplex']
  -> exec { '2 coredns for duplex mode':
    command   => 'kubectl --kubeconfig=/etc/kubernetes/admin.conf -n kube-system scale --replicas=2 deployment coredns',
    logoutput => true,
  }

  class { '::platform::kubernetes::duplex_migration::runtime::post':
    stage => post,
  }
}

class platform::kubernetes::master::rootca::trustbothcas::runtime
  inherits ::platform::kubernetes::params {

  # Create the new root CA cert file
  file { $rootca_certfile_new:
    ensure  => file,
    content => base64('decode', $rootca_cert),
  }
  # Create new root CA key file
  -> file { $rootca_keyfile_new:
    ensure  => file,
    content => base64('decode', $rootca_key),
  }
  # Append the new cert to the current cert
  -> exec { 'append_ca_cert':
    command => "cat ${rootca_certfile_new} >> ${rootca_certfile}",
  }
  # update admin.conf with both old and new certs
  -> exec { 'update_admin_conf':
    environment => [ 'KUBECONFIG=/etc/kubernetes/admin.conf' ],
    command     => 'kubectl config set-cluster kubernetes --certificate-authority /etc/kubernetes/pki/ca.crt --embed-certs',
  }
  # update super-admin.conf with both old and new certs
  -> exec { 'update_super_admin_conf':
    environment => [ 'KUBECONFIG=/etc/kubernetes/super-admin.conf' ],
    command     => 'kubectl config set-cluster kubernetes --certificate-authority /etc/kubernetes/pki/ca.crt --embed-certs',
  }
  # Restart apiserver to trust both old and new certs
  -> exec { 'restart_apiserver':
    command => "/usr/bin/kill -s SIGHUP $(pidof kube-apiserver)",
  }
  # Update scheduler.conf with both old and new certs
  -> exec { 'update_scheduler_conf':
    environment => [ 'KUBECONFIG=/etc/kubernetes/scheduler.conf' ],
    command     => 'kubectl config set-cluster kubernetes --certificate-authority /etc/kubernetes/pki/ca.crt --embed-certs',
  }
  # Restart scheduler to trust both old and new certs
  -> exec { 'restart_scheduler':
    command => "/usr/bin/kill -s SIGHUP $(pidof kube-scheduler)"
  }
  # Update controller-manager.conf with both old and new certs
  -> exec { 'update_controller-manager_conf':
    environment => [ 'KUBECONFIG=/etc/kubernetes/controller-manager.conf' ],
    command     => 'kubectl config set-cluster kubernetes --certificate-authority /etc/kubernetes/pki/ca.crt --embed-certs',
  }
  # Update kube-controller-manager.yaml with new cert and key
  -> exec { 'update_controller-manager_yaml':
    command => "/bin/sed -i \\
                -e 's|cluster-signing-cert-file=.*|cluster-signing-cert-file=/etc/kubernetes/pki/ca_new.crt|' \\
                -e 's|cluster-signing-key-file=.*|cluster-signing-key-file=/etc/kubernetes/pki/ca_new.key|' \\
                /etc/kubernetes/manifests/kube-controller-manager.yaml"
  }
  # Wait for kube-apiserver to be up before executing next steps
  # Uses a k8s API health endpoint for that: https://kubernetes.io/docs/reference/using-api/health-checks/
  -> exec { 'wait_for_kube_apiserver':
    command   => '/usr/bin/curl -k -f -m 15 https://localhost:6443/readyz',
    timeout   => 30,
    tries     => 18,
    try_sleep => 5,
  }

  # Update kubelet.conf with both old and new certs
  $cluster = generate('/bin/bash', '-c', "/bin/sed -e '/- cluster/,/name:/!d' /etc/kubernetes/kubelet.conf \\
                      | grep 'name:' | awk '{printf \"%s\", \$2}'")
  exec { 'update_kubelet_conf':
    environment => [ 'KUBECONFIG=/etc/kubernetes/kubelet.conf' ],
    command     => "kubectl config set-cluster ${cluster} --certificate-authority /etc/kubernetes/pki/ca.crt --embed-certs",
    require     => Exec['append_ca_cert'],
  }
  # Restart kubelet to truct both certs
  -> exec { 'restart_kubelet':
    command => '/usr/local/sbin/pmon-restart kubelet',
  }
}

class platform::kubernetes::worker::rootca::trustbothcas::runtime
  inherits ::platform::kubernetes::params {

  $cluster = generate('/bin/bash', '-c', "/bin/sed -e '/- cluster/,/name:/!d' /etc/kubernetes/kubelet.conf \
                      | grep 'name:' | awk '{printf \"%s\", \$2}'")
  # Create the new root CA cert file
  file { $rootca_certfile_new:
    ensure  => file,
    content => base64('decode', $rootca_cert),
  }
  # Create new root CA key file
  -> file { $rootca_keyfile_new:
    ensure  => file,
    content => base64('decode', $rootca_key),
  }
  # Append the new cert to the current cert
  -> exec { 'append_ca_cert':
    command => "cat ${rootca_certfile_new} >> ${rootca_certfile}",
    unless  => "grep -v '[BEGIN|END] CERTIFICATE' ${rootca_certfile_new} | awk /./ | grep -f ${rootca_certfile} &>/dev/null"
  }
  # Update kubelet.conf with both old and new certs
  -> exec { 'update_kubelet_conf':
    environment => [ 'KUBECONFIG=/etc/kubernetes/kubelet.conf' ],
    command     => "kubectl config set-cluster ${cluster} --certificate-authority /etc/kubernetes/pki/ca.crt --embed-certs",
  }
  # Restart kubelet to trust both certs
  -> exec { 'restart_kubelet':
    command => '/usr/local/sbin/pmon-restart kubelet',
  }
}

class platform::kubernetes::master::rootca::trustnewca::runtime
  inherits ::platform::kubernetes::params {
  include ::platform::params

  # Copy the new root CA cert in place
  exec { 'put_new_ca_cert_in_place':
    command => "/bin/cp ${rootca_certfile_new} ${rootca_certfile}",
  }
  # Copy the new root CA key in place
  -> exec { 'put_new_ca_key_in_place':
    command => "/bin/cp ${rootca_keyfile_new} ${rootca_keyfile}",
  }
  # Update admin.conf to remove the old CA cert
  -> exec { 'update_admin_conf':
    environment => [ 'KUBECONFIG=/etc/kubernetes/admin.conf' ],
    command     => "kubectl config set-cluster kubernetes --certificate-authority ${rootca_certfile} --embed-certs",
  }
  # Update super-admin.conf to remove the old CA cert
  -> exec { 'update_super_admin_conf':
    environment => [ 'KUBECONFIG=/etc/kubernetes/super-admin.conf' ],
    command     => "kubectl config set-cluster kubernetes --certificate-authority ${rootca_certfile} --embed-certs",
  }
  # Restart sysinv-conductor and sysinv-inv since they cache clients with
  # credentials from admin.conf
  -> exec { 'restart_sysinv_conductor':
    command => 'sm-restart service sysinv-conductor',
  }
  # Restart cert-mon since it uses admin.conf
  -> exec { 'restart_cert_mon':
    command => 'sm-restart-safe service cert-mon',
  }
  # Restart dccertmon since it uses admin.conf
  -> exec { 'restart_dccertmon':
    command => 'sm-restart-safe service dccertmon',
    onlyif  => $::platform::params::distributed_cloud_role == 'systemcontroller',
  }
  # Restart kube-apiserver to pick up the new cert
  -> exec { 'restart_apiserver':
    command => "/usr/bin/kill -s SIGHUP $(pidof kube-apiserver)",
  }
  # Update controller-manager.conf with the new cert
  -> exec { 'update_controller-manager_conf':
    environment => [ 'KUBECONFIG=/etc/kubernetes/controller-manager.conf' ],
    command     => 'kubectl config set-cluster kubernetes --certificate-authority /etc/kubernetes/pki/ca.crt --embed-certs',
  }
  # Update kube-controller-manager.yaml with the new cert and key,
  # this also restart controller-manager
  -> exec { 'update_controller-manager_yaml':
    command => "/bin/sed -i \\
                -e 's|cluster-signing-cert-file=.*|cluster-signing-cert-file=${rootca_certfile}|' \\
                -e 's|cluster-signing-key-file=.*|cluster-signing-key-file=${rootca_keyfile}|' \\
                /etc/kubernetes/manifests/kube-controller-manager.yaml",
  }
  # Update scheduler.conf with the new cert
  -> exec { 'update_scheduler_conf':
    environment => [ 'KUBECONFIG=/etc/kubernetes/scheduler.conf' ],
    command     => "kubectl config set-cluster kubernetes --certificate-authority ${rootca_certfile} --embed-certs",
  }
  # Restart scheduler to trust the new cert
  -> exec { 'restart_scheduler':
    command => "/usr/bin/kill -s SIGHUP $(pidof kube-scheduler)",
  }
  # Wait for kube-apiserver to be up before executing next steps
  # Uses a k8s API health endpoint for that: https://kubernetes.io/docs/reference/using-api/health-checks/
  -> exec { 'wait_for_kube_apiserver':
    command   => '/usr/bin/curl -k -f -m 15 https://localhost:6443/readyz',
    timeout   => 30,
    tries     => 18,
    try_sleep => 5,
  }

  # Update kubelet.conf with the new cert
  $cluster = generate('/bin/bash', '-c', "/bin/sed -e '/- cluster/,/name:/!d' /etc/kubernetes/kubelet.conf \
                      | grep 'name:' | awk '{printf \"%s\", \$2}'")

  exec { 'update_kubelet_conf':
    environment => [ 'KUBECONFIG=/etc/kubernetes/kubelet.conf' ],
    command     => "kubectl config set-cluster ${cluster} --certificate-authority ${rootca_certfile} --embed-certs",
    require     => Exec['put_new_ca_key_in_place'],
  }
  # Restart kubelet to trust only the new cert
  -> exec { 'restart_kubelet':
    command => '/usr/local/sbin/pmon-restart kubelet',
  }
  # Remove the new cert file
  -> exec { 'remove_new_cert_file':
    command => "/bin/rm -f ${rootca_certfile_new}",
  }
  # Remove the new key file
  -> exec { 'remove_new_key_file':
    command => "/bin/rm -f ${rootca_keyfile_new}",
  }
}

class platform::kubernetes::worker::rootca::trustnewca::runtime
  inherits ::platform::kubernetes::params {

  $cluster = generate('/bin/bash', '-c', "/bin/sed -e '/- cluster/,/name:/!d' /etc/kubernetes/kubelet.conf \
                      | grep 'name:' | awk '{printf \"%s\", \$2}'")
  # Replace the current root CA cert with the new one
  exec { 'replace_ca_cert_with_new_one':
    command => "/bin/mv -f ${rootca_certfile_new} ${rootca_certfile}",
    onlyif  => "/usr/bin/test -e ${rootca_certfile_new}",
  }
  # Replace the current root CA key with the new one
  -> exec { 'replace_ca_key_with_new_one':
    command => "/bin/mv -f ${rootca_keyfile_new} ${rootca_keyfile}",
    onlyif  => "/usr/bin/test -e ${rootca_keyfile_new}",
  }
  # Update kubelet.conf with the new cert
  -> exec { 'update_kubelet_conf':
    environment => [ 'KUBECONFIG=/etc/kubernetes/kubelet.conf' ],
    command     => "kubectl config set-cluster ${cluster} --certificate-authority ${rootca_certfile} --embed-certs",
  }
  # Restart kubelet to trust only the new cert
  -> exec { 'restart_kubelet':
    command => '/usr/local/sbin/pmon-restart kubelet',
  }
}

class platform::kubernetes::master::rootca::pods::trustbothcas::runtime
  inherits ::platform::kubernetes::params {
  exec { 'update_pods_trustbothcas':
    environment => [ 'KUBECONFIG=/etc/kubernetes/admin.conf' ],
    provider    => shell,
    command     => template('platform/kube-rootca-update-pods.erb'),
    timeout     => 3600,
    logoutput   => true,
  }
}

class platform::kubernetes::master::rootca::pods::trustnewca::runtime
  inherits ::platform::kubernetes::params {
  exec { 'update_pods_trustnewca':
    environment => [ 'KUBECONFIG=/etc/kubernetes/admin.conf' ],
    provider    => shell,
    command     => template('platform/kube-rootca-update-pods.erb'),
    timeout     => 3600,
    logoutput   => true,
  }
}

class platform::kubernetes::master::rootca::updatecerts::runtime
  inherits ::platform::kubernetes::params {

  # Create directory to use crt and key from secret in kubernetes components configuration
  file { '/tmp/kube_rootca_update':
    ensure => directory,
    owner  => 'root',
    group  => 'root',
    mode   => '0640',
  }

  # Create the new k8s admin cert file
  -> file { '/tmp/kube_rootca_update/kubernetes-admin.crt':
    ensure  => file,
    content => base64('decode', $admin_cert),
    owner   => 'root',
    group   => 'root',
    mode    => '0640',
  }

  # Create the new k8s admin key file
  -> file { '/tmp/kube_rootca_update/kubernetes-admin.key':
    ensure  => file,
    content => base64('decode', $admin_key),
    owner   => 'root',
    group   => 'root',
    mode    => '0640',
  }

  # Create the new k8s super admin cert file
  -> file { '/tmp/kube_rootca_update/kubernetes-super-admin.crt':
    ensure  => file,
    content => base64('decode', $super_admin_cert),
    owner   => 'root',
    group   => 'root',
    mode    => '0640',
  }

  # Create the new k8s super admin key file
  -> file { '/tmp/kube_rootca_update/kubernetes-super-admin.key':
    ensure  => file,
    content => base64('decode', $super_admin_key),
    owner   => 'root',
    group   => 'root',
    mode    => '0640',
  }

  # Update admin.conf with new cert/key
  -> exec { 'update_admin_conf_credentials':
    environment => [ 'KUBECONFIG=/etc/kubernetes/admin.conf' ],
    command     => "kubectl config set-credentials kubernetes-admin --client-key /tmp/kube_rootca_update/kubernetes-admin.key \
                    --client-certificate /tmp/kube_rootca_update/kubernetes-admin.crt --embed-certs",
  }

  # Update super-admin.conf with new cert/key
  -> exec { 'update_super_admin_conf_credentials':
    environment => [ 'KUBECONFIG=/etc/kubernetes/super-admin.conf' ],
    command     => "kubectl config set-credentials kubernetes-super-admin --client-key /tmp/kube_rootca_update/kubernetes-super-admin.key \
                    --client-certificate /tmp/kube_rootca_update/kubernetes-super-admin.crt --embed-certs",
  }

  # Copy the new apiserver.crt, apiserver.key to replace the ones in /etc/kubernetes/pki/ directory
  # Create the new k8s apiserver cert file
  -> file { '/etc/kubernetes/pki/apiserver.crt':
    ensure  => file,
    content => base64('decode', $apiserver_cert),
    replace => true,
  }

  # Create the new k8s apiserver key file
  -> file { '/etc/kubernetes/pki/apiserver.key':
    ensure  => file,
    content => base64('decode', $apiserver_key),
    replace => true,
  }

  # Copy the new apiserver-kubelet-client.crt, apiserver-kubelet-client.key to replace the ones in /etc/kubernetes/pki/ directory
  # Create the new k8s apiserver-kubelet-client cert file
  -> file { '/etc/kubernetes/pki/apiserver-kubelet-client.crt':
    ensure  => file,
    content => base64('decode', $apiserver_kubelet_cert),
  }

  # Create the new k8s apiserver-kubelet-client key file
  -> file { '/etc/kubernetes/pki/apiserver-kubelet-client.key':
    ensure  => file,
    content => base64('decode', $apiserver_kubelet_key),
  }

  # Create the new kube scheduler crt file
  -> file { '/tmp/kube_rootca_update/kube-scheduler.crt':
    ensure  => file,
    content => base64('decode', $scheduler_cert),
    owner   => 'root',
    group   => 'root',
    mode    => '0640',
  }

  # Create the new kube scheduler key file
  -> file { '/tmp/kube_rootca_update/kube-scheduler.key':
    ensure  => file,
    content => base64('decode', $scheduler_key),
    owner   => 'root',
    group   => 'root',
    mode    => '0640',
  }

  # Update scheduler.conf with the new client cert
  -> exec { 'scheduler_conf':
    environment => [ 'KUBECONFIG=/etc/kubernetes/scheduler.conf' ],
    command     => "kubectl config set-credentials system:kube-scheduler --client-key /tmp/kube_rootca_update/kube-scheduler.key \
                    --client-certificate /tmp/kube_rootca_update/kube-scheduler.crt --embed-certs",
  }

  # Restart scheduler
  -> exec { 'restart_scheduler':
    command => "/usr/bin/kill -s SIGHUP $(pidof kube-scheduler)"
  }

  # Create the new k8s controller-manager crt file
  -> file { '/tmp/kube_rootca_update/kube-controller-manager.crt':
    ensure  => file,
    content => base64('decode', $controller_manager_cert),
    owner   => 'root',
    group   => 'root',
    mode    => '0640',
  }

  # Create the new k8s controller-manager key file
  -> file { '/tmp/kube_rootca_update/kube-controller-manager.key':
    ensure  => file,
    content => base64('decode', $controller_manager_key),
    owner   => 'root',
    group   => 'root',
    mode    => '0640',
  }

  # Update controller-manager.conf with the new client cert/key
  -> exec { 'controller-manager_conf':
    environment => [ 'KUBECONFIG=/etc/kubernetes/controller-manager.conf' ],
    command     => "kubectl config set-credentials system:kube-controller-manager \
                    --client-key /tmp/kube_rootca_update/kube-controller-manager.key \
                    --client-certificate  /tmp/kube_rootca_update/kube-controller-manager.crt --embed-certs",
  }

  # Restart kube-controller-manager
  -> exec { 'restart_controller-manager':
    command => "/usr/bin/kill -s SIGHUP $(pidof kube-controller-manager)"
  }

  # Create the new kubelet client crt file
  -> file { "/tmp/kube_rootca_update/${::platform::params::hostname}.crt":
    ensure  => file,
    content => base64('decode', $kubelet_cert),
    owner   => 'root',
    group   => 'root',
    mode    => '0640',
  }

  # Create the new kubelet client key file
  -> file { "/tmp/kube_rootca_update/${::platform::params::hostname}.key":
    ensure  => file,
    content => base64('decode', $kubelet_key),
    owner   => 'root',
    group   => 'root',
    mode    => '0640',
  }

  # Append the cert and key to a pem file
  -> exec { 'append_kubelet_client_cert_and_key':
    command => "cat /tmp/kube_rootca_update/${::platform::params::hostname}.crt \
                /tmp/kube_rootca_update/${::platform::params::hostname}.key > /tmp/kube_rootca_update/kubelet-client-cert-with-key.pem",
  }

  # Copy the new apiserver.crt, apiserver.key to replace the ones in /etc/kubernetes/pki/ directory
  -> file { '/var/lib/kubelet/pki/kubelet-client-cert-with-key.pem':
    ensure  => file,
    source  => '/tmp/kube_rootca_update/kubelet-client-cert-with-key.pem',
    replace => true,
  }

  # add link to new kubelet client cert
  -> file { '/var/lib/kubelet/pki/kubelet-client-current.pem':
    ensure  => 'link',
    target  => '/var/lib/kubelet/pki/kubelet-client-cert-with-key.pem',
    replace => true,
  }

  # Restart kubelet
  -> exec { 'restart_kubelet-client':
    command => "/usr/bin/kill -s SIGHUP $(pidof kubelet)"
  }

  # Moving the signing ca cert in ca.crt and admin.conf to be the first in the bundle.
  # This is neccessary for cert-mon, since it only uses the first ca cert in admin.conf
  # to verify server certificate from apiserver.
  # Remove the new ca cert from the bundle first
  -> exec { 'remove_new_ca_cert_from_bottom':
    command => "tac ${rootca_certfile} | sed '0,/-----BEGIN CERTIFICATE-----/d' | tac -  > /tmp/kube_rootca_update/ca_tmp.crt"
  }

  # Create the ca.crt with the new ca cert at the top of the bundle
  -> exec { 'prepend_new_ca_cert_at_top':
    command => "cat ${rootca_certfile_new} /tmp/kube_rootca_update/ca_tmp.crt > ${rootca_certfile}"
  }

  # Update admin.conf with the newly create ca.crt
  -> exec { 'update_admin_conf_with_new_cert_at_top':
    environment => [ 'KUBECONFIG=/etc/kubernetes/admin.conf' ],
    command     => "kubectl config set-cluster kubernetes --certificate-authority ${rootca_certfile} --embed-certs",
  }

  # Removing temporary directory for files along this configuration process
  -> exec { 'remove_kube_rootca_update_dir':
    command => '/usr/bin/rm -rf /tmp/kube_rootca_update',
  }
}

class platform::kubernetes::worker::rootca::updatecerts::runtime
  inherits ::platform::kubernetes::params {
  file { '/tmp/kube_rootca_update':
    ensure => directory,
    owner  => 'root',
    group  => 'root',
    mode   => '0640',
  }

  # Create the new k8s kubelet client cert file
  -> file { "/tmp/kube_rootca_update/${::platform::params::hostname}.crt":
    ensure  => file,
    content => base64('decode', $kubelet_cert),
    owner   => 'root',
    group   => 'root',
    mode    => '0640',
  }

  # Create the new k8s kubelet client key file
  -> file { "/tmp/kube_rootca_update/${::platform::params::hostname}.key":
    ensure  => file,
    content => base64('decode', $kubelet_key),
    owner   => 'root',
    group   => 'root',
    mode    => '0640',
  }

  # Append the new cert and key files
  -> exec { 'append_kubelet_client_cert_and_key':
    command => "cat /tmp/kube_rootca_update/${::platform::params::hostname}.crt \
                /tmp/kube_rootca_update/${::platform::params::hostname}.key > /tmp/kube_rootca_update/kubelet-client-cert-with-key.pem",
  }

  # Copy kubelet cert and key file to replace the one in /var/lib/kubelet/pki/ directory
  -> file { '/var/lib/kubelet/pki/kubelet-client-cert-with-key.pem':
    ensure  => file,
    source  => '/tmp/kube_rootca_update/kubelet-client-cert-with-key.pem',
    replace => true,
  }

  # Remove the current kubelet-client reference
  -> exec { 'remove_current_kubelet_cert_link':
    command => '/usr/bin/rm -rf /var/lib/kubelet/pki/kubelet-client-current.pem',
  }

  # add link to new kubelet client cert
  -> file { '/var/lib/kubelet/pki/kubelet-client-current.pem':
    ensure => 'link',
    target => '/var/lib/kubelet/pki/kubelet-client-cert-with-key.pem',
  }

  # Restart kubelet
  -> exec { 'restart_kubelet-client':
    command => "/usr/bin/kill -s SIGHUP $(pidof kubelet)"
  }

  # Removing temporary directory for files along this configuration process
  -> exec { 'remove_kube_rootca_update_dir':
    command => '/usr/bin/rm -rf /tmp/kube_rootca_update',
  }
}

class platform::kubernetes::master::apiserver::runtime{
  # Restart apiserver (to trust a new ca)
  exec { 'restart_kube_apiserver':
    command => "/usr/bin/kill -s SIGHUP $(pidof kube-apiserver)",
  }
}

class platform::kubernetes::master::update_kubelet_params::runtime
  inherits ::platform::kubernetes::params {

  # Ensure kubectl symlink is up to date.  May not actually be needed.
  require platform::kubernetes::symlinks

  $kubelet_image_gc_low_threshold_percent = $::platform::kubernetes::params::kubelet_image_gc_low_threshold_percent
  $kubelet_image_gc_high_threshold_percent = $::platform::kubernetes::params::kubelet_image_gc_high_threshold_percent
  $kubelet_eviction_hard_imagefs_available = $::platform::kubernetes::params::kubelet_eviction_hard_imagefs_available

  # Update kubelet parameters in kubelet-config Configmap.
  exec { 'update kubelet config parameters':
    environment => [ 'KUBECONFIG=/etc/kubernetes/admin.conf' ],
    provider    => shell,
    command     => template('platform/kube-config-kubelet.erb'),
    timeout     => 60,
    logoutput   => true,
  }
}

class platform::kubernetes::update_kubelet_config::runtime
  inherits ::platform::kubernetes::params {

  # Update kubeadm/kubelet symlinks.   May not actually be needed.
  require platform::kubernetes::symlinks

  # Regenerate /var/lib/kubelet/config.yaml based on current kubelet-config
  # ConfigMap. This does not regenerate /var/lib/kubelet/kubeadm-flags.env.
  platform::kubernetes::kube_command { 'update kubelet config':
    command     => 'kubeadm upgrade node phase kubelet-config',
    logname     => 'kubeadm-upgrade-node-phase-kubelet-config.log',
    environment => 'KUBECONFIG=/etc/kubernetes/admin.conf:/etc/kubernetes/kubelet.conf',
    timeout     => 60,
  }

  -> exec { 'restart kubelet':
      command => '/usr/local/sbin/pmon-restart kubelet',
  }

}

class platform::kubernetes::cordon_node {
  # Cordon will poll indefinitely every 5 seconds if there is
  # unsatisfied pod-disruption-budget, and may also run long if there
  # are lots of pods to drain, so limit operation to 150 seconds.
  platform::kubernetes::kube_command { 'drain the node':
    command     => "kubectl drain ${::platform::params::hostname} \
                    --ignore-daemonsets --delete-emptydir-data \
                    --skip-wait-for-delete-timeout=10 \
                    --force --timeout=150s",
    logname     => 'cordon.log',
    environment => 'KUBECONFIG=/etc/kubernetes/admin.conf:/etc/kubernetes/kubelet.conf',
    onlyif      => "kubectl get node ${::platform::params::hostname}",
  }
}

class platform::kubernetes::unmask_start_services
  inherits ::platform::kubernetes::params {
  include platform::kubernetes::unmask_start_kubelet

  exec { 'unmask etcd service ':
    command => '/usr/bin/systemctl unmask --runtime etcd',
  }
  -> exec { 'start etcd service':
      command => '/usr/local/sbin/pmon-start etcd'
  }
  -> exec { 'unmask docker service':
      command => '/usr/bin/systemctl unmask --runtime docker',
  }
  -> exec { 'start docker service':
      command => '/usr/local/sbin/pmon-start docker'
  }
  -> exec { 'unmask containerd service':
      command => '/usr/bin/systemctl unmask --runtime containerd',
  }
  -> exec { 'start containerd service':
      command => '/usr/local/sbin/pmon-start containerd'
  }
  -> Class['platform::kubernetes::unmask_start_kubelet']
  -> exec { 'wait for kubernetes endpoints health check':
      command => '/usr/bin/sysinv-k8s-health check',
  }
}

class platform::kubernetes::refresh_admin_config {
  # Remove and regenerate the kube config file /etc/kubernetes/admin.conf
  exec { 'remove the /etc/kubernetes/admin.conf':
    command => 'rm -f /etc/kubernetes/admin.conf',
  }
  -> exec { 'remove the /etc/kubernetes/super-admin.conf':
    command => 'rm -f /etc/kubernetes/super-admin.conf',
    onlyif  => 'test -f /etc/kubernetes/super-admin.conf',
  }
  # K8s version upgrade abort of 1.28 to 1.29 removes some of the permission & priviledge
  # of kubernetes-admin user. Following command will regenerate admin.conf file and
  # ensure the required permissions & priviledges.
  -> exec { 'regenerate the /etc/kubernetes/admin.conf':
    command => 'kubeadm init phase kubeconfig admin',
  }
  -> file { '/etc/kubernetes/admin.conf':
    owner => 'root',
    group => 'root',
    mode  => '0640',
  }
  -> exec { 'set_acl_on_admin_conf':
    command   => 'setfacl -m g:sys_protected:r /etc/kubernetes/admin.conf',
    logoutput => true,
  }
}

class platform::kubernetes::upgrade_abort
  inherits ::platform::kubernetes::params {
  $software_version = $::platform::params::software_version
  include platform::kubernetes::cordon_node
  include platform::kubernetes::mask_stop_kubelet
  include platform::kubernetes::unmask_start_services
  include platform::kubernetes::refresh_admin_config

  # Keep a backup of the current Kubernetes config files so that if abort fails,
  # we can restore to that state with upgrade_abort_recovery.
  exec { 'backup the kubernetes admin and super-admin config':
    command => "mkdir -p ${kube_config_backup_path} && cp -p /etc/kubernetes/*admin.conf ${kube_config_backup_path}/.",
    onlyif  => ['test -f /etc/kubernetes/admin.conf'],
  }
  # Take latest static manifest files backup for recovery if upgrade_abort fail
  exec { 'remove the control-plane pods':
      command => "mkdir -p ${static_pod_manifests_abort} && mv -f  /etc/kubernetes/manifests/*.yaml ${static_pod_manifests_abort}/.",
      require => Class['platform::kubernetes::cordon_node'],
      onlyif  => ["test -d ${static_pod_manifests_initial}",
                  "kubectl --kubeconfig=/etc/kubernetes/admin.conf get node ${::platform::params::hostname}" ] # lint:ignore:140chars
  }
  -> exec { 'wait for control plane terminated':
      command => '/usr/local/bin/kube-wait-control-plane-terminated.sh',
      onlyif  => "test -d ${static_pod_manifests_initial}",
  }
  -> Class['platform::kubernetes::mask_stop_kubelet']
  -> exec { 'stop all containers':
      command   => '/usr/sbin/k8s-container-cleanup.sh  force-clean',
      logoutput => true,
  }
  -> exec { 'mask containerd service':
      command => '/usr/bin/systemctl mask --runtime --now containerd',
  }
  -> exec { 'stop containerd service':
      command => '/usr/local/sbin/pmon-stop containerd',
  }
  -> exec { 'mask docker service':
      command => '/usr/bin/systemctl mask --runtime --now docker',
  }
  -> exec { 'stop docker service':
      command => '/usr/local/sbin/pmon-stop docker',
  }
  -> exec { 'mask etcd service':
      command => '/usr/bin/systemctl mask --runtime --now etcd',
  }
  -> exec { 'stop etcd service':
      command => '/usr/local/sbin/pmon-stop etcd',
  }
  # Take latest etcd data dir backup for recovery if snapshot restore fails
  -> exec{ 'move etcd data dir to backup':
      command => "mv -f /opt/etcd/${software_version}/controller.etcd /opt/etcd/${software_version}/controller.etcd.bck",
      onlyif  => ["test -f ${etcd_snapshot_file}",
                  "test ! -d /opt/etcd/${software_version}/controller.etcd.bck"]
  }
  -> exec { 'restore etcd snapshot':
      command     => "etcdctl --cert ${etcd_cert_file} --key ${etcd_key_file} --cacert ${etcd_ca_cert} --endpoints ${etcd_endpoints} snapshot restore ${etcd_snapshot_file} --data-dir /opt/etcd/${software_version}/controller.etcd --name ${etcd_name} --initial-cluster ${etcd_initial_cluster} ", # lint:ignore:140chars
      environment => [ 'ETCDCTL_API=3' ],
      onlyif      => "test -f ${etcd_snapshot_file}"
  }
  -> exec { 'restore static manifest files':
      command => "/usr/bin/cp -f  ${static_pod_manifests_initial}/*.yaml /etc/kubernetes/manifests",
      onlyif  => "test -d ${static_pod_manifests_initial}",
  }
  -> Class['platform::kubernetes::unmask_start_services']
  -> Class['platform::kubernetes::refresh_admin_config']
  # Remove recover static manifest files backup if snapshot restore succeeded
  -> exec { 'remove recover static manifest files':
      command => "rm -rf ${static_pod_manifests_abort}",
      onlyif  => "test -d ${static_pod_manifests_abort}",
  }
  # Remove latest etcd data dir backup if snapshot restore succeeded
  -> exec { 'remove recover etcd data dir':
      command => "rm -rf /opt/etcd/${software_version}/controller.etcd.bck",
      onlyif  => "test -d /opt/etcd/${software_version}/controller.etcd.bck",
  }
  # Remove kube config files backup after the abort
  -> exec { 'remove kube config files backup':
      command => "rm -rf ${kube_config_backup_path}",
      onlyif  => "test -d ${kube_config_backup_path}",
  }
}

class platform::kubernetes::upgrade_abort_recovery
  inherits ::platform::kubernetes::params {
  include platform::kubernetes::unmask_start_services
  $software_version = $::platform::params::software_version

  exec{ 'restore recover etcd data dir':
    command => "mv -f /opt/etcd/${software_version}/controller.etcd.bck /opt/etcd/${software_version}/controller.etcd",
    onlyif  => "test -d /opt/etcd/${software_version}/controller.etcd.bck",
  }
  -> exec { 'restore recover static manifest files':
      command => "mv -f  ${static_pod_manifests_abort}/*.yaml /etc/kubernetes/manifests/",
  }
  -> exec { 'restore the admin and super-admin config files':
    command => "mv -f ${kube_config_backup_path}/*admin.conf /etc/kubernetes/",
  }
  -> Class['platform::kubernetes::unmask_start_services']
  -> exec { 'uncordon the node':
      command   => "kubectl --kubeconfig=/etc/kubernetes/admin.conf uncordon ${::platform::params::hostname}",
  }
}

class platform::kubernetes::kubelet::update_node_ip::runtime
  inherits ::platform::kubernetes::params {
  # lint:ignore:140chars
  if $::personality == 'worker' or $::personality == 'controller' {

    $node_ip = $::platform::kubernetes::params::node_ip
    if $::platform::kubernetes::params::node_ip_secondary {
      $node_ip_secondary = $::platform::kubernetes::params::node_ip_secondary
    } else {
      $node_ip_secondary = 'undef'
    }
    $restart_wait = '5'

    if $::personality == 'worker' {
      $cfgf = '/etc/kubernetes/kubelet.conf'
    } elsif $::personality == 'controller' {
      $cfgf = '/etc/kubernetes/admin.conf'
    }

    exec { 'kubelet-update-node-ip':
      path      => '/usr/bin:/usr/sbin:/bin:/usr/local/bin',
      command   => "dual-stack-kubelet.py ${node_ip} ${node_ip_secondary} ${restart_wait} ${cfgf}",
      logoutput => true,
    }
  }
  # lint:endignore:140chars
}

class platform::kubernetes::kubeadm::dual_stack::ipv4::runtime {
  # lint:ignore:140chars
  include ::platform::network::cluster_pod::params
  include ::platform::network::cluster_pod::ipv4::params
  include ::platform::network::cluster_service::params
  include ::platform::network::cluster_service::ipv4::params
  include ::platform::network::cluster_host::ipv4::params
  if $::personality == 'controller' {
    $restart_wait = '5'

    $pod_prim_network = $::platform::network::cluster_pod::params::subnet_network
    $pod_prim_prefixlen = $::platform::network::cluster_pod::params::subnet_prefixlen
    $pod_prim_subnet = "${pod_prim_network}/${pod_prim_prefixlen}"

    if $platform::network::cluster_pod::ipv4::params::subnet_version == $::platform::params::ipv4  {
      $pod_sec_network = $::platform::network::cluster_pod::ipv4::params::subnet_network
      $pod_sec_prefixlen = $::platform::network::cluster_pod::ipv4::params::subnet_prefixlen
      $pod_sec_subnet = "${pod_sec_network}/${pod_sec_prefixlen}"
    } else {
      $pod_sec_subnet = 'undef'
    }

    $svc_prim_network = $::platform::network::cluster_service::params::subnet_network
    $svc_prim_prefixlen = $::platform::network::cluster_service::params::subnet_prefixlen
    $svc_prim_subnet = "${svc_prim_network}/${svc_prim_prefixlen}"

    if $platform::network::cluster_service::ipv4::params::subnet_version == $::platform::params::ipv4 {
      $svc_sec_network = $::platform::network::cluster_service::ipv4::params::subnet_network
      $svc_sec_prefixlen = $::platform::network::cluster_service::ipv4::params::subnet_prefixlen
      $svc_sec_subnet = "${svc_sec_network}/${svc_sec_prefixlen}"
    } else {
      $svc_sec_subnet = 'undef'
    }

    if $::platform::params::hostname == 'controller-0' {
      $cluster_host_addr = $::platform::network::cluster_host::params::controller0_address
    } else {
      $cluster_host_addr = $::platform::network::cluster_host::params::controller1_address
    }

    exec { 'update kubeadm pod and service secondary IPv6 subnets':
      path      => '/usr/bin:/usr/sbin:/bin:/usr/local/bin',
      command   => "dual-stack-kubeadm.py ${pod_prim_subnet} ${svc_prim_subnet} ${pod_sec_subnet} ${svc_sec_subnet} ${restart_wait} ${cluster_host_addr}",
      logoutput => true,
    }
  }
  # lint:endignore:140chars
}

class platform::kubernetes::kubeadm::dual_stack::ipv6::runtime {
  # lint:ignore:140chars
  include ::platform::network::cluster_pod::params
  include ::platform::network::cluster_pod::ipv6::params
  include ::platform::network::cluster_service::params
  include ::platform::network::cluster_service::ipv6::params
  include ::platform::network::cluster_host::ipv6::params
  if $::personality == 'controller' {
    $restart_wait = '5'

    $pod_prim_network = $::platform::network::cluster_pod::params::subnet_network
    $pod_prim_prefixlen = $::platform::network::cluster_pod::params::subnet_prefixlen
    $pod_prim_subnet = "${pod_prim_network}/${pod_prim_prefixlen}"

    if $platform::network::cluster_pod::ipv6::params::subnet_version == $::platform::params::ipv6  {
      $pod_sec_network = $::platform::network::cluster_pod::ipv6::params::subnet_network
      $pod_sec_prefixlen = $::platform::network::cluster_pod::ipv6::params::subnet_prefixlen
      $pod_sec_subnet = "${pod_sec_network}/${pod_sec_prefixlen}"
    } else {
      $pod_sec_subnet = 'undef'
    }

    $svc_prim_network = $::platform::network::cluster_service::params::subnet_network
    $svc_prim_prefixlen = $::platform::network::cluster_service::params::subnet_prefixlen
    $svc_prim_subnet = "${svc_prim_network}/${svc_prim_prefixlen}"

    if $platform::network::cluster_service::ipv6::params::subnet_version == $::platform::params::ipv6 {
      $svc_sec_network = $::platform::network::cluster_service::ipv6::params::subnet_network
      $svc_sec_prefixlen = $::platform::network::cluster_service::ipv6::params::subnet_prefixlen
      $svc_sec_subnet = "${svc_sec_network}/${svc_sec_prefixlen}"
    } else {
      $svc_sec_subnet = 'undef'
    }

    if $::platform::params::hostname == 'controller-0' {
      $cluster_host_addr = $::platform::network::cluster_host::params::controller0_address
    } else {
      $cluster_host_addr = $::platform::network::cluster_host::params::controller1_address
    }

    exec { 'update kubeadm pod and service secondary IPv6 subnets':
      path      => '/usr/bin:/usr/sbin:/bin:/usr/local/bin',
      command   => "dual-stack-kubeadm.py ${pod_prim_subnet} ${svc_prim_subnet} ${pod_sec_subnet} ${svc_sec_subnet} ${restart_wait} ${cluster_host_addr}",
      logoutput => true,
    }
  }
  # lint:endignore:140chars
}

class platform::kubernetes::dual_stack::ipv4::runtime {
  # lint:ignore:140chars
  # adds/removes secondary IPv4 subnets to pod and service
  include ::platform::network::cluster_pod::params
  include ::platform::network::cluster_pod::ipv4::params
  include ::platform::network::cluster_service::params
  include ::platform::network::cluster_service::ipv4::params
  include ::platform::network::cluster_host::ipv4::params

  $protocol = 'ipv4'
  $def_pool_filename = "/tmp/def_pool_${protocol}.yaml"
  $kubeconfig = '--kubeconfig=/etc/kubernetes/admin.conf'
  $restart_wait = '5'

  $pod_prim_network = $::platform::network::cluster_pod::params::subnet_network
  $pod_prim_prefixlen = $::platform::network::cluster_pod::params::subnet_prefixlen
  $pod_prim_subnet = "${pod_prim_network}/${pod_prim_prefixlen}"

  if $platform::network::cluster_pod::ipv4::params::subnet_version == $::platform::params::ipv4  {
    $pod_sec_network = $::platform::network::cluster_pod::ipv4::params::subnet_network
    $pod_sec_prefixlen = $::platform::network::cluster_pod::ipv4::params::subnet_prefixlen
    $pod_sec_subnet = "${pod_sec_network}/${pod_sec_prefixlen}"
    $c0_addr = $::platform::network::cluster_host::ipv4::params::controller0_address
    $state = true
  } else {
    $pod_sec_subnet = 'undef'
    $state = false
    $c0_addr = '::'
  }

  $svc_prim_network = $::platform::network::cluster_service::params::subnet_network
  $svc_prim_prefixlen = $::platform::network::cluster_service::params::subnet_prefixlen
  $svc_prim_subnet = "${svc_prim_network}/${svc_prim_prefixlen}"

  if $platform::network::cluster_service::ipv4::params::subnet_version == $::platform::params::ipv4 {
    $svc_sec_network = $::platform::network::cluster_service::ipv4::params::subnet_network
    $svc_sec_prefixlen = $::platform::network::cluster_service::ipv4::params::subnet_prefixlen
    $svc_sec_subnet = "${svc_sec_network}/${svc_sec_prefixlen}"
  } else {
    $svc_sec_subnet = 'undef'
  }

  exec { 'update kube-proxy pod secondary IPv6 subnet':
    path      => '/usr/bin:/usr/sbin:/bin:/usr/local/bin',
    command   => "dual-stack-kubeproxy.py ${pod_prim_subnet} ${pod_sec_subnet} ${restart_wait}",
    logoutput => true,
  }
  -> exec { 'update calico node pod secondary IPv6 subnet':
    path      => '/usr/bin:/usr/sbin:/bin:/usr/local/bin',
    command   => "dual-stack-calico.py ${protocol} ${state} ${c0_addr} ${restart_wait}",
    logoutput => true,
  }
  if $state == true {
    file { $def_pool_filename:
      ensure  => file,
      content => template('platform/callico_ippool.yaml.erb'),
      owner   => 'root',
      group   => 'root',
      mode    => '0640',
    }
    -> exec { "create default-${protocol}-ippool":
      path      => '/usr/bin:/usr/sbin:/bin:/usr/local/bin',
      command   => "kubectl ${kubeconfig} apply -f ${def_pool_filename}",
      logoutput => true
    }
  } else {
    exec { "delete default-${protocol}-ippool":
      path      => '/usr/bin:/usr/sbin:/bin:/usr/local/bin',
      command   => "kubectl ${kubeconfig} delete ippools.crd.projectcalico.org default-${protocol}-ippool",
      logoutput => true,
      onlyif    => "kubectl ${kubeconfig} get ippools.crd.projectcalico.org default-${protocol}-ippool ",
    }
  }
  exec { 'update multus to support IPv4':
    path      => '/usr/bin:/usr/sbin:/bin:/usr/local/bin',
    command   => "dual-stack-multus.py ${protocol} ${state} ${restart_wait}",
    logoutput => true,
  }
  # lint:endignore:140chars
}

class platform::kubernetes::dual_stack::ipv6::runtime {
  # lint:ignore:140chars
  # adds/removes secondary IPv6 subnets to pod and service
  include ::platform::network::cluster_pod::params
  include ::platform::network::cluster_pod::ipv6::params
  include ::platform::network::cluster_service::params
  include ::platform::network::cluster_service::ipv6::params
  include ::platform::network::cluster_host::ipv6::params

  $protocol = 'ipv6'
  $def_pool_filename = "/tmp/def_pool_${protocol}.yaml"
  $kubeconfig = '--kubeconfig=/etc/kubernetes/admin.conf'
  $restart_wait = '10'

  $pod_prim_network = $::platform::network::cluster_pod::params::subnet_network
  $pod_prim_prefixlen = $::platform::network::cluster_pod::params::subnet_prefixlen
  $pod_prim_subnet = "${pod_prim_network}/${pod_prim_prefixlen}"

  if $platform::network::cluster_pod::ipv6::params::subnet_version == $::platform::params::ipv6  {
    $pod_sec_network = $::platform::network::cluster_pod::ipv6::params::subnet_network
    $pod_sec_prefixlen = $::platform::network::cluster_pod::ipv6::params::subnet_prefixlen
    $pod_sec_subnet = "${pod_sec_network}/${pod_sec_prefixlen}"
    $c0_addr = $::platform::network::cluster_host::ipv6::params::controller0_address
    $state = true
  } else {
    $pod_sec_subnet = 'undef'
    $state = false
    $c0_addr = '::'
  }

  $svc_prim_network = $::platform::network::cluster_service::params::subnet_network
  $svc_prim_prefixlen = $::platform::network::cluster_service::params::subnet_prefixlen
  $svc_prim_subnet = "${svc_prim_network}/${svc_prim_prefixlen}"

  if $platform::network::cluster_service::ipv6::params::subnet_version == $::platform::params::ipv6 {
    $svc_sec_network = $::platform::network::cluster_service::ipv6::params::subnet_network
    $svc_sec_prefixlen = $::platform::network::cluster_service::ipv6::params::subnet_prefixlen
    $svc_sec_subnet = "${svc_sec_network}/${svc_sec_prefixlen}"
  } else {
    $svc_sec_subnet = 'undef'
  }

  exec { 'update kube-proxy pod secondary IPv6 subnet':
    path      => '/usr/bin:/usr/sbin:/bin:/usr/local/bin',
    command   => "dual-stack-kubeproxy.py ${pod_prim_subnet} ${pod_sec_subnet} ${restart_wait}",
    logoutput => true,
  }
  -> exec { 'update calico node pod secondary IPv6 subnet':
    path      => '/usr/bin:/usr/sbin:/bin:/usr/local/bin',
    command   => "dual-stack-calico.py ${protocol} ${state} ${c0_addr} ${restart_wait}",
    logoutput => true,
  }
  if $state == true {
    file { $def_pool_filename:
      ensure  => file,
      content => template('platform/callico_ippool.yaml.erb'),
      owner   => 'root',
      group   => 'root',
      mode    => '0640',
    }
    -> exec { "create default-${protocol}-ippool":
      path      => '/usr/bin:/usr/sbin:/bin:/usr/local/bin',
      command   => "kubectl ${kubeconfig} apply -f ${def_pool_filename}",
      logoutput => true,
    }
  } else {
    exec { "delete default-${protocol}-ippool":
      path      => '/usr/bin:/usr/sbin:/bin:/usr/local/bin',
      command   => "kubectl ${kubeconfig} delete ippools.crd.projectcalico.org default-${protocol}-ippool",
      logoutput => true,
      onlyif    => "kubectl ${kubeconfig} get ippools.crd.projectcalico.org default-${protocol}-ippool "
    }
  }
  exec { 'update multus to support IPv6':
    path      => '/usr/bin:/usr/sbin:/bin:/usr/local/bin',
    command   => "dual-stack-multus.py ${protocol} ${state} ${restart_wait}",
    logoutput => true,
  }
  # lint:endignore:140chars
}

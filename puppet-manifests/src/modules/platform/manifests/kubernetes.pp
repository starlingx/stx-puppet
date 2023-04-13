class platform::kubernetes::params (
  $enabled = true,
  # K8S version we are upgrading to (None if not in an upgrade)
  $upgrade_to_version = undef,
  # K8S version running on a host
  $version = undef,
  $kubeadm_version = undef,
  $kubelet_version = undef,
  $node_ip = undef,
  $service_domain = undef,
  $dns_service_ip = undef,
  $host_labels = [],
  $k8s_cpuset = undef,
  $k8s_nodeset = undef,
  $k8s_platform_cpuset = undef,
  $k8s_reserved_mem = undef,
  $k8s_all_reserved_cpuset = undef,
  $k8s_cpu_mgr_policy = 'none',
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
  # The file holding the root CA cert/key to update to
  $rootca_certfile_new = '/etc/kubernetes/pki/ca_new.crt',
  $rootca_keyfile_new = '/etc/kubernetes/pki/ca_new.key',
  $kubelet_image_gc_low_threshold_percent = 75,
  $kubelet_image_gc_high_threshold_percent = 79,
  $kubelet_eviction_hard_imagefs_available = '2Gi',
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

class platform::kubernetes::configuration {

  if 'kube-ignore-isol-cpus=enabled' in $::platform::kubernetes::params::host_labels {
    $ensure = 'present'
  } else {
    $ensure = 'absent'
  }

  file { '/etc/kubernetes/ignore_isolcpus':
    ensure => $ensure,
    owner  => 'root',
    group  => 'root',
    mode   => '0644',
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

class platform::kubernetes::bindmounts {
  include ::platform::kubernetes::params

  $kubeadm_version = $::platform::kubernetes::params::kubeadm_version
  $kubelet_version = $::platform::kubernetes::params::kubelet_version

  # In the following two bind mounts, the "remounts" option *must* be
  # set to 'false' otherwise it doesn't work reliably.  In my testing
  # (as of July 2021) it will update /etc/fstab but any existing
  # mounts will be left untouched.  This sort of makes sense, as
  # the mount man page specifies that the "remount" option does not
  # change device or mount point and we may want to change the device.

  notice("setting stage1 bind mount, kubeadm_version is ${kubeadm_version}")
  mount { '/usr/local/kubernetes/current/stage1':
    ensure   => mounted,
    device   => "/usr/local/kubernetes/${kubeadm_version}/stage1",
    fstype   => 'none',
    options  => 'x-systemd.after=ostree-remount,rw,bind',
    remounts => false,
  }

  notice("setting stage2 bind mount, kubelet_version is ${kubelet_version}")
  mount { '/usr/local/kubernetes/current/stage2':
    ensure   => mounted,
    device   => "/usr/local/kubernetes/${kubelet_version}/stage2",
    fstype   => 'none',
    options  => 'x-systemd.after=ostree-remount,rw,bind',
    remounts => false,
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
  }
}

class platform::kubernetes::kubeadm {

  include ::platform::docker::params
  include ::platform::kubernetes::params
  include ::platform::params

  # Update kubeadm/kubelet bindmounts if needed.
  require platform::kubernetes::bindmounts

  $node_ip = $::platform::kubernetes::params::node_ip
  $host_labels = $::platform::kubernetes::params::host_labels
  $k8s_platform_cpuset = $::platform::kubernetes::params::k8s_platform_cpuset
  $k8s_reserved_mem = $::platform::kubernetes::params::k8s_reserved_mem
  $k8s_all_reserved_cpuset = $::platform::kubernetes::params::k8s_all_reserved_cpuset
  $k8s_cni_bin_dir = $::platform::kubernetes::params::k8s_cni_bin_dir
  $k8s_vol_plugin_dir = $::platform::kubernetes::params::k8s_vol_plugin_dir
  $k8s_cpu_mgr_policy = $::platform::kubernetes::params::k8s_cpu_mgr_policy
  $k8s_topology_mgr_policy = $::platform::kubernetes::params::k8s_topology_mgr_policy
  $k8s_pod_max_pids = $::platform::kubernetes::params::k8s_pod_max_pids

  $iptables_file = "net.bridge.bridge-nf-call-ip6tables = 1
    net.bridge.bridge-nf-call-iptables = 1"

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
        # Enable TopologyManager for hosts with the worker subfunction.
        # Exceptions are:
        #   - DC System controllers
        #   - Virtualized nodes (lab environment only)

        $opts = join(['--feature-gates TopologyManager=true',
                      "--cpu-manager-policy=${k8s_cpu_mgr_policy}",
                      "--topology-manager-policy=${k8s_topology_mgr_policy}"], ' ')

        if $k8s_cpu_mgr_policy == 'none' {
          $k8s_reserved_cpus = $k8s_platform_cpuset
        } else {
          # The union of platform, isolated, and vswitch
          $k8s_reserved_cpus = $k8s_all_reserved_cpuset
        }

        $opts_res_cpus = "--reserved-cpus=${k8s_reserved_cpus}"
        $k8s_cpu_manager_opts = join([$opts,
                                      $opts_sys_res,
                                      $opts_res_cpus], ' ')
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

class platform::kubernetes::master::init
  inherits ::platform::kubernetes::params {

  include ::platform::params
  include ::platform::docker::params
  include ::platform::dockerdistribution::params

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
      group  => $::platform::params::protected_group_name,
      mode   => '0640',
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

    # set kubelet monitored by pmond
    -> file { '/etc/pmon.d/kubelet.conf':
      ensure  => file,
      content => template('platform/kubelet-pmond-conf.erb'),
      owner   => 'root',
      group   => 'root',
      mode    => '0644',
    }

    # Reload systemd
    -> exec { 'perform systemctl daemon reload for kubelet override':
      command   => 'systemctl daemon-reload',
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
  }

  # Run kube-cert-rotation daily
  cron { 'kube-cert-rotation':
    ensure      => 'present',
    command     => '/usr/bin/kube-cert-rotation.sh',
    environment => 'PATH=/bin:/usr/bin:/usr/sbin',
    minute      => '10',
    hour        => '*/24',
    user        => 'root',
  }
}

class platform::kubernetes::master
  inherits ::platform::kubernetes::params {

  contain ::platform::kubernetes::kubeadm
  contain ::platform::kubernetes::cgroup
  contain ::platform::kubernetes::master::init
  contain ::platform::kubernetes::coredns
  contain ::platform::kubernetes::firewall
  contain ::platform::kubernetes::configuration

  Class['::platform::sysctl::controller::reserve_ports'] -> Class[$name]
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

  # set kubelet monitored by pmond
  -> file { '/etc/pmon.d/kubelet.conf':
    ensure  => file,
    content => template('platform/kubelet-pmond-conf.erb'),
    owner   => 'root',
    group   => 'root',
    mode    => '0644',
  }

  # Reload systemd
  -> exec { 'perform systemctl daemon reload for kubelet override':
    command   => 'systemctl daemon-reload',
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
      ports        => $dports,
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

  # Get the short kubernetes version without the leading 'v'.
  $short_version = regsubst($upgrade_to_version, '^v(.*)', '\1')
  $local_registry_auth = "${::platform::dockerdistribution::params::registry_username}:${::platform::dockerdistribution::params::registry_password}" # lint:ignore:140chars
  $creds_command = '$(cat /tmp/puppet/registry_credentials)'

  $resource_title = 'pre pull images'
  $command = "/usr/local/kubernetes/${short_version}/stage1/usr/bin/kubeadm --kubeconfig=/etc/kubernetes/admin.conf config images list --kubernetes-version ${upgrade_to_version} | xargs -i crictl pull --creds ${creds_command} registry.local:9001/{}" # lint:ignore:140chars

  platform::kubernetes::pull_images_from_registry { 'pull images from private registry':
    resource_title      => $resource_title,
    command             => $command,
    before_exec         => undef,
    local_registry_auth => $local_registry_auth,
  }
}

class platform::kubernetes::upgrade_first_control_plane
  inherits ::platform::kubernetes::params {

  include ::platform::params

  # Update kubeadm bindmount if needed.
  require platform::kubernetes::bindmounts

  # Update apiserver and kubelet config to configure cgroupDriver and RemoveSelfLink feature-gates
  exec { 'update kubeadm-config':
    command   => '/usr/local/sbin/upgrade_k8s_config.sh',
    logoutput => true
  }

  # The kubeadm command below doesn't have the credentials to download the
  # images from local registry when they are not present in the cache, so we
  # assure here that the images are downloaded.
  require platform::kubernetes::pre_pull_control_plane_images

  # The --allow-*-upgrades options allow us to upgrade to any k8s release if necessary
  # The -v6 gives verbose debug output includes health, GET response, delay.
  # Puppet captures no command output on timeout. Workaround:
  # - use 'stdbuf' to flush line buffer for stdout and stderr
  # - redirect stderr to stdout
  # - use 'tee' so we write output to both stdout and file
  # Since we hit default 300 second timeout under load (i.e., upgrade 250 subclouds
  # in parallel), specify larger timeout.
  exec { 'upgrade first control plane':
    command   => "stdbuf -oL -eL kubeadm -v6 --kubeconfig=/etc/kubernetes/admin.conf upgrade apply ${version} --allow-experimental-upgrades --allow-release-candidate-upgrades -y 2>&1 | tee /var/log/puppet/latest/kubeadm-upgrade-apply.log", # lint:ignore:140chars
    logoutput => true,
    timeout   => 600,
    require   => Exec['update kubeadm-config']
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
}

class platform::kubernetes::upgrade_control_plane
  inherits ::platform::kubernetes::params {

  # Update kubeadm bindmount if needed.
  require platform::kubernetes::bindmounts

  # The kubeadm command below doesn't have the credentials to download the
  # images from local registry when they are not present in the cache, so we
  # assure here that the images are downloaded.
  require platform::kubernetes::pre_pull_control_plane_images

  # control plane is only upgraded on a controller
  exec { 'upgrade control plane':
    command   => 'kubeadm upgrade node',
    logoutput => true,
  }
}

class platform::kubernetes::mask_stop_kubelet {
  # Mask restarting kubelet and stop it now so that we can unmount
  # and re-mount the bind mount.
  exec { 'mask kubelet for master upgrade':
    command => '/usr/bin/systemctl mask --runtime --now kubelet',
  }
  # Tell pmon to stop kubelet so it doesn't try to restart it
  -> exec { 'stop kubelet for upgrade':
      command => '/usr/local/sbin/pmon-stop kubelet',
  }
}

class platform::kubernetes::unmask_start_kubelet
  inherits ::platform::kubernetes::params {

  $kubelet_version = $::platform::kubernetes::params::kubelet_version
  # The next three steps are a hack.  While stress-testing in the lab it
  # was discovered that intermittently the attempt to remount the
  # "stage2" mountpoint fails due to it being busy.  Waiting for kubelet
  # to exit is not sufficient, as occasionally the remount attempt
  # happens while kubectl is running.  The best solution found so far
  # is to retry the unmount repeatedly until it succeeds, and then
  # explicitly update the /etc/fstab file and mount the filesystem
  # again.
  # The worst case seen so far is a 16-second delay before the unmount
  # actually succeeds.  In the future we should probably switch to using
  # symlinks instead of bindmounts so that they can be changed
  # atomically.

  # Try unmounting stage2 until it succeeds
  exec { 'unmount k8s stage2 for upgrade':
    command   => '/usr/bin/umount /usr/local/kubernetes/current/stage2',
    tries     => 30,
    try_sleep => 1,
    timeout   => 10,
  }
  -> exec { 'update fstab for upgrade':
      command => "/usr/bin/sed -i \"s#/usr/local/kubernetes/[0-9]\\.[0-9]\\+\\.[0-9]\\+/stage2#/usr/local/kubernetes/${kubelet_version}/stage2#\" /etc/fstab", # lint:ignore:140chars
  }
  # Remount k8s stage2 so that the puppet mount class works
  -> exec { 'mount k8s stage2 for upgrade':
      command   => '/usr/bin/mount /usr/local/kubernetes/current/stage2',
      tries     => 30,
      try_sleep => 1,
      timeout   => 10,
  }
  # Unmask and restart kubelet after the bind mount is updated.
  -> exec { 'unmask kubelet for upgrade':
      command => '/usr/bin/systemctl unmask --runtime kubelet',
  }
  -> exec { 'start kubelet':
      command => '/usr/local/sbin/pmon-start kubelet'
  }
}

class platform::kubernetes::master::upgrade_kubelet
  inherits ::platform::kubernetes::params {
    include platform::kubernetes::mask_stop_kubelet
    include platform::kubernetes::unmask_start_kubelet

    Class['platform::kubernetes::mask_stop_kubelet'] -> Class['platform::kubernetes::unmask_start_kubelet']

}

class platform::kubernetes::worker::upgrade_kubelet
  inherits ::platform::kubernetes::params {
  include ::platform::dockerdistribution::params
  include platform::kubernetes::mask_stop_kubelet
  include platform::kubernetes::unmask_start_kubelet

  # workers use kubelet.conf rather than admin.conf
  $kubelet_version = $::platform::kubernetes::params::kubelet_version
  $local_registry_auth = "${::platform::dockerdistribution::params::registry_username}:${::platform::dockerdistribution::params::registry_password}" # lint:ignore:140chars
  $creds_command = '$(cat /tmp/puppet/registry_credentials)'

  $resource_title = 'pull pause image'
  $command = "kubeadm --kubeconfig=/etc/kubernetes/kubelet.conf config images list --kubernetes-version ${upgrade_to_version} 2>/dev/null | grep pause: | xargs -i crictl pull --creds ${creds_command} registry.local:9001/{}" # lint:ignore:140chars
  $before_exec = 'upgrade kubelet for worker'

  platform::kubernetes::pull_images_from_registry { 'pull images from private registry':
    resource_title      => $resource_title,
    command             => $command,
    before_exec         => $before_exec,
    local_registry_auth => $local_registry_auth,
  }

  exec { 'upgrade kubelet for worker':
    command   => 'kubeadm --kubeconfig=/etc/kubernetes/kubelet.conf upgrade node',
    logoutput => true,
  }
  -> Class['platform::kubernetes::mask_stop_kubelet']
  -> Class['platform::kubernetes::unmask_start_kubelet']

}

class platform::kubernetes::master::change_apiserver_parameters (
  $etcd_cafile = $platform::kubernetes::params::etcd_cafile,
  $etcd_certfile = $platform::kubernetes::params::etcd_certfile,
  $etcd_keyfile = $platform::kubernetes::params::etcd_keyfile,
  $etcd_servers = $platform::kubernetes::params::etcd_servers,
) inherits ::platform::kubernetes::params {

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
      command => "python /usr/share/puppet/modules/platform/files/change_k8s_control_plane_params.py --etcd_cafile ${etcd_cafile} --etcd_certfile ${etcd_certfile} --etcd_keyfile ${etcd_keyfile} --etcd_servers ${etcd_servers}",  # lint:ignore:140chars
      timeout => 600}
  } else {
    exec { 'update configmap and apply changes to control plane components':
      command => 'python /usr/share/puppet/modules/platform/files/change_k8s_control_plane_params.py',
      timeout => 600}
  }
}

class platform::kubernetes::certsans::runtime
  inherits ::platform::kubernetes::params {
  include ::platform::params
  include ::platform::network::mgmt::params
  include ::platform::network::oam::params
  include ::platform::network::cluster_host::params

  if $::platform::network::mgmt::params::subnet_version == $::platform::params::ipv6 {
    $localhost_address = '::1'
  } else {
    $localhost_address = '127.0.0.1'
  }

  if $::platform::params::system_mode == 'simplex' {
    $certsans = "\"${platform::network::cluster_host::params::controller_address}, \
                   ${localhost_address}, \
                   ${platform::network::oam::params::controller_address}\""
  } else {
    $certsans = "\"${platform::network::cluster_host::params::controller_address}, \
                   ${platform::network::cluster_host::params::controller0_address}, \
                   ${platform::network::cluster_host::params::controller1_address}, \
                   ${localhost_address}, \
                   ${platform::network::oam::params::controller_address}, \
                   ${platform::network::oam::params::controller0_address}, \
                   ${platform::network::oam::params::controller1_address}\""
  }

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
    command => '/usr/bin/systemctl restart kubelet',
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
    command => '/usr/bin/systemctl restart kubelet',
  }
}

class platform::kubernetes::master::rootca::trustnewca::runtime
  inherits ::platform::kubernetes::params {
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
  # Restart sysinv-conductor and sysinv-inv since they cache clients with
  # credentials from admin.conf
  -> exec { 'restart_sysinv_conductor':
    command => 'sm-restart service sysinv-conductor',
  }
  # Restart cert-mon since it uses admin.conf
  -> exec { 'restart_cert_mon':
    command => 'sm-restart-safe service cert-mon',
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
    command => '/usr/bin/systemctl restart kubelet',
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
    command => '/usr/bin/systemctl restart kubelet',
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

  # Update admin.conf with new cert/key
  -> exec { 'update_admin_conf_credentials':
    environment => [ 'KUBECONFIG=/etc/kubernetes/admin.conf' ],
    command     => "kubectl config set-credentials kubernetes-admin --client-key /tmp/kube_rootca_update/kubernetes-admin.key \
                    --client-certificate /tmp/kube_rootca_update/kubernetes-admin.crt --embed-certs",
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

  # Update kubeadm bindmount if needed.
  require platform::kubernetes::bindmounts

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

  # Update kubeadm/kubelet bindmounts if needed.
  include platform::kubernetes::bindmounts

  # Regenerate /var/lib/kubelet/config.yaml based on current kubelet-config
  # ConfigMap. This does not regenerate /var/lib/kubelet/kubeadm-flags.env.
  exec { 'update kubelet config':
    environment => [ 'KUBECONFIG=/etc/kubernetes/admin.conf:/etc/kubernetes/kubelet.conf' ],
    provider    => shell,
    command     => 'kubeadm upgrade node phase kubelet-config',
    timeout     => 60,
    logoutput   => true,
  }
  -> exec { 'restart kubelet':
      command => '/usr/local/sbin/pmon-restart kubelet'
  }
}

class platform::kubernetes::upgrade_abort
  inherits ::platform::kubernetes::params {

  include platform::kubernetes::mask_stop_kubelet
  include platform::kubernetes::unmask_start_kubelet
  include platform::kubernetes::bindmounts

  exec { 'restore static manifest files':
    command => '/usr/bin/cp -r  /var/rootdirs/opt/backups/k8s-control-plane/static-pod-manifests/* /etc/kubernetes/manifests',
    require => Class['platform::kubernetes::mask_stop_kubelet']
  }
  -> exec { 'restart etcd':
      command => '/usr/bin/systemctl restart etcd',
  }
  -> Class['platform::kubernetes::bindmounts']
  -> Class['platform::kubernetes::unmask_start_kubelet']
}

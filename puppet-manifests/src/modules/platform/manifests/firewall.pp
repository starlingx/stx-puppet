define platform::firewall::rule (
  $service_name,
  $chain = 'INPUT',
  $destination = undef,
  $ensure = present,
  $host = 'ALL',
  $jump  = undef,
  $outiface = undef,
  $ports = undef,
  $proto = 'tcp',
  $table = undef,
  $tosource = undef,
) {

  include ::platform::params
  include ::platform::network::oam::params

  $ip_version = $::platform::network::oam::params::subnet_version

  $provider = $ip_version ? {
    6 => 'ip6tables',
    default => 'iptables',
  }

  $source = $host ? {
    'ALL' => $ip_version ? {
      6  => '::/0',
      default => '0.0.0.0/0'
    },
    default => $host,
  }

  $heading = $chain ? {
    'OUTPUT' => 'outgoing',
    'POSTROUTING' => 'forwarding',
    default => 'incoming',
  }

  # NAT rule
  if $jump == 'SNAT' or $jump == 'MASQUERADE' {
    firewall { "500 ${service_name} ${heading} ${title}":
      ensure      => $ensure,
      table       => $table,
      proto       => $proto,
      dport       => $ports,
      outiface    => $outiface,
      jump        => $jump,
      tosource    => $tosource,
      destination => $destination,
      source      => $source,
      provider    => $provider,
      chain       => $chain,
    }
  }
  else {
    if $ports == undef {
      firewall { "500 ${service_name} ${heading} ${title}":
        ensure   => $ensure,
        proto    => $proto,
        action   => 'accept',
        source   => $source,
        provider => $provider,
        chain    => $chain,
      }
    }
    else {
      firewall { "500 ${service_name} ${heading} ${title}":
        ensure   => $ensure,
        proto    => $proto,
        dport    => $ports,
        action   => 'accept',
        source   => $source,
        provider => $provider,
        chain    => $chain,
      }
    }
  }
}

class platform::firewall::calico::controller {
  contain ::platform::firewall::calico::is_config_available
  contain ::platform::firewall::calico::oam
  contain ::platform::firewall::calico::mgmt
  contain ::platform::firewall::calico::cluster_host
  contain ::platform::firewall::calico::pxeboot
  contain ::platform::firewall::calico::storage
  contain ::platform::firewall::calico::admin
  contain ::platform::firewall::calico::hostendpoint
  contain ::platform::firewall::nat::admin
  contain ::platform::firewall::rbac::worker

  Class['::platform::kubernetes::gate'] -> Class[$name]

  Class['::platform::firewall::calico::is_config_available']
  -> Class['::platform::firewall::calico::oam']
  -> Class['::platform::firewall::calico::mgmt']
  -> Class['::platform::firewall::calico::cluster_host']
  -> Class['::platform::firewall::calico::pxeboot']
  -> Class['::platform::firewall::calico::storage']
  -> Class['::platform::firewall::calico::admin']
  -> Class['::platform::firewall::calico::hostendpoint']
  -> Class['::platform::firewall::nat::admin']
  -> Class['::platform::firewall::rbac::worker']
}

class platform::firewall::calico::worker {
  contain ::platform::firewall::calico::is_config_available
  contain ::platform::firewall::calico::mgmt
  contain ::platform::firewall::calico::cluster_host
  contain ::platform::firewall::calico::pxeboot
  contain ::platform::firewall::calico::storage
  contain ::platform::firewall::calico::hostendpoint

  Class['::platform::kubernetes::worker'] -> Class[$name]

  Class['::platform::firewall::calico::is_config_available']
  -> Class['::platform::firewall::calico::mgmt']
  -> Class['::platform::firewall::calico::cluster_host']
  -> Class['::platform::firewall::calico::pxeboot']
  -> Class['::platform::firewall::calico::storage']
  -> Class['::platform::firewall::calico::hostendpoint']
}

class platform::firewall::runtime {
  include ::platform::firewall::calico::oam
  include ::platform::firewall::calico::mgmt
  include ::platform::firewall::calico::cluster_host
  include ::platform::firewall::calico::pxeboot
  include ::platform::firewall::calico::storage
  include ::platform::firewall::calico::admin
  include ::platform::firewall::calico::hostendpoint
  include ::platform::firewall::nat::admin
  include ::platform::firewall::rbac::worker

  Class['::platform::firewall::calico::oam']
  -> Class['::platform::firewall::calico::mgmt']
  -> Class['::platform::firewall::calico::cluster_host']
  -> Class['::platform::firewall::calico::pxeboot']
  -> Class['::platform::firewall::calico::storage']
  -> Class['::platform::firewall::calico::admin']
  -> Class['::platform::firewall::calico::hostendpoint']
  -> Class['::platform::firewall::nat::admin']
  -> Class['::platform::firewall::rbac::worker']
}

class platform::firewall::mgmt::runtime {
  include ::platform::firewall::calico::mgmt
}

class platform::firewall::admin::runtime {
  include ::platform::firewall::calico::admin
  include ::platform::firewall::nat::admin
}

class platform::firewall::calico::oam (
  $config = {}
) {
  if $config != {} {
    $apply_script = 'calico_firewall_apply_policy.sh'
    if $::personality == 'worker' {
      $cfgf = '/etc/kubernetes/kubelet.conf'
    } elsif $::personality == 'controller' {
      $cfgf = '/etc/kubernetes/admin.conf'
    }
    $yaml_config = hash2yaml($config)
    $gnp_name = "${::personality}-oam-if-gnp"
    $file_name_gnp = "/tmp/gnp_${gnp_name}.yaml"
    file { $file_name_gnp:
      ensure  => file,
      content => template('platform/calico_platform_network_if_gnp.yaml.erb'),
      owner   => 'root',
      group   => 'root',
      mode    => '0640',
    }
    -> exec { "apply globalnetworkpolicies ${gnp_name} with ${file_name_gnp}":
      path      => '/usr/bin:/usr/sbin:/bin:/usr/local/bin',
      command   => "${apply_script} ${gnp_name} ${file_name_gnp} ${cfgf}",
      logoutput => true
    }
  }
}

class platform::firewall::calico::mgmt (
  $config = {}
) {
  if $config != {} {
    $apply_script = 'calico_firewall_apply_policy.sh'
    if $::personality == 'worker' {
      $cfgf = '/etc/kubernetes/kubelet.conf'
    } elsif $::personality == 'controller' {
      $cfgf = '/etc/kubernetes/admin.conf'
    }
    $yaml_config = hash2yaml($config)
    $gnp_name = "${::personality}-mgmt-if-gnp"
    $file_name_gnp = "/tmp/gnp_${gnp_name}.yaml"
    file { $file_name_gnp:
      ensure  => file,
      content => template('platform/calico_platform_network_if_gnp.yaml.erb'),
      owner   => 'root',
      group   => 'root',
      mode    => '0640',
    }
    -> exec { "apply globalnetworkpolicies ${gnp_name} with ${file_name_gnp}":
      path      => '/usr/bin:/usr/sbin:/bin:/usr/local/bin',
      command   => "${apply_script} ${gnp_name} ${file_name_gnp} ${cfgf}",
      logoutput => true
    }
  }
}

class platform::firewall::calico::cluster_host  (
  $config = {}
) {
  if $config != {} {
    $apply_script = 'calico_firewall_apply_policy.sh'
    if $::personality == 'worker' {
      $cfgf = '/etc/kubernetes/kubelet.conf'
    } elsif $::personality == 'controller' {
      $cfgf = '/etc/kubernetes/admin.conf'
    }
    $yaml_config = hash2yaml($config)
    $gnp_name = "${::personality}-cluster-host-if-gnp"
    $file_name_gnp = "/tmp/gnp_${gnp_name}.yaml"
    file { $file_name_gnp:
      ensure  => file,
      content => template('platform/calico_platform_network_if_gnp.yaml.erb'),
      owner   => 'root',
      group   => 'root',
      mode    => '0640',
    }
    -> exec { "apply globalnetworkpolicies ${gnp_name} with ${file_name_gnp}":
      path      => '/usr/bin:/usr/sbin:/bin:/usr/local/bin',
      command   => "${apply_script} ${gnp_name} ${file_name_gnp} ${cfgf}",
      logoutput => true
    }
  }
}

class platform::firewall::calico::pxeboot  (
  $config = {}
) {
  if $config != {} {
    $apply_script = 'calico_firewall_apply_policy.sh'
    if $::personality == 'worker' {
      $cfgf = '/etc/kubernetes/kubelet.conf'
    } elsif $::personality == 'controller' {
      $cfgf = '/etc/kubernetes/admin.conf'
    }
    $yaml_config = hash2yaml($config)
    $gnp_name = "${::personality}-pxeboot-if-gnp"
    $file_name_gnp = "/tmp/gnp_${gnp_name}.yaml"
    file { $file_name_gnp:
      ensure  => file,
      content => template('platform/calico_platform_network_if_gnp.yaml.erb'),
      owner   => 'root',
      group   => 'root',
      mode    => '0640',
    }
    -> exec { "apply globalnetworkpolicies ${gnp_name} with ${file_name_gnp}":
      path      => '/usr/bin:/usr/sbin:/bin:/usr/local/bin',
      command   => "${apply_script} ${gnp_name} ${file_name_gnp} ${cfgf}",
      logoutput => true
    }
  }
}

class platform::firewall::calico::storage  (
  $config = {}
) {
  if $config != {} {
    $apply_script = 'calico_firewall_apply_policy.sh'
    if $::personality == 'worker' {
      $cfgf = '/etc/kubernetes/kubelet.conf'
    } elsif $::personality == 'controller' {
      $cfgf = '/etc/kubernetes/admin.conf'
    }
    $yaml_config = hash2yaml($config)
    $gnp_name = "${::personality}-storage-if-gnp"
    $file_name_gnp = "/tmp/gnp_${gnp_name}.yaml"
    file { $file_name_gnp:
      ensure  => file,
      content => template('platform/calico_platform_network_if_gnp.yaml.erb'),
      owner   => 'root',
      group   => 'root',
      mode    => '0640',
    }
    -> exec { "apply globalnetworkpolicies ${gnp_name} with ${file_name_gnp}":
      path      => '/usr/bin:/usr/sbin:/bin:/usr/local/bin',
      command   => "${apply_script} ${gnp_name} ${file_name_gnp} ${cfgf}",
      logoutput => true
    }
  }
}

class platform::firewall::calico::admin  (
  $config = {}
) {
  if $config != {} {
    $apply_script = 'calico_firewall_apply_policy.sh'
    if $::personality == 'worker' {
      $cfgf = '/etc/kubernetes/kubelet.conf'
    } elsif $::personality == 'controller' {
      $cfgf = '/etc/kubernetes/admin.conf'
    }
    $yaml_config = hash2yaml($config)
    $gnp_name = "${::personality}-admin-if-gnp"
    $file_name_gnp = "/tmp/gnp_${gnp_name}.yaml"
    file { $file_name_gnp:
      ensure  => file,
      content => template('platform/calico_platform_network_if_gnp.yaml.erb'),
      owner   => 'root',
      group   => 'root',
      mode    => '0640',
    }
    -> exec { "apply globalnetworkpolicies ${gnp_name} with ${file_name_gnp}":
      path      => '/usr/bin:/usr/sbin:/bin:/usr/local/bin',
      command   => "${apply_script} ${gnp_name} ${file_name_gnp} ${cfgf}",
      logoutput => true
    }
  }
}

class platform::firewall::calico::hostendpoint (
  $config = {}
) {
  $active_heps = keys($config)
  if $::personality == 'worker' {
    $cfgf = '/etc/kubernetes/kubelet.conf'
  } elsif $::personality == 'controller' {
    $cfgf = '/etc/kubernetes/admin.conf'
  }

  if $config != {} {
    $apply_script = 'calico_firewall_apply_hostendp.sh'
    $config.each |$key, $value| {
      # create/update host endpoint
      $file_name_hep = "/tmp/hep_${key}.yaml"
      $yaml_config = hash2yaml($value)
      file { $file_name_hep:
        ensure  => file,
        content => template('platform/calico_platform_firewall_if_hep.yaml.erb'),
        owner   => 'root',
        group   => 'root',
        mode    => '0640',
      }
      -> exec { "apply hostendpoints ${key} with ${file_name_hep}":
        path      => '/usr/bin:/usr/sbin:/bin:/usr/local/bin',
        command   => "${apply_script} ${key} ${file_name_hep} ${cfgf}",
        logoutput => true
      }
    }
  }

  # storage nodes do not run k8s
  if $::personality != 'storage' {

    $remove_script = 'remove_unused_calico_hostendpoints.sh'
    $file_hep_active = '/tmp/hep_active.txt'
    exec { "get active hostendepoints: ${active_heps}":
      command => "echo ${active_heps} > ${file_hep_active}",
    }
    -> exec { "remove unused hostendepoints ${::hostname} ${file_hep_active}":
      path    => '/usr/bin:/usr/sbin:/bin:/usr/local/bin',
      command => "${remove_script} ${::hostname} ${file_hep_active} ${cfgf}",
      onlyif  => "test -f ${file_hep_active} && test ! -f /etc/platform/.platform_firewall_config_required"
    }
  }
}

class platform::firewall::calico::is_config_available {
  include ::platform::firewall::calico::oam
  include ::platform::firewall::calico::mgmt
  include ::platform::firewall::calico::cluster_host
  include ::platform::firewall::calico::pxeboot
  include ::platform::firewall::calico::storage
  include ::platform::firewall::calico::admin
  include ::platform::firewall::calico::hostendpoint
  if $::personality != 'storage' {
    if ($::platform::firewall::calico::oam::config == {}
          and $::platform::firewall::calico::mgmt::config == {}
          and $::platform::firewall::calico::cluster_host::config == {}
          and $::platform::firewall::calico::pxeboot::config == {}
          and $::platform::firewall::calico::storage::config == {}
          and $::platform::firewall::calico::admin::config == {}
          and $::platform::firewall::calico::hostendpoint::config == {}) {
      exec { 'request platform::firewall runtime execution':
        path      => '/usr/bin:/usr/sbin:/bin:/usr/local/bin',
        command   => 'touch /etc/platform/.platform_firewall_config_required',
        logoutput => true
      }
    }
  }
}

class platform::firewall::nat::admin::params (
  $transport = 'tcp',
  $table = 'nat',
  # openLDAP ports 636, 389
  $dports = [636, 389],
  $chain = 'POSTROUTING',
  $jump = 'SNAT',
) {}

class platform::firewall::nat::admin (
  $enabled = true,
) inherits ::platform::firewall::nat::admin::params {

  include ::platform::params

  if $::platform::params::distributed_cloud_role == 'subcloud' {
    include ::platform::network::mgmt::params
    include ::platform::network::admin::params

    $system_mode = $::platform::params::system_mode
    $mgmt_subnet = $::platform::network::mgmt::params::subnet_network
    $mgmt_prefixlen = $::platform::network::mgmt::params::subnet_prefixlen
    $admin_float_ip = $::platform::network::admin::params::controller_address
    $admin_interface = $::platform::network::admin::params::interface_name
    $s_mgmt_subnet = "${mgmt_subnet}/${mgmt_prefixlen}"

    if $enabled {
      $ensure = 'present'
    } else {
      $ensure = 'absent'
    }

    if $system_mode != 'simplex' and $admin_interface {
      platform::firewall::rule { 'ldap-admin-nat':
        ensure       => $ensure,
        service_name => 'subcloud',
        table        => $table,
        chain        => $chain,
        proto        => $transport,
        jump         => $jump,
        ports        => $dports,
        host         => $s_mgmt_subnet,
        outiface     => $admin_interface,
        tosource     => $admin_float_ip,
      }
    }
  }
}

class platform::firewall::nat::admin::runtime {
  include ::platform::firewall::nat::admin
}

class platform::firewall::nat::admin::remove
  inherits ::platform::firewall::nat::admin::params {

  class { '::platform::firewall::nat::admin':
    enabled    => false,
  }
}

class platform::firewall::rbac::worker {
  if $::personality == 'controller' {
    $k8cfg = '--kubeconfig=/etc/kubernetes/admin.conf'
    $k8api = 'rbac.authorization.k8s.io'
    $reconfig = '/etc/platform/.platform_firewall_config_required'
    $file_name = '/tmp/rbac_worker_permission_for_firewall.yaml'
    file { $file_name:
      ensure  => file,
      content => template('platform/calico_platform_firewall_worker_permission.yaml.erb'),
      owner   => 'root',
      group   => 'root',
      mode    => '0640',
    }
    -> exec { 'apply permission to worker node firewall configuration':
      path      => '/usr/bin:/usr/sbin:/bin:/usr/local/bin',
      command   => "kubectl ${k8cfg} apply -f ${file_name} && if [ -f ${reconfig} ]; then rm -f ${reconfig}; fi",
      onlyif    => "kubectl ${k8cfg} get clusterrolebindings.${k8api} cluster-admin || (touch ${reconfig} && exit 1)",
      logoutput => true
    }
  }
}
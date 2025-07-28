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
  $l3proto = undef,
) {

  include ::platform::params
  include ::platform::network::oam::params

  if $l3proto == undef {
    # if not provided use the primary OAM address subnet_version
    $ip_version = $::platform::network::oam::params::subnet_version
  } elsif $l3proto == $::platform::params::ipv4 {
    $ip_version = $::platform::params::ipv4
  } elsif $l3proto == $::platform::params::ipv6 {
    $ip_version = $::platform::params::ipv6
  }

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
  contain ::platform::firewall::dc::nat::ldap
  contain ::platform::firewall::extra
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
  -> Class['::platform::firewall::dc::nat::ldap']
  -> Class['::platform::firewall::extra']
  -> Class['::platform::firewall::rbac::worker']
}

class platform::firewall::calico::worker {
  contain ::platform::firewall::calico::is_config_available
  contain ::platform::firewall::calico::mgmt
  contain ::platform::firewall::calico::cluster_host
  contain ::platform::firewall::calico::pxeboot
  contain ::platform::firewall::calico::storage
  contain ::platform::firewall::calico::hostendpoint
  contain ::platform::firewall::extra

  Class['::platform::kubernetes::worker'] -> Class[$name]

  Class['::platform::firewall::calico::is_config_available']
  -> Class['::platform::firewall::calico::mgmt']
  -> Class['::platform::firewall::calico::cluster_host']
  -> Class['::platform::firewall::calico::pxeboot']
  -> Class['::platform::firewall::calico::storage']
  -> Class['::platform::firewall::calico::hostendpoint']
  -> Class['::platform::firewall::extra']
}

class platform::firewall::runtime {
  include ::platform::firewall::calico::oam
  include ::platform::firewall::calico::mgmt
  include ::platform::firewall::calico::cluster_host
  include ::platform::firewall::calico::pxeboot
  include ::platform::firewall::calico::storage
  include ::platform::firewall::calico::admin
  include ::platform::firewall::calico::hostendpoint
  include ::platform::firewall::dc::nat::ldap
  include ::platform::firewall::extra
  include ::platform::firewall::rbac::worker

  Class['::platform::firewall::calico::oam']
  -> Class['::platform::firewall::calico::mgmt']
  -> Class['::platform::firewall::calico::cluster_host']
  -> Class['::platform::firewall::calico::pxeboot']
  -> Class['::platform::firewall::calico::storage']
  -> Class['::platform::firewall::calico::admin']
  -> Class['::platform::firewall::calico::hostendpoint']
  -> Class['::platform::firewall::dc::nat::ldap']
  -> Class['::platform::firewall::extra']
  -> Class['::platform::firewall::rbac::worker']
}

class platform::firewall::mgmt::runtime {
  include ::platform::firewall::calico::mgmt
  include ::platform::firewall::dc::nat::ldap
}

class platform::firewall::admin::runtime {
  include ::platform::firewall::calico::admin
  include ::platform::firewall::dc::nat::ldap
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

class platform::firewall::extra (
  $config = {}
) {
  if $config != {} {
    $config.each |$key, $value| {
      # if $key == <key placeholder> {
      #   <process extra>
      # }
    }
  }
}

class platform::firewall::dc::nat::ldap::params (
  $transport = 'tcp',
  $table = 'nat',
  # openLDAP ports 636, 389
  $dports = [636, 389],
  $chain = 'POSTROUTING',
  $jump = 'SNAT',
) {}

class platform::firewall::dc::nat::ldap::rule (
  $enabled = true,
  $outiface = undef,
  $tosource = undef,
) inherits ::platform::firewall::dc::nat::ldap::params {

  include ::platform::params
  include ::platform::ldap::params
  include ::platform::network::mgmt::params

  if $enabled {
    $ensure = 'present'
  } else {
    $ensure = 'absent'
  }

  $destination = $::platform::ldap::params::ldapserver_host
  $mgmt_subnet = $::platform::network::mgmt::params::subnet_network
  $mgmt_prefixlen = $::platform::network::mgmt::params::subnet_prefixlen
  $s_mgmt_subnet = "${mgmt_subnet}/${mgmt_prefixlen}"

  # SNAT rule is used to get worker / storage LDAP traffic to
  # the system controller.
  platform::firewall::rule { 'ldap-nat':
    ensure       => $ensure,
    service_name => 'subcloud',
    table        => $table,
    chain        => $chain,
    proto        => $transport,
    jump         => $jump,
    ports        => $dports,
    host         => $s_mgmt_subnet,
    destination  => $destination,
    outiface     => $outiface,
    tosource     => $tosource,
  }
}

class platform::firewall::dc::nat::ldap (
  $enabled = true,
) {
  include ::platform::params
  $system_mode  = $::platform::params::system_mode
  $dc_role      = $::platform::params::distributed_cloud_role

  if ($system_mode != 'simplex' and $dc_role == 'subcloud') {
    include ::platform::network::admin::params
    include ::platform::network::mgmt::params

    $controller_0_hostname = $::platform::params::controller_0_hostname
    $controller_1_hostname = $::platform::params::controller_1_hostname
    $admin_interface = $::platform::network::admin::params::interface_name
    $mgmt_interface = $::platform::network::mgmt::params::interface_name

    $hostname = $::platform::params::hostname
    case $::hostname {
      $controller_0_hostname: {
        $mgmt_unit_ip  = $::platform::network::mgmt::params::controller0_address
        $admin_unit_ip = $::platform::network::admin::params::controller0_address
      }
      $controller_1_hostname: {
        $mgmt_unit_ip  = $::platform::network::mgmt::params::controller1_address
        $admin_unit_ip = $::platform::network::admin::params::controller1_address
      }
      default: {
        fail("Hostname must be either ${controller_0_hostname} or ${controller_1_hostname}")
      }
    }

    if ($admin_interface and $admin_unit_ip) {
      $outiface = $admin_interface
      $tosource = $admin_unit_ip
    } else {
      $outiface = $mgmt_interface
      $tosource = $mgmt_unit_ip
    }

    # Worker/Storage LDAP traffic from the subcloud management network
    # is SNAT to the system controller.
    class { '::platform::firewall::dc::nat::ldap::rule':
        enabled  => $enabled,
        outiface => $outiface,
        tosource => $tosource
    }
  }
}

class platform::firewall::dc::nat::ldap::runtime {
  include ::platform::firewall::dc::nat::ldap
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

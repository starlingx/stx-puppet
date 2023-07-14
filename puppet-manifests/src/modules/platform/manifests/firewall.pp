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
  contain ::platform::firewall::calico::oam
  contain ::platform::firewall::calico::mgmt
  contain ::platform::firewall::calico::cluster_host
  contain ::platform::firewall::calico::pxeboot
  contain ::platform::firewall::calico::storage
  contain ::platform::firewall::calico::admin
  contain ::platform::firewall::calico::hostendpoint

  Class['::platform::kubernetes::gate'] -> Class[$name]

  Class['::platform::firewall::calico::oam']
  -> Class['::platform::firewall::calico::mgmt']
  -> Class['::platform::firewall::calico::cluster_host']
  -> Class['::platform::firewall::calico::pxeboot']
  -> Class['::platform::firewall::calico::storage']
  -> Class['::platform::firewall::calico::admin']
  -> Class['::platform::firewall::calico::hostendpoint']
}

class platform::firewall::calico::worker {
  contain ::platform::firewall::calico::mgmt
  contain ::platform::firewall::calico::cluster_host
  contain ::platform::firewall::calico::pxeboot
  contain ::platform::firewall::calico::storage
  contain ::platform::firewall::calico::hostendpoint

  Class['::platform::kubernetes::worker'] -> Class[$name]

  Class['::platform::firewall::calico::mgmt']
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

  Class['::platform::firewall::calico::oam']
  -> Class['::platform::firewall::calico::mgmt']
  -> Class['::platform::firewall::calico::cluster_host']
  -> Class['::platform::firewall::calico::pxeboot']
  -> Class['::platform::firewall::calico::storage']
  -> Class['::platform::firewall::calico::admin']
  -> Class['::platform::firewall::calico::hostendpoint']
}

class platform::firewall::mgmt::runtime {
  include ::platform::firewall::calico::mgmt
}

class platform::firewall::admin::runtime {
  include ::platform::firewall::calico::admin
}

class platform::firewall::calico::oam (
  $config = {}
) {
  if $config != {} {
    $apply_script = 'calico_firewall_apply_policy.sh'
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
      command   => "${apply_script} ${gnp_name} ${file_name_gnp}",
      logoutput => true
    }
  }
}

class platform::firewall::calico::mgmt (
  $config = {}
) {
  if $config != {} {
    if $::personality == 'worker' {
      $apply_script = 'calico_firewall_remote_apply_policy.sh'
    } elsif $::personality == 'controller' {
      $apply_script = 'calico_firewall_apply_policy.sh'
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
      command   => "${apply_script} ${gnp_name} ${file_name_gnp}",
      logoutput => true
    }
  }
}

class platform::firewall::calico::cluster_host  (
  $config = {}
) {
  if $config != {} {
    if $::personality == 'worker' {
      $apply_script = 'calico_firewall_remote_apply_policy.sh'
    } elsif $::personality == 'controller' {
      $apply_script = 'calico_firewall_apply_policy.sh'
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
      command   => "${apply_script} ${gnp_name} ${file_name_gnp}",
      logoutput => true
    }
  }
}

class platform::firewall::calico::pxeboot  (
  $config = {}
) {
  if $config != {} {
    if $::personality == 'worker' {
      $apply_script = 'calico_firewall_remote_apply_policy.sh'
    } elsif $::personality == 'controller' {
      $apply_script = 'calico_firewall_apply_policy.sh'
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
      command   => "${apply_script} ${gnp_name} ${file_name_gnp}",
      logoutput => true
    }
  }
}

class platform::firewall::calico::storage  (
  $config = {}
) {
  if $config != {} {
    if $::personality == 'worker' {
      $apply_script = 'calico_firewall_remote_apply_policy.sh'
    } elsif $::personality == 'controller' {
      $apply_script = 'calico_firewall_apply_policy.sh'
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
      command   => "${apply_script} ${gnp_name} ${file_name_gnp}",
      logoutput => true
    }
  }
}

class platform::firewall::calico::admin  (
  $config = {}
) {
  if $config != {} {
    if $::personality == 'worker' {
      $apply_script = 'calico_firewall_remote_apply_policy.sh'
    } elsif $::personality == 'controller' {
      $apply_script = 'calico_firewall_apply_policy.sh'
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
      command   => "${apply_script} ${gnp_name} ${file_name_gnp}",
      logoutput => true
    }
  }
}

class platform::firewall::calico::hostendpoint (
  $config = {}
) {
  $active_heps = keys($config)
  if $config != {} {
    if $::personality == 'worker' {
      $apply_script = 'calico_firewall_remote_apply_hostendp.sh'
    } elsif $::personality == 'controller' {
      $apply_script = 'calico_firewall_apply_hostendp.sh'
    }
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
        command   => "${apply_script} ${key} ${file_name_hep}",
        logoutput => true
      }
    }
  }
  # storage nodes do not run k8s
  if $::personality != 'storage' {

    if $::personality == 'worker' {
      $remove_script = 'remove_remote_unused_calico_hostendpoints.sh'
    } elsif $::personality == 'controller' {
      $remove_script = 'remove_unused_calico_hostendpoints.sh'
    }
    $file_hep_active = '/tmp/hep_active.txt'
    exec { "get active hostendepoints: ${active_heps}":
      command => "echo ${active_heps} > ${file_hep_active}",
    }
    -> exec { "remove unused hostendepoints ${::hostname} ${file_hep_active}":
      path    => '/usr/bin:/usr/sbin:/bin:/usr/local/bin',
      command => "${remove_script} ${::hostname} ${file_hep_active}",
      onlyif  => "test -f ${file_hep_active}"
    }
  }
}
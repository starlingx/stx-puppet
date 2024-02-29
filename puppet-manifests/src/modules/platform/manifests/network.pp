
class platform::network::pxeboot::ipv4::params(
  # shared parameters with base class - required for auto hiera parameter lookup
  $interface_address = undef,
  $subnet_version = undef,
  $subnet_network = undef,
  $subnet_network_url = undef,
  $subnet_prefixlen = undef,
  $subnet_netmask = undef,
  $subnet_start = undef,
  $subnet_end = undef,
  $gateway_address = undef,
  $controller_address = undef,  # controller floating
  $controller_address_url = undef,  # controller floating url address
  $controller0_address = undef, # controller unit0
  $controller1_address = undef, # controller unit1
) { }

class platform::network::pxeboot::ipv6::params(
  # shared parameters with base class - required for auto hiera parameter lookup
  $interface_address = undef,
  $subnet_version = undef,
  $subnet_network = undef,
  $subnet_network_url = undef,
  $subnet_prefixlen = undef,
  $subnet_netmask = undef,
  $subnet_start = undef,
  $subnet_end = undef,
  $gateway_address = undef,
  $controller_address = undef,  # controller floating
  $controller_address_url = undef,  # controller floating url address
  $controller0_address = undef, # controller unit0
  $controller1_address = undef, # controller unit1
) { }

class platform::network::pxeboot::params(
  # this class contains the primary pool (ipv4 or ipv6) addresses for compatibility
  # shared parameters with base class - required for auto hiera parameter lookup
  $interface_name = undef,
  $interface_address = undef,
  $interface_devices = [],
  $subnet_version = undef,
  $subnet_network = undef,
  $subnet_network_url = undef,
  $subnet_prefixlen = undef,
  $subnet_netmask = undef,
  $subnet_start = undef,
  $subnet_end = undef,
  $gateway_address = undef,
  $controller_address = undef,  # controller floating
  $controller_address_url = undef,  # controller floating url address
  $controller0_address = undef, # controller unit0
  $controller1_address = undef, # controller unit1
  $mtu = 1500,
) { }

class platform::network::mgmt::ipv4::params(
  # shared parameters with base class - required for auto hiera parameter lookup
  $interface_address = undef,
  $subnet_version = undef,
  $subnet_network = undef,
  $subnet_network_url = undef,
  $subnet_prefixlen = undef,
  $subnet_netmask = undef,
  $subnet_start = undef,
  $subnet_end = undef,
  $gateway_address = undef,
  $controller_address = undef,  # controller floating
  $controller_address_url = undef,  # controller floating url address
  $controller0_address = undef, # controller unit0
  $controller1_address = undef, # controller unit1
) { }

class platform::network::mgmt::ipv6::params(
  # shared parameters with base class - required for auto hiera parameter lookup
  $interface_address = undef,
  $subnet_version = undef,
  $subnet_network = undef,
  $subnet_network_url = undef,
  $subnet_prefixlen = undef,
  $subnet_netmask = undef,
  $subnet_start = undef,
  $subnet_end = undef,
  $gateway_address = undef,
  $controller_address = undef,  # controller floating
  $controller_address_url = undef,  # controller floating url address
  $controller0_address = undef, # controller unit0
  $controller1_address = undef, # controller unit1
) { }

class platform::network::mgmt::params(
  # this class contains the primary pool (ipv4 or ipv6) addresses for compatibility
  # shared parameters with base class - required for auto hiera parameter lookup
  $interface_name = undef,
  $interface_address = undef,
  $interface_devices = [],
  $subnet_version = undef,
  $subnet_network = undef,
  $subnet_network_url = undef,
  $subnet_prefixlen = undef,
  $subnet_netmask = undef,
  $subnet_start = undef,
  $subnet_end = undef,
  $gateway_address = undef,
  $controller_address = undef,  # controller floating
  $controller_address_url = undef,  # controller floating url address
  $controller0_address = undef, # controller unit0
  $controller1_address = undef, # controller unit1
  $mtu = 1500,
  # network type specific parameters
  # TODO: remove platform_nfs_address when StarlingX rel 6 and 7 are not being used anymore
  $platform_nfs_address = undef,
  $fqdn_ready = undef,
) { }

class platform::network::oam::ipv4::params(
  # shared parameters with base class - required for auto hiera parameter lookup
  $interface_address = undef,
  $subnet_version = undef,
  $subnet_network = undef,
  $subnet_network_url = undef,
  $subnet_prefixlen = undef,
  $subnet_netmask = undef,
  $subnet_start = undef,
  $subnet_end = undef,
  $gateway_address = undef,
  $controller_address = undef,  # controller floating
  $controller_address_url = undef,  # controller floating url address
  $controller0_address = undef, # controller unit0
  $controller1_address = undef, # controller unit1
) { }

class platform::network::oam::ipv6::params(
  # shared parameters with base class - required for auto hiera parameter lookup
  $interface_address = undef,
  $subnet_version = undef,
  $subnet_network = undef,
  $subnet_network_url = undef,
  $subnet_prefixlen = undef,
  $subnet_netmask = undef,
  $subnet_start = undef,
  $subnet_end = undef,
  $gateway_address = undef,
  $controller_address = undef,  # controller floating
  $controller_address_url = undef,  # controller floating url address
  $controller0_address = undef, # controller unit0
  $controller1_address = undef, # controller unit1
) { }

class platform::network::oam::params(
  # this class contains the primary pool (ipv4 or ipv6) addresses for compatibility
  # shared parameters with base class - required for auto hiera parameter lookup
  $interface_name = undef,
  $interface_address = undef,
  $interface_devices = [],
  $subnet_version = undef,
  $subnet_network = undef,
  $subnet_network_url = undef,
  $subnet_prefixlen = undef,
  $subnet_netmask = undef,
  $subnet_start = undef,
  $subnet_end = undef,
  $gateway_address = undef,
  $controller_address = undef,  # controller floating
  $controller_address_url = undef,  # controller floating url address
  $controller0_address = undef, # controller unit0
  $controller1_address = undef, # controller unit1
  $mtu = 1500,
) { }

class platform::network::cluster_host::ipv4::params(
  # shared parameters with base class - required for auto hiera parameter lookup
  $interface_address = undef,
  $subnet_version = undef,
  $subnet_network = undef,
  $subnet_network_url = undef,
  $subnet_prefixlen = undef,
  $subnet_netmask = undef,
  $subnet_start = undef,
  $subnet_end = undef,
  $gateway_address = undef,
  $controller_address = undef,  # controller floating
  $controller_address_url = undef,  # controller floating url address
  $controller0_address = undef, # controller unit0
  $controller1_address = undef, # controller unit1
) { }

class platform::network::cluster_host::ipv6::params(
  # shared parameters with base class - required for auto hiera parameter lookup
  $interface_address = undef,
  $subnet_version = undef,
  $subnet_network = undef,
  $subnet_network_url = undef,
  $subnet_prefixlen = undef,
  $subnet_netmask = undef,
  $subnet_start = undef,
  $subnet_end = undef,
  $gateway_address = undef,
  $controller_address = undef,  # controller floating
  $controller_address_url = undef,  # controller floating url address
  $controller0_address = undef, # controller unit0
  $controller1_address = undef, # controller unit1
) { }

class platform::network::cluster_host::params(
  # this class contains the primary pool (ipv4 or ipv6) addresses for compatibility
  # shared parameters with base class - required for auto hiera parameter lookup
  $interface_name = undef,
  $interface_address = undef,
  $interface_devices = [],
  $subnet_version = undef,
  $subnet_network = undef,
  $subnet_network_url = undef,
  $subnet_prefixlen = undef,
  $subnet_netmask = undef,
  $subnet_start = undef,
  $subnet_end = undef,
  $gateway_address = undef,
  $controller_address = undef,  # controller floating
  $controller_address_url = undef,  # controller floating url address
  $controller0_address = undef, # controller unit0
  $controller1_address = undef, # controller unit1
  $mtu = 1500,
) { }

class platform::network::ironic::ipv4::params(
  # shared parameters with base class - required for auto hiera parameter lookup
  $interface_address = undef,
  $subnet_version = undef,
  $subnet_network = undef,
  $subnet_network_url = undef,
  $subnet_prefixlen = undef,
  $subnet_netmask = undef,
  $subnet_start = undef,
  $subnet_end = undef,
  $gateway_address = undef,
  $controller_address = undef,  # controller floating
  $controller_address_url = undef,  # controller floating url address
  $controller0_address = undef, # controller unit0
  $controller1_address = undef, # controller unit1
) { }

class platform::network::ironic::ipv6::params(
  # shared parameters with base class - required for auto hiera parameter lookup
  $interface_address = undef,
  $subnet_version = undef,
  $subnet_network = undef,
  $subnet_network_url = undef,
  $subnet_prefixlen = undef,
  $subnet_netmask = undef,
  $subnet_start = undef,
  $subnet_end = undef,
  $gateway_address = undef,
  $controller_address = undef,  # controller floating
  $controller_address_url = undef,  # controller floating url address
  $controller0_address = undef, # controller unit0
  $controller1_address = undef, # controller unit1
) { }

class platform::network::ironic::params(
  # this class contains the primary pool (ipv4 or ipv6) addresses for compatibility
  # shared parameters with base class - required for auto hiera parameter lookup
  $interface_name = undef,
  $interface_address = undef,
  $interface_devices = [],
  $subnet_version = undef,
  $subnet_network = undef,
  $subnet_network_url = undef,
  $subnet_prefixlen = undef,
  $subnet_netmask = undef,
  $subnet_start = undef,
  $subnet_end = undef,
  $gateway_address = undef,
  $controller_address = undef,  # controller floating
  $controller_address_url = undef,  # controller floating url address
  $controller0_address = undef, # controller unit0
  $controller1_address = undef, # controller unit1
  $mtu = 1500,
) { }

class platform::network::admin::ipv4::params(
  # shared parameters with base class - required for auto hiera parameter lookup
  $interface_address = undef,
  $subnet_version = undef,
  $subnet_network = undef,
  $subnet_network_url = undef,
  $subnet_prefixlen = undef,
  $subnet_netmask = undef,
  $subnet_start = undef,
  $subnet_end = undef,
  $gateway_address = undef,
  $controller_address = undef,  # controller floating
  $controller_address_url = undef,  # controller floating url address
  $controller0_address = undef, # controller unit0
  $controller1_address = undef, # controller unit1
) { }

class platform::network::admin::ipv6::params(
  # shared parameters with base class - required for auto hiera parameter lookup
  $interface_address = undef,
  $subnet_version = undef,
  $subnet_network = undef,
  $subnet_network_url = undef,
  $subnet_prefixlen = undef,
  $subnet_netmask = undef,
  $subnet_start = undef,
  $subnet_end = undef,
  $gateway_address = undef,
  $controller_address = undef,  # controller floating
  $controller_address_url = undef,  # controller floating url address
  $controller0_address = undef, # controller unit0
  $controller1_address = undef, # controller unit1
) { }

class platform::network::admin::params(
  # this class contains the primary pool (ipv4 or ipv6) addresses for compatibility
  # shared parameters with base class - required for auto hiera parameter lookup
  $interface_name = undef,
  $interface_address = undef,
  $interface_devices = [],
  $subnet_version = undef,
  $subnet_network = undef,
  $subnet_network_url = undef,
  $subnet_prefixlen = undef,
  $subnet_netmask = undef,
  $subnet_start = undef,
  $subnet_end = undef,
  $gateway_address = undef,
  $controller_address = undef,  # controller floating
  $controller_address_url = undef,  # controller floating url address
  $controller0_address = undef, # controller unit0
  $controller1_address = undef, # controller unit1
  $mtu = 1500,
  # network type specific parameters
) { }

define platform::network::network_address (
  $address,
  $ifname,
) {
  # In AIO simplex configurations, the management addresses are assigned to the
  # loopback interface. These addresses must be assigned using the host scope
  # or assignment is prevented (can't have multiple global scope addresses on
  # the loopback interface).

  # For ipv6 the only way to initiate outgoing connections
  # over the fixed ips is to set preferred_lft to 0 for the
  # floating ips so that they are not used
  if $ifname == 'lo' {
    $options = 'scope host'
  } elsif $::platform::network::mgmt::params::subnet_version == $::platform::params::ipv6 {
    $options = 'preferred_lft 0'
  } else {
    $options = ''
  }

  # addresses should only be configured if running in simplex, otherwise SM
  # will configure them on the active controller.
  exec { "Configuring ${name} IP address to ${address}":
    command => "ip addr replace ${address} dev ${ifname} ${options}",
    onlyif  => ['test -f /etc/platform/simplex', 'test ! -f /var/run/.network_upgrade_bootstrap'],
  }
}


class platform::network::addresses (
  $address_config = {},
) {
  create_resources('platform::network::network_address', $address_config, {})
}


# TODO(fcorream): update_platform_nfs_ip_references is just necessary to allow
# an upgrade from StarlingX releases 6 or 7 to new releases.
# remove this class when StarlingX rel. 6 or 7 are not being used anymore
class platform::network::update_platform_nfs_ip_references (
) {
  include ::platform::network::mgmt::params
  include ::platform::upgrade::params

  $upgrade_to_release = $::platform::upgrade::params::to_release
  $plat_nfs_ip = $::platform::network::mgmt::params::platform_nfs_address
  $plat_nfs_prefixlen = $::platform::network::mgmt::params::subnet_prefixlen
  $plat_nfs_iface = $::platform::network::mgmt::params::interface_name

  # if plat_nfs_ip is empty, it means upgrade-activate was called again and there is nothing to do
  if $plat_nfs_ip and $plat_nfs_ip != '' {
    # platform-nfs-ip SM deprovision ( run in active and standby controller )
    exec {'Deprovision platform-nfs-ip (service-group-member platform-nfs-ip)':
      command => 'sm-deprovision service-group-member controller-services platform-nfs-ip --apply'
    }
    -> exec { 'Deprovision Platform-NFS IP service in SM (service platform-nfs-ip)':
      command => 'sm-deprovision service platform-nfs-ip',
    }
    -> exec { "Removing Plaform NFS IP address from interface: ${plat_nfs_iface}":
      command => "ip addr del ${plat_nfs_ip}/${plat_nfs_prefixlen} dev ${plat_nfs_iface}",
      onlyif  => "ip -br addr show dev ${plat_nfs_iface} 2>/dev/null | grep '${plat_nfs_ip}/${plat_nfs_prefixlen}' 1>/dev/null",
    }
    -> exec { "Removing Plaform NFS IP address from /${upgrade_to_release}/dnsmasq.hosts":
      command => "sed -i '/controller-platform-nfs/d' /opt/platform/config/${upgrade_to_release}/dnsmasq.hosts",
      onlyif  => "test -f /opt/platform/config/${upgrade_to_release}/dnsmasq.hosts",
    }
    -> exec { "Removing Plaform NFS IP address from /${upgrade_to_release}/hieradata/system.yaml":
      command => "sed -i '/platform_nfs_address/d' /opt/platform/puppet/${upgrade_to_release}/hieradata/system.yaml",
      onlyif  => "test -f /opt/platform/puppet/${upgrade_to_release}/hieradata/system.yaml",
    }
  } else {
    notice('update platform nfs ip not detected, deprovisioning skipped')
  }
}

# Defines a single route resource for an interface.
# If multiple are required in the future, then this will need to
# iterate over a hash to create multiple entries per file.
define platform::network::network_route6 (
  $prefix,
  $gateway,
  $ifname,
) {
  case $::osfamily {
    'RedHat': {
      file { "/etc/sysconfig/network-scripts/route6-${ifname}":
        ensure  => present,
        owner   => root,
        group   => root,
        mode    => '0644',
        content => "${prefix} via ${gateway} dev ${ifname}"
      }
    }
    'Debian': {
      file { '/var/run/network-scripts.puppet/routes6':
        ensure => present,
        owner  => root,
        group  => root,
        mode   => '0644'
      }
      if $prefix == 'default' {
        file_line { 'set_ipv6_default_route':
          ensure             => present,
          path               => '/var/run/network-scripts.puppet/routes6',
          line               => "default 0 ${gateway} ${ifname} metric 1024",
          match              => 'default 0 .*',
          append_on_no_match => true
        }
      }
    }
    default : {
      fail("unsupported osfamily ${::osfamily}, Debian and Redhat are the only supported ones")
    }
  } # Case $::osfamily
}

class platform::network::routes (
  $route_config = {}
) {
  # Reset file /var/run/network-scripts.puppet/routes so that deleted routes don't persist
  exec { 'Erasing routes from file /var/run/network-scripts.puppet/routes':
    command => "/bin/sed -i '/# HEADER/!d' /var/run/network-scripts.puppet/routes",
    onlyif  => 'test -f /var/run/network-scripts.puppet/routes',
  }

  create_resources('network_route', $route_config, {})

  include ::platform::params
  include ::platform::network::mgmt::params

  # Add static IPv6 default route since DHCPv6 does not support the router option
  if $::personality != 'controller' {
    if $::platform::network::mgmt::params::subnet_version == $::platform::params::ipv6 {
      platform::network::network_route6 { 'ipv6 default route':
        prefix  => 'default',
        gateway => $::platform::network::mgmt::params::controller_address,
        ifname  => $::platform::network::mgmt::params::interface_name
      }
    }
  }
}


define platform::network::interfaces::sriov_enable (
  $addr,
  $device_id,
  $num_vfs,
  $port_name,
  $up_requirement,
  $vf_config = undef
) {
  $vf_file = 'sriov_numvfs'
  if ($num_vfs != undef) and ($num_vfs > 0) {
    exec { "sriov-enable-device: ${title}":
      command   => template('platform/sriov.enable-device.erb'),
      provider  => shell,
      onlyif    => "[ $(cat /sys/bus/pci/devices/${addr}/${vf_file}) != ${num_vfs} ]",
      logoutput => true,
    }
  }
}


define platform::network::interfaces::sriov_bind (
  $addr,
  $driver,
  $vfnumber = undef,
  $max_tx_rate = undef
) {
  if ($driver != undef) {
    if ($driver == 'vfio-pci') {
      exec { "Load vfio-pci driver with sriov enabled: ${title}":
        command   => 'modprobe vfio-pci enable_sriov=1 disable_idle_d3=1',
        logoutput => true,
      }
      -> exec { "Ensure enable_sriov is set: ${title}":
        command   => 'echo 1 > /sys/module/vfio_pci/parameters/enable_sriov',
        logoutput => true,
      }
      -> exec { "Ensure disable_idle_d3 is set: ${title}":
        command   => 'echo 1 > /sys/module/vfio_pci/parameters/disable_idle_d3',
        logoutput => true,
      }
      -> exec { "sriov-vf-bind-device: ${title}":
        command   => template('platform/sriov.bind-device.erb'),
        logoutput => true,
      }
      -> Platform::Network::Interfaces::Sriov_ratelimit <| addr == $addr |>
    } else {
      ensure_resource(kmod::load, $driver)
      exec { "sriov-vf-bind-device: ${title}":
        command   => template('platform/sriov.bind-device.erb'),
        logoutput => true,
        require   => [ Kmod::Load[$driver] ],
      }
      -> Platform::Network::Interfaces::Sriov_ratelimit <| addr == $addr |>
    }
  }
}

define platform::network::interfaces::sriov_vf_bind (
  $addr,
  $device_id,
  $num_vfs,
  $port_name,
  $up_requirement,
  $vf_config
) {
  create_resources('platform::network::interfaces::sriov_bind', $vf_config, {})
}


define platform::network::interfaces::sriov_ratelimit (
  $addr,
  $driver,
  $port_name,
  $vfnumber = undef,
  $max_tx_rate = undef
) {
  if $max_tx_rate {
    exec { "sriov-vf-rate-limit: ${title}":
      command   => template('platform/sriov.ratelimit.erb'),
      logoutput => true,
      tries     => 5,
      try_sleep => 1,
    }
  }
}

define platform::network::interfaces::sriov_vf_ratelimit (
  $addr,
  $device_id,
  $num_vfs,
  $port_name,
  $up_requirement,
  $vf_config
) {
  create_resources('platform::network::interfaces::sriov_ratelimit', $vf_config, {
    port_name => $port_name
  })
}

class platform::network::interfaces::sriov (
  $sriov_config = {}
) {
}

class platform::network::interfaces::sriov::enable
  inherits platform::network::interfaces::sriov {
  create_resources('platform::network::interfaces::sriov_enable', $sriov_config, {})
}

class platform::network::interfaces::sriov::config
  inherits platform::network::interfaces::sriov {
  Anchor['platform::networking'] -> Class[$name]
  create_resources('platform::network::interfaces::sriov_vf_bind', $sriov_config, {})
  create_resources('platform::network::interfaces::sriov_vf_ratelimit', $sriov_config, {})
}

class platform::network::interfaces::sriov::runtime {
  include ::platform::network::interfaces::sriov::enable
}

class platform::network::interfaces::sriov::vf::runtime {
  include ::platform::network::interfaces::sriov::config
}

define platform::network::interfaces::fpga::n3000 (
  $device_id,
  $used_by
) {
  if ($device_id != undef) and ($device_id == '0d58') {
    include ::platform::devices::fpga::n3000::reset
    exec { "ifdown/up: ${title}":
      command   => template('platform/interface.ifup.erb'),
      logoutput => true,
    }
    -> Platform::Network::Interfaces::Sriov_bind <| |>
  }
}

class platform::network::interfaces::fpga (
  $fpga_config = {}
) {
}

class platform::network::interfaces::fpga::config
  inherits platform::network::interfaces::fpga {
  Anchor['platform::networking'] -> Class[$name]
  create_resources('platform::network::interfaces::fpga::n3000', $fpga_config, {})
}


class platform::network::interfaces (
  $network_config = {},
) {
  create_resources('network_config', $network_config, {})
}


class platform::network::apply {
  include ::platform::network::interfaces
  include ::platform::network::addresses
  include ::platform::network::routes

  Network_config <| |>
  -> Exec['apply-network-config']
  -> Platform::Network::Network_address <| |>
  -> Exec['wait-for-tentative']
  -> Anchor['platform::networking']

  # Adding Network_route dependency separately, in case it's empty,
  # as puppet bug will remove dependency altogether if
  # Network_route is empty. See below.
  # https://projects.puppetlabs.com/issues/18399
  Network_config <| |>
  -> Network_route <| |>
  -> Exec['apply-network-config']

  Network_config <| |>
  -> Platform::Network::Network_route6 <| |>
  -> Exec['apply-network-config']

  exec {'apply-network-config':
    command => 'apply_network_config.sh',
  }

  # Wait for network interface to leave tentative state during ipv6 DAD, if interface is UP
  exec { 'wait-for-tentative':
    path      => '/usr/bin:/usr/sbin:/bin:/usr/local/bin',
    command   => 'check_ipv6_tentative_addresses.py',
    logoutput => true,
    tries     => 10,
    try_sleep => 1,
    onlyif    => 'test ! -f /var/run/.network_upgrade_bootstrap',
  }
}


class platform::network {
  include ::platform::params
  include ::platform::network::mgmt::params
  include ::platform::network::cluster_host::params

  include ::platform::network::apply

  $management_interface = $::platform::network::mgmt::params::interface_name

  $testcmd = '/usr/local/bin/connectivity_test'

  if $::personality != 'controller' {
    if $management_interface {
      exec { 'connectivity-test-management':
        command => "${testcmd} -t 70 -i ${management_interface} controller-platform-nfs; /bin/true",
        require => Anchor['platform::networking'],
        onlyif  => 'test ! -f /etc/platform/simplex',
      }
    }
  }
}


class platform::network::runtime {
  class {'::platform::network::apply':
    stage => pre
  }
}


class platform::network::routes::runtime {
  include ::platform::network::routes
  include ::platform::params
  $dc_role = $::platform::params::distributed_cloud_role

  # Adding Network_route dependency separately, in case it's empty,
  # as puppet bug will remove dependency altogether if
  # Network_route is empty. See below.
  # https://projects.puppetlabs.com/issues/18399

  # in DC setups the firewall needs to be updated also in the controllers
  if ($dc_role == 'systemcontroller' and $::personality == 'controller') {

    # systemcontroller for the management network
    include ::platform::firewall::mgmt::runtime

    Network_route <| |> -> Exec['apply-network-config route setup']
    Platform::Network::Network_route6 <| |> -> Exec['apply-network-config route setup']
    -> Class['::platform::firewall::mgmt::runtime']

  } elsif ($dc_role == 'subcloud' and $::personality == 'controller') {

    # subcloud for the management and admin networks
    include ::platform::firewall::mgmt::runtime
    include ::platform::firewall::admin::runtime

    Network_route <| |> -> Exec['apply-network-config route setup']
    Platform::Network::Network_route6 <| |> -> Exec['apply-network-config route setup']
    -> Class['::platform::firewall::mgmt::runtime']
    -> Class['::platform::firewall::admin::runtime']

  } else {

    Network_route <| |> -> Exec['apply-network-config route setup']
    Platform::Network::Network_route6 <| |> -> Exec['apply-network-config route setup']

  }

  exec {'apply-network-config route setup':
    command => 'apply_network_config.sh --routes',
  }
}

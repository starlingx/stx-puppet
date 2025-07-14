
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

class platform::network::cluster_pod::ipv4::params(
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

class platform::network::cluster_pod::ipv6::params(
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

class platform::network::cluster_pod::params(
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

class platform::network::cluster_service::ipv4::params(
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

class platform::network::cluster_service::ipv6::params(
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

class platform::network::cluster_service::params(
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
  $addresses,
  $ifname,
) {
  # In AIO simplex configurations, the management addresses are assigned to the
  # loopback interface. These addresses must be assigned using the host scope
  # or assignment is prevented (can't have multiple global scope addresses on
  # the loopback interface).

  $addresses.each |$address| {
    # For ipv6 the only way to initiate outgoing connections
    # over the fixed ips is to set preferred_lft to 0 for the
    # floating ips so that they are not used
    if $ifname == 'lo' {
      $options = 'scope host'
      $protocol = ''
    } elsif $address =~ Stdlib::IP::Address::V6 {
      $options = 'preferred_lft 0'
      $protocol = 'ipv6'
    } else {
      $options = ''
      $protocol = 'ipv4'
    }

    # Remove the subnet prefix if present ( e.g: 1.1.1.1/24 fd001::1/64)
    $ip_address = $address ? {
      /.+\// => $address.split('/')[0], # If there's a '/', take the part before it
      default => $address,              # Otherwise, keep it as is
    }

    # save subnet prefix if present ( e.g: 1.1.1.1/24 fd001::1/64)
    $ip_prefix = $address ? {
      /.+\// => $address.split('/')[1], # If there's a '/', take the part after it
      default => '',
    }

    # addresses should only be configured if running in simplex, otherwise SM
    # will configure them on the active controller.
    # Force a gratuitous ARP for IPv4 floating IPs, for fresh installs the
    # controller-0 works like simplex even for aio-dx/standard modes.
    exec { "Configuring ${name} IP address to ${address}":
      command   => "ip addr replace ${address} dev ${ifname} ${options}",
      logoutput => true,
      onlyif    => ['test -f /etc/platform/simplex',
                    'test ! -f /var/run/.network_upgrade_bootstrap'],
    }
    -> exec { "Send Gratuitous ARP for IPv4: ${ip_address}/${ip_prefix} on interface: ${name},${ifname}":
      command   => "arping -c 3 -U -I ${ifname} ${ip_address}",
      logoutput => 'on_failure',
      onlyif    => ["test ${ifname} != 'lo'",
                    "echo ${ip_address} | grep -qE '^([0-9]{1,3}\\.){3}[0-9]{1,3}$'",
                    'test -f /etc/platform/simplex',
                    'test ! -f /var/run/.network_upgrade_bootstrap'],
    }
    -> exec { "Send Unsolicited Advertisement for IPv6: ${ip_address}/${ip_prefix} on interface: ${name},${ifname}":
      command   => "/usr/lib/heartbeat/send_ua ${ip_address} ${ip_prefix} ${ifname}",
      logoutput => 'on_failure',
      onlyif    => ["test ${ifname} != 'lo'",
                    "test ${ip_prefix} != ''",
                    "test ${protocol} == 'ipv6'",
                    'test -x /usr/lib/heartbeat/send_ua',
                    'test -f /etc/platform/simplex',
                    'test ! -f /var/run/.network_upgrade_bootstrap'],
    }
  }
}


class platform::network::addresses (
  $address_config = {},
) {
  create_resources('platform::network::network_address', $address_config, {})
}


class platform::network::upgrade_fqdn_cleanup {
    # Remove this flag after the upgrade complete/abort
    # during the upgrade the controller-0 runs version X
    # and controller-1 runs version X+1
    # to use the FQDN the active controller must run dnsmasq
    # with the FQDN entries. It doesn't happen during an upgrade
    file {'/etc/platform/.upgrade_do_not_use_fqdn':
      ensure => absent,
    }
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

define platform::network::interfaces::rate_limit::tx_rate (
  Integer $max_tx_rate,
  String $address_pool,
  String $interface_name,
  Optional[Array[String]] $accept_subnet = undef,
  Enum['present', 'absent'] $ensure_rule = 'present',
) {

  $hashlimit_name = "${interface_name}-limit"

  # Convert max_tx_rate to Kilobytes/second
  # 1 Megabit (Mb) = 125 Kilobytes (KB)
  $max_tx_rate_kbps = $max_tx_rate * 125

  notify { "Configuring tx rate limit for ${interface_name}":
    message  => "Applying tx rate limit settings on ${interface_name}",
    loglevel => 'debug',
  }

  # Add IPv4 rules if needed
  if $address_pool == 'ipv4' or $address_pool == 'dual' {

    if $accept_subnet and !empty($accept_subnet) {
      platform::network::interfaces::accept::subnet { "${interface_name}-ipv4-egress":
        interface_name => $interface_name,
        address_pool   => 'ipv4',
        accept_subnet  => $accept_subnet,
        ensure_rule    => $ensure_rule,
        provider       => 'iptables',
        direction      => 'egress',
      }
    }

    firewall { "301 rate-limit egress IPv4 ${interface_name}":
      ensure          => $ensure_rule,
      chain           => 'OUTPUT',
      proto           => 'all',
      outiface        => $interface_name,
      action          => 'drop',
      hashlimit_name  => "${hashlimit_name}-egress",
      hashlimit_above => "${max_tx_rate_kbps}kb/s",
      hashlimit_mode  => 'srcip',
      provider        => 'iptables',
    }
  }

  # Add IPv6 rules if needed
  if $address_pool == 'ipv6' or $address_pool == 'dual' {

    if $accept_subnet and !empty($accept_subnet) {
      platform::network::interfaces::accept::subnet { "${interface_name}-ipv6-egress":
        interface_name => $interface_name,
        address_pool   => 'ipv6',
        accept_subnet  => $accept_subnet,
        ensure_rule    => $ensure_rule,
        provider       => 'ip6tables',
        direction      => 'egress',
      }
    }

    firewall { "303 rate-limit egress IPv6 ${interface_name}":
      ensure          => $ensure_rule,
      chain           => 'OUTPUT',
      proto           => 'all',
      outiface        => $interface_name,
      action          => 'drop',
      hashlimit_name  => "${hashlimit_name}-egress",
      hashlimit_above => "${max_tx_rate_kbps}kb/s",
      hashlimit_mode  => 'srcip',
      provider        => 'ip6tables',
    }
  }
}

define platform::network::interfaces::rate_limit::rx_rate (
  Integer $max_rx_rate,
  String $address_pool,
  String $interface_name,
  Optional[Array[String]] $accept_subnet = undef,
  Enum['present', 'absent'] $ensure_rule = 'present',
) {
  $hashlimit_name = "${interface_name}-limit"

  # Convert max_rx_rate to Kilobytes/second
  # 1 Megabit (Mb) = 125 Kilobytes (KB)
  $max_rx_rate_kbps = $max_rx_rate * 125

  notify { "Configuring rx rate limit for ${interface_name}":
    message  => "Applying rx rate limit settings on ${interface_name}",
    loglevel => 'debug',
  }

  # Add IPv4 rules if needed
  if $address_pool == 'ipv4' or $address_pool == 'dual' {

    if $accept_subnet and !empty($accept_subnet) {
      platform::network::interfaces::accept::subnet { "${interface_name}-ipv4-ingress":
        interface_name => $interface_name,
        address_pool   => 'ipv4',
        accept_subnet  => $accept_subnet,
        ensure_rule    => $ensure_rule,
        provider       => 'iptables',
        direction      => 'ingress',
      }
    }

    firewall { "300 rate-limit ingress IPv4 ${interface_name}":
      ensure          => $ensure_rule,
      chain           => 'INPUT',
      proto           => 'all',
      iniface         => $interface_name,
      action          => 'drop',
      hashlimit_name  => "${hashlimit_name}-ingress",
      hashlimit_above => "${max_rx_rate_kbps}kb/s",
      hashlimit_mode  => 'dstip',
      provider        => 'iptables',
    }
  }

  # Add IPv6 rules if needed
  if $address_pool == 'ipv6' or $address_pool == 'dual' {

    if $accept_subnet and !empty($accept_subnet) {
      platform::network::interfaces::accept::subnet { "${interface_name}-ipv6-ingress":
        interface_name => $interface_name,
        address_pool   => 'ipv6',
        accept_subnet  => $accept_subnet,
        ensure_rule    => $ensure_rule,
        provider       => 'ip6tables',
        direction      => 'ingress',
      }
    }

    firewall { "302 rate-limit ingress IPv6 ${interface_name}":
      ensure          => $ensure_rule,
      chain           => 'INPUT',
      proto           => 'all',
      iniface         => $interface_name,
      action          => 'drop',
      hashlimit_name  => "${hashlimit_name}-ingress",
      hashlimit_above => "${max_rx_rate_kbps}kb/s",
      hashlimit_mode  => 'dstip',
      provider        => 'ip6tables',
    }
  }
}

define platform::network::interfaces::rate_limit::interface (
  Optional[Integer] $max_tx_rate = undef,
  Optional[Integer] $max_rx_rate = undef,
  Optional[Enum['ipv4', 'ipv6', 'dual']] $address_pool = undef,
  Optional[Array[String]] $accept_subnet = undef,
) {

  $interface_name = $title

  if ($max_rx_rate != undef or $max_tx_rate != undef) {
    include platform::network::interfaces::rate_limit::load_driver
    if $::personality == 'controller' {
        include platform::network::interfaces::rate_limit::bypass
    }
  } else {
    notice("No rate limiting configured for interface ${interface_name}")
  }

  if $max_tx_rate != undef and $max_tx_rate > 0 and $address_pool != undef {
    platform::network::interfaces::rate_limit::tx_rate { $interface_name:
      max_tx_rate    => $max_tx_rate,
      address_pool   => $address_pool,
      interface_name => $interface_name,
      accept_subnet  => $accept_subnet,
      ensure_rule    => 'present',
    }
  }
  elsif $max_tx_rate == 0 and $address_pool != undef {
    platform::network::interfaces::rate_limit::tx_rate { $interface_name:
      max_tx_rate    => 0,
      address_pool   => $address_pool,
      interface_name => $interface_name,
      accept_subnet  => $accept_subnet,
      ensure_rule    => 'absent',
    }
  }

  if $max_rx_rate != undef and $max_rx_rate > 0 and $address_pool != undef {
    platform::network::interfaces::rate_limit::rx_rate { $interface_name:
      max_rx_rate    => $max_rx_rate,
      address_pool   => $address_pool,
      interface_name => $interface_name,
      accept_subnet  => $accept_subnet,
      ensure_rule    => 'present',
    }
  }
  elsif $max_rx_rate == 0 and $address_pool != undef {
    platform::network::interfaces::rate_limit::rx_rate { $interface_name:
      max_rx_rate    => 0,
      address_pool   => $address_pool,
      interface_name => $interface_name,
      accept_subnet  => $accept_subnet,
      ensure_rule    => 'absent',
    }
  }
}

define platform::network::interfaces::accept::subnet (
  String $interface_name,
  String $address_pool,
  Enum['ingress', 'egress'] $direction,
  Enum['present', 'absent'] $ensure_rule = 'present',
  Enum['iptables', 'ip6tables'] $provider = undef,
  Optional[Array[String]] $accept_subnet = undef,
) {
  if $accept_subnet and !empty($accept_subnet) {
    $accept_subnet.each |String $network_type| {

      $subnet = lookup(
        "platform::network::${network_type}::${address_pool}::params::subnet_network",
        { 'default_value' => undef }
      )
      $prefix = lookup(
        "platform::network::${network_type}::${address_pool}::params::subnet_prefixlen",
        { 'default_value' => undef }
      )

      if $subnet and $prefix {
        $cidr = "${subnet}/${prefix}"

        if $direction == 'ingress' {
          firewall { "100 accept ${network_type} ${direction} ${address_pool} ${interface_name}":
            ensure   => $ensure_rule,
            chain    => 'INPUT',
            proto    => 'all',
            source   => $cidr,
            iniface  => $interface_name,
            action   => 'accept',
            provider => $provider,
          }
        } else {
          firewall { "101 accept ${network_type} ${direction} ${address_pool} ${interface_name}":
            ensure      => $ensure_rule,
            proto       => 'all',
            chain       => 'OUTPUT',
            destination => $cidr,
            outiface    => $interface_name,
            action      => 'accept',
            provider    => $provider,
          }
        }
      } else {
        notice("Subnet or prefix not found for ${network_type} ${address_pool} ${interface_name}")
      }
    }
  }
}

class platform::network::interfaces::rate_limit::load_driver {
  # Load xt_hashlimit driver
  kmod::load { 'xt_hashlimit':
    ensure => 'present',
  }
}


class platform::network::interfaces::rate_limit::bypass {
  firewall { '200 accept ingress State Synchronization and heartbeat traffic (IPv4)':
    chain    => 'INPUT',
    proto    => 'udp',
    dport    => ['2222', '2223'],
    action   => 'accept',
    provider => 'iptables',
  }

  firewall { '201 accept egress State Synchronization and heartbeat traffic (IPv4)':
    chain    => 'OUTPUT',
    proto    => 'udp',
    sport    => ['2222', '2223'],
    action   => 'accept',
    provider => 'iptables',
  }

  # IPv6 Rules (ip6tables)
  firewall { '202 accept ingress State Synchronization and heartbeat traffic (IPv6)':
    chain    => 'INPUT',
    proto    => 'udp',
    dport    => ['2222', '2223'],
    action   => 'accept',
    provider => 'ip6tables',
  }

  firewall { '203 accept egress State Synchronization and heartbeat traffic (IPv6)':
    chain    => 'OUTPUT',
    proto    => 'udp',
    sport    => ['2222', '2223'],
    action   => 'accept',
    provider => 'ip6tables',
  }
}


class platform::network::interfaces::rate_limit (
  $rate_limit_config = {}
) {
  create_resources('platform::network::interfaces::rate_limit::interface', $rate_limit_config, {})
}


class platform::network::interfaces::rate_limit::runtime {
  include platform::network::interfaces::rate_limit
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

class platform::network::blackhole (
  $ipv4_host = undef,
  $ipv4_subnet = undef,
  $ipv6_host = undef,
  $ipv6_subnet = undef,
) {
}

class platform::network::apply {
  include ::platform::params
  include ::platform::network::interfaces
  include ::platform::network::addresses
  include ::platform::network::routes
  include ::platform::network::interfaces::rate_limit
  include ::platform::network::blackhole

  Exec['cleanup-interfaces-file']
  -> Network_config <| |>
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
  -> Exec['install-ipv4-blackhole-address-rule-simplex']
  -> Exec['remove-ipv4-blackhole-address-rule-duplex']

  Network_config <| |>
  -> Platform::Network::Network_route6 <| |>
  -> Exec['apply-network-config']
  -> Exec['install-ipv6-blackhole-address-rule-simplex']
  -> Exec['remove-ipv6-blackhole-address-rule-duplex']

  exec {'apply-network-config':
    command => 'apply_network_config.py',
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

  exec { 'cleanup-interfaces-file':
    command   => 'rm -f /var/run/network-scripts.puppet/interfaces && touch /var/run/network-scripts.puppet/interfaces',
    logoutput => true,
    onlyif    => 'test -f /var/run/network-scripts.puppet/interfaces',
  }

  # The commands below are used for the DRBD peer in AIO-SX as it needs one address to be provided
  # not using a blackhole route because it triggers connection errors messages from the DRBD kernel modules
  # this rule will prevent these packets to reach the outside world
  # lint:ignore:140chars
  exec { 'install-ipv4-blackhole-address-rule-simplex':
    command   => "iptables -t raw -A OUTPUT -d ${::platform::network::blackhole::ipv4_host} -j DROP -m comment --comment 'stx drop rule for blackhole address in AIO-SX'",
    logoutput => true,
    unless    => "iptables -t raw -L OUTPUT | grep -q 'DROP.*${::platform::network::blackhole::ipv4_host}';",
    onlyif    => 'test -f /etc/platform/simplex',
  }

  exec { 'install-ipv6-blackhole-address-rule-simplex':
    command   => "ip6tables -t raw -A OUTPUT -d ${::platform::network::blackhole::ipv6_host} -j DROP  -m comment --comment 'stx drop rule for blackhole address in AIO-SX'",
    logoutput => true,
    unless    => "ip6tables -t raw -L OUTPUT | grep -q 'DROP.*${::platform::network::blackhole::ipv6_host}';",
    onlyif    => 'test -f /etc/platform/simplex',
  }

  exec { 'remove-ipv4-blackhole-address-rule-duplex':
    command   => "iptables -t raw -D OUTPUT \$(iptables -t raw -L OUTPUT -n --line-numbers | grep -E 'DROP.*${::platform::network::blackhole::ipv4_host}' | awk '{print \$1}')",
    logoutput => true,
    onlyif    => ["iptables -t raw -L OUTPUT | grep -q -E 'DROP.*${::platform::network::blackhole::ipv4_host}';", 'test ! -f /etc/platform/simplex'],
  }

  exec { 'remove-ipv6-blackhole-address-rule-duplex':
    command   => "ip6tables -t raw -D OUTPUT \$(ip6tables -t raw -L OUTPUT -n --line-numbers | grep -E 'DROP.*${::platform::network::blackhole::ipv6_host}' | awk '{print \$1}')",
    logoutput => true,
    onlyif    => ["ip6tables -t raw -L OUTPUT | grep -q -E 'DROP.*${::platform::network::blackhole::ipv6_host}';", 'test ! -f /etc/platform/simplex'],
  }
  # lint:endignore:140chars
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
    command => 'apply_network_config.py --routes',
  }
}

class platform::network::upgrade_fqdn_cleanup::runtime {
  include platform::network::upgrade_fqdn_cleanup
}

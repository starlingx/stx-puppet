#
# puppet manifest for controller nodes of AIO system
#

Exec {
  timeout => 600,
  path => '/usr/bin:/usr/sbin:/bin:/sbin:/usr/local/bin:/usr/local/sbin'
}

class { '::firewall':
  ensure => stopped
}

include ::platform::config
include ::platform::users
include ::platform::sysctl::controller
include ::platform::filesystem::controller
include ::platform::firewall::calico::oam
include ::platform::dhclient
include ::platform::partitions
include ::platform::lvm::aio
include ::platform::network
include ::platform::drbd
include ::platform::exports
include ::platform::dns
include ::platform::password
include ::platform::ldap::server
include ::platform::ldap::client
include ::platform::sssd
include ::platform::ntp::server
include ::platform::ptpinstance
include ::platform::ptpinstance::nic_clock
include ::platform::lldp
include ::platform::amqp::rabbitmq
include ::platform::postgresql::server
include ::platform::haproxy::server
include ::platform::grub
include ::platform::etcd
include ::platform::docker::controller
include ::platform::dockerdistribution
include ::platform::containerd::controller
include ::platform::kubernetes::gate
include ::platform::helm
include ::platform::tty
include ::platform::coredump::k8s_token_handler::controller

include ::platform::patching
include ::platform::patching::api

include ::platform::remotelogging
include ::platform::remotelogging::proxy

include ::platform::sysinv
include ::platform::sysinv::api
include ::platform::sysinv::conductor

include ::platform::mtce
include ::platform::mtce::agent

include ::platform::memcached

include ::platform::nfv
include ::platform::nfv::api

include ::platform::ceph::controller
include ::platform::ceph::rgw

include ::platform::collectd

include ::platform::fm
include ::platform::fm::api

include ::platform::multipath
include ::platform::client
include ::openstack::keystone
include ::openstack::keystone::api

include ::openstack::horizon

include ::platform::dcmanager
include ::platform::dcmanager::manager

include ::platform::dcorch
include ::platform::dcorch::engine
include ::platform::dcorch::api_proxy
include ::platform::dcmanager::api
include ::platform::certmon
include ::platform::certalarm

include ::platform::dcdbsync
include ::platform::dcdbsync::api

include ::platform::smapi

include ::openstack::barbican
include ::openstack::barbican::api

include ::platform::sm

include ::platform::lmon
include ::platform::rook
include ::platform::deviceimage

include ::platform::compute
include ::platform::vswitch
include ::platform::devices
include ::platform::network::interfaces::sriov::config
include ::platform::network::interfaces::fpga::config
include ::platform::worker::storage
include ::platform::kubernetes::aio


class { '::platform::config::aio::post':
  stage => post,
}

if $::osfamily == 'Debian' {
  lookup('classes', {merge => unique}).include
} else {
  hiera_include('classes')
}

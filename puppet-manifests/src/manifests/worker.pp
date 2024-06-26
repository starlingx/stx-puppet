#
# puppet manifest for worker nodes
#

# A separated AIO manifest (./aio.pp) is applied to AIO controllers.
# Changes for workers should also be considered to implement in
# aio.pp.

Exec {
  timeout => 300,
  path => '/usr/bin:/usr/sbin:/bin:/sbin:/usr/local/bin:/usr/local/sbin'
}

include ::platform::config
include ::platform::config::iscsi
include ::platform::config::nvme
include ::platform::users
include ::platform::sysctl::compute
include ::platform::dhclient
include ::platform::partitions
include ::platform::lvm::compute
include ::platform::compute
include ::platform::vswitch
include ::platform::network
include ::platform::dns
include ::platform::fstab
include ::platform::password
include ::platform::ldap::client
include ::platform::sssd
include ::platform::ntp::client
include ::platform::strongswan::apparmor
include ::platform::ptpinstance
include ::platform::ptpinstance::nic_clock
include ::platform::lldp
include ::platform::patching
include ::platform::usm
include ::platform::remotelogging
include ::platform::mtce
include ::platform::sysinv
include ::platform::devices
include ::platform::network::interfaces::sriov::config
include ::platform::network::interfaces::fpga::config
include ::platform::grub
include ::platform::collectd
include ::platform::filesystem::compute
include ::platform::docker::worker
include ::platform::containerd::worker
include ::platform::dockerdistribution::compute
include ::platform::kubernetes::worker
include ::platform::firewall::calico::worker
include ::platform::multipath
include ::platform::client
include ::platform::ceph::worker
include ::platform::worker::storage
include ::platform::lmon
include ::platform::rook
include ::platform::tty
include ::platform::crashdump


class { '::platform::config::worker::post':
  stage => post,
}

if $::osfamily == 'Debian' {
  lookup('classes', {merge => unique}).include
} else {
  hiera_include('classes')
}

#
# puppet manifest for storage hosts
#

Exec {
  timeout => 300,
  path => '/usr/bin:/usr/sbin:/bin:/sbin:/usr/local/bin:/usr/local/sbin'
}

include ::platform::config
include ::platform::config::iscsi
include ::platform::config::nvme
include ::platform::users
include ::platform::sysctl::storage
include ::platform::dhclient
include ::platform::partitions
include ::platform::lvm::storage
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
include ::platform::grub
include ::platform::collectd
include ::platform::filesystem::storage
include ::platform::k8splatform
include ::platform::docker::storage
include ::platform::containerd::storage
include ::platform::ceph::storage
include ::platform::rook
include ::platform::tty
include ::platform::crashdump

class { '::platform::config::storage::post':
  stage => post,
}

if $::osfamily == 'Debian' {
  lookup('classes', {merge => unique}).include
} else {
  hiera_include('classes')
}

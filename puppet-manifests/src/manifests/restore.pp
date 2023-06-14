#
# puppet manifest for restore
#

Exec {
  timeout => 600,
  path => '/usr/bin:/usr/sbin:/bin:/sbin:/usr/local/bin:/usr/local/sbin'
}

include ::platform::config::bootstrap
include ::platform::users::bootstrap
include ::platform::sysctl::bootstrap
include ::platform::ldap::bootstrap
include ::platform::drbd::bootstrap
include ::platform::postgresql::bootstrap
include ::platform::amqp::bootstrap
include ::platform::compute::grub::update

include ::platform::drbd::etcd::bootstrap
include ::platform::drbd::dockerdistribution::bootstrap

# Puppet classes to enable the bring up of kubernetes master
include ::platform::docker::bootstrap
include ::platform::etcd::bootstrap

include ::platform::filesystem::docker
include ::platform::filesystem::scratch
include ::platform::filesystem::backup
include ::platform::filesystem::kubelet

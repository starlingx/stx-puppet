#
# puppet manifest for controller initial bootstrap
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

include ::platform::client::bootstrap

# Puppet classes to enable the bring up of kubernetes master
include ::platform::k8splatform::bootstrap
include ::platform::docker::bootstrap
include ::platform::etcd::bootstrap

# Puppet classes to enable initial controller unlock
include ::platform::drbd::dockerdistribution::bootstrap
include ::platform::filesystem::scratch
include ::platform::filesystem::backup
include ::platform::filesystem::kubelet

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
include ::platform::drbd::etcd::bootstrap
include ::platform::drbd::dockerdistribution::bootstrap
include ::platform::filesystem::docker::bootstrap
include ::platform::filesystem::scratch
include ::platform::filesystem::backup
include ::platform::filesystem::kubelet

#
# puppet manifest for subcloud re-home
#

Exec {
  timeout => 600,
  path => '/usr/bin:/usr/sbin:/bin:/sbin:/usr/local/bin:/usr/local/sbin'
}

include ::platform::config

include ::platform::haproxy::runtime

include ::platform::patching
include ::platform::patching::api

include ::platform::sysinv
include ::platform::sysinv::api

include ::platform::mtce
include ::platform::mtce::agent

include ::platform::certmon

include ::platform::smapi::rehome

include ::openstack::barbican
include ::openstack::barbican::api

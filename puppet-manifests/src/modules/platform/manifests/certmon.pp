class platform::certmon {
  if ($::platform::params::distributed_cloud_role == 'systemcontroller' or
      $::platform::params::distributed_cloud_role == 'subcloud') {
      include ::sysinv::certmon
  }
}

class platform::config::params (
  $config_uuid = 'install',
  $hosts = {},
  $timezone = 'UTC',
) { }

class platform::config::certs::params (
  $ssl_ca_cert = '',
) { }


class platform::config
  inherits ::platform::config::params {

  include ::platform::params
  include ::platform::anchors
  include ::platform::config::pam_systemd
  include ::platform::config::system_name

  stage { 'pre':
    before => Stage['main'],
  }

  stage { 'post':
    require => Stage['main'],
  }

  class { '::platform::config::pre':
    stage => pre
  }

  class { '::platform::config::post':
    stage => post,
  }
}


class platform::config::file {

  include ::platform::params
  include ::platform::network::mgmt::params
  include ::platform::network::oam::params
  include ::platform::network::cluster_host::params
  include ::platform::network::admin::params
  include ::openstack::horizon::params

  # dependent template variables
  $management_interface = $::platform::network::mgmt::params::interface_name
  $cluster_host_interface = $::platform::network::cluster_host::params::interface_name
  $oam_interface = $::platform::network::oam::params::interface_name
  $admin_interface = $::platform::network::admin::params::interface_name

  $platform_conf = '/etc/platform/platform.conf'

  file_line { "${platform_conf} sw_version":
    path  => $platform_conf,
    line  => "sw_version=${::platform::params::software_version}",
    match => '^sw_version=',
  }

  if $management_interface {
    file_line { "${platform_conf} management_interface":
      path  => $platform_conf,
      line  => "management_interface=${management_interface}",
      match => '^management_interface=',
    }
  }

  if $cluster_host_interface {
    file_line { "${platform_conf} cluster_host_interface":
      path  => '/etc/platform/platform.conf',
      line  => "cluster_host_interface=${cluster_host_interface}",
      match => '^cluster_host_interface=',
    }
  }
  else {
    file_line { "${platform_conf} cluster_host_interface":
      ensure            => absent,
      path              => '/etc/platform/platform.conf',
      match             => '^cluster_host_interface=',
      match_for_absence => true,
    }
  }

  if $oam_interface {
    file_line { "${platform_conf} oam_interface":
      path  => $platform_conf,
      line  => "oam_interface=${oam_interface}",
      match => '^oam_interface=',
    }
  }

  if $admin_interface {
    file_line { "${platform_conf} admin_interface":
      path  => '/etc/platform/platform.conf',
      line  => "admin_interface=${admin_interface}",
      match => '^admin_interface=',
    }
  }
  else {
    file_line { "${platform_conf} admin_interface":
      ensure            => absent,
      path              => '/etc/platform/platform.conf',
      match             => '^admin_interface=',
      match_for_absence => true,
    }
  }

  if $::platform::params::vswitch_type {
    file_line { "${platform_conf} vswitch_type":
      path  => $platform_conf,
      line  => "vswitch_type=${::platform::params::vswitch_type}",
      match => '^vswitch_type=',
    }
  }

  if $::platform::params::system_type {
    file_line { "${platform_conf} system_type":
      path  => $platform_conf,
      line  => "system_type=${::platform::params::system_type}",
      match => '^system_type=*',
    }
  }

  if $::platform::params::system_mode {
    file_line { "${platform_conf} system_mode":
      path  => $platform_conf,
      line  => "system_mode=${::platform::params::system_mode}",
      match => '^system_mode=*',
    }
  }

  if $::platform::params::security_profile {
    file_line { "${platform_conf} security_profile":
      path  => $platform_conf,
      line  => "security_profile=${::platform::params::security_profile}",
      match => '^security_profile=*',
    }
  }

  if $::platform::params::sdn_enabled {
    file_line { "${platform_conf}f sdn_enabled":
      path  => $platform_conf,
      line  => 'sdn_enabled=yes',
      match => '^sdn_enabled=',
    }
  }
  else {
    file_line { "${platform_conf} sdn_enabled":
      path  => $platform_conf,
      line  => 'sdn_enabled=no',
      match => '^sdn_enabled=',
    }
  }

  if $::platform::params::region_config {
    file_line { "${platform_conf} region_config":
      path  => $platform_conf,
      line  => 'region_config=yes',
      match => '^region_config=',
    }
    file_line { "${platform_conf} region_1_name":
      path  => $platform_conf,
      line  => "region_1_name=${::platform::params::region_1_name}",
      match => '^region_1_name=',
    }
    file_line { "${platform_conf} region_2_name":
      path  => $platform_conf,
      line  => "region_2_name=${::platform::params::region_2_name}",
      match => '^region_2_name=',
    }
  } else {
    file_line { "${platform_conf} region_config":
      path  => $platform_conf,
      line  => 'region_config=no',
      match => '^region_config=',
    }
  }

  if $::platform::params::distributed_cloud_role {
    file_line { "${platform_conf} distributed_cloud_role":
      path  => $platform_conf,
      line  => "distributed_cloud_role=${::platform::params::distributed_cloud_role}",
      match => '^distributed_cloud_role=',
    }
  }

  if $::platform::params::security_feature {
    file_line { "${platform_conf} security_feature":
      path  => $platform_conf,
      line  => "security_feature=\"${::platform::params::security_feature}\"",
      match => '^security_feature=*',
    }
  }

  file_line { "${platform_conf} http_port":
    path  => $platform_conf,
    line  => "http_port=${::openstack::horizon::params::http_port}",
    match => '^http_port=',
  }

  include platform::config::file::subfunctions::lowlatency
}

# update the subfunctions in /etc/platform/platform.conf
# with the current low latency setting
class platform::config::file::subfunctions::lowlatency {
  include platform::sysctl::params
  $platform_conf = '/etc/platform/platform.conf'

  if str2bool($platform::sysctl::params::low_latency) {
    # low latency = true, append 'lowlatency'
    if !str2bool($::is_lowlatency_subfunction) {
      $subfunctions = "${::subfunction},lowlatency"

      file_line { "${platform_conf} subfunctions":
        path  => $platform_conf,
        line  => "subfunction=${subfunctions}",
        match => '^subfunction=',
      }
    }
  }
  else {
    # low latency = false, remove 'lowlatency'
    if str2bool($::is_lowlatency_subfunction) {
      $subfunctions = regsubst($::subfunction, /,?lowlatency/,'')

      file_line { "${platform_conf} subfunctions":
        path  => $platform_conf,
        line  => "subfunction=${subfunctions}",
        match => '^subfunction=',
      }
    }
  }
}

# runtime manifest updates subfunctions line
# in /etc/platform/platform.conf to match low latency config setting
class platform::config::file::subfunctions::lowlatency::runtime {
  include platform::config::file::subfunctions::lowlatency
}

class platform::config::hostname {
  include ::platform::params

  file { '/etc/hostname':
    ensure  => present,
    owner   => root,
    group   => root,
    mode    => '0644',
    content => "${::platform::params::hostname}\n",
    notify  => Exec['set-hostname'],
  }

  exec { 'set-hostname':
    command => 'hostname -F /etc/hostname',
    unless  => 'test `hostname` = `cat /etc/hostname`',
  }
}

class platform::config::system_name {
  $system_name = $platform::params::system_name

  file { '/etc/sysinv/motd.system':
    ensure  => present,
    owner   => 'root',
    group   => 'root',
    mode    => '0644',
    content => template('platform/system_name.erb'),
  }
}

class platform::config::apparmor {
  include ::platform::params

  if $::osfamily == 'Debian' {
    if $::platform::params::apparmor == 'enabled' {
        exec { 'set-apparmor':
          command => '/usr/bin/sed -i "s/apparmor=0/apparmor=1/" /boot/1/kernel.env',
        }
    } else {
        exec { 'remove-apparmor':
          command => '/usr/bin/sed -i "s/apparmor=1/apparmor=0/" /boot/1/kernel.env',
        }
    }
  }
}

class platform::config::apparmor::runtime {
  include ::platform::config::apparmor
}


class platform::config::mgmt_network_reconfig_update_runtime {
  include ::sysinv
  include ::platform::params

  $platform_sw_version    = $::platform::params::software_version
  $zeromq_bind_ip         = $::sysinv::rpc_zeromq_bind_ip

  # update hosts file to be used for all reboots
  exec { "Copy /etc/hosts to /opt/platform/config/${platform_sw_version}/hosts" :
        command => "cp -f /etc/hosts /opt/platform/config/${platform_sw_version}/hosts",
  }

  file_line { "mgmt_reconfig update rpc_zeromq_bind_ip to ${zeromq_bind_ip}":
    path               => "/opt/platform/sysinv/${platform_sw_version}/sysinv.conf.default",
    line               => "rpc_zeromq_bind_ip=${zeromq_bind_ip}",
    match              => '^rpc_zeromq_bind_ip=',
    append_on_no_match => false,
  }
}


class platform::config::hosts
  inherits ::platform::config::params {

  # The localhost should resolve to the IPv4 loopback address only, therefore
  # ensure the IPv6 address is removed from configured hosts
  resources { 'host': purge => true }

  $localhost = {
    'localhost' => {
      ip => '127.0.0.1',
      host_aliases => ['localhost.localdomain', 'localhost4', 'localhost4.localdomain4']
    },
  }

  # it will replace previous aliases of controller
  $nfs_alias_controller = {
    'controller' => {
      host_aliases => ['registry.local','controller-platform-nfs']
    },
  }

  $hosts_with_alias = deep_merge($hosts, $nfs_alias_controller)
  $merged_hosts = merge($localhost, $hosts_with_alias)

  $dns_host_records = lookup({'name'  => 'platform::config::hosts::host_records', 'default_value' => []})

  # The controller needs to add dns host records to /etc/hosts file for name resolution,
  # before initial unlock when dnsmasq service is not running
  if ($::personality != 'controller') or
      ($dns_host_records == [] or str2bool($::is_dnsmasq_running)) {
    create_resources('host', $merged_hosts, {})
  } else {
    $host_records_hash = $dns_host_records.map | $line | {
      $ip_record = split($line, ' ')
      $host_record = {
        $ip_record[1] => {
          ip => $ip_record[0],
          host_aliases => $ip_record[2,-1]
        }
      }
    }
    $reduced_hosts_records = $host_records_hash.reduce({}) |$result, $resource| { $result + $resource }
    $merged_host_records = merge($merged_hosts, $reduced_hosts_records)
    create_resources('host', $merged_host_records, {})
  }
}


class platform::config::dnsmasq {
  include ::platform::params

  $config_path = $::platform::params::config_path
  $path_exists = find_file($config_path)

  if $path_exists and $::personality == 'controller' {
    file { "${config_path}/dnsmasq.addn_conf":
      ensure  => present,
    }
  }
}


class platform::config::timezone
  inherits ::platform::config::params {
  exec { 'Configure Timezone':
    command => "ln -sf /usr/share/zoneinfo/${timezone} /etc/localtime",
  }
}


class platform::config::tpm {
  if $::osfamily == 'Debian' {
    $tpm_certs = lookup({'name'  => 'platform::tpm::tpm_data', 'merge' => 'hash', 'default_value' => undef})
  } else {
    $tpm_certs = hiera_hash('platform::tpm::tpm_data', undef)
  }
  if $tpm_certs != undef {
    # iterate through each tpm_cert creating it if it doesn't exist
    $tpm_certs.each |String $key, String $value| {
      file { "create-TPM-cert-${key}":
        ensure  => present,
        path    => $key,
        owner   => root,
        group   => root,
        mode    => '0644',
        content => $value,
      }
    }
  }
}


class platform::config::kdump {
  if $::osfamily == 'RedHat' {
    file_line { '/etc/kdump.conf dracut_args':
      path  => '/etc/kdump.conf',
      line  => 'dracut_args --omit-drivers "ice e1000e i40e ixgbe ixgbevf iavf mlx5_ib mlx5_core bnxt_en bnxt_re"',
      match => '^dracut_args .*--omit-drivers',
    }
    ~> service { 'kdump': }
  } else {
    exec { 'enable-kdump-tools':
      command => '/usr/bin/systemctl enable kdump-tools.service',
    }
    -> service{ 'kdump-tools':
      enable => true,
    }
  }
}


class platform::config::certs::ssl_ca
  inherits ::platform::config::certs::params {

  case $::osfamily {
    'RedHat': {
      $ssl_ca_file = '/etc/pki/ca-trust/source/anchors/ca-cert.pem'
      $ca_update_cmd = 'update-ca-trust'
    }
    default: {
      # This directory does not exist by default on debian
      $ca_trust_dir = '/etc/pki/ca-trust/source/anchors'
      file { ['/etc/pki', '/etc/pki/ca-trust', '/etc/pki/ca-trust/source', $ca_trust_dir]:
        ensure => 'directory',
        owner  => root,
        group  => root,
        mode   => '0755',
      }
      # update-ca-certificates command only scans for *.crt files
      $ssl_ca_file = "${ca_trust_dir}/ca-cert.crt"
      # This updates Debian's Trusted CAs file which is /etc/ssl/certs/ca-certificates.crt
      # with certificates present in *.crt files in $ca_trust_dir
      $ca_update_cmd = "update-ca-certificates --localcertsdir ${ca_trust_dir}"
    }
  }

  if str2bool($::is_initial_config) {
    $containerd_restart_cmd = 'systemctl restart containerd'
    $dockerd_restart_cmd = 'systemctl restart docker'
  }
  else {
    $containerd_restart_cmd = 'pmon-restart containerd'
    $dockerd_restart_cmd = 'pmon-restart dockerd'
  }

  if ! empty($ssl_ca_cert) {
    file { 'create-ssl-ca-cert':
      ensure  => present,
      path    => $ssl_ca_file,
      owner   => root,
      group   => root,
      mode    => '0644',
      content => $ssl_ca_cert,
    }
  }
  else {
    file { 'create-ssl-ca-cert':
      ensure => absent,
      path   => $ssl_ca_file
    }
  }
  exec { 'update-ca-certificates':
    command     => $ca_update_cmd,
    subscribe   => File[$ssl_ca_file],
    refreshonly => true
  }
  # Restart containerd.
  -> exec { 'restart containerd':
    command     => $containerd_restart_cmd,
    subscribe   => File[$ssl_ca_file],
    onlyif      => 'systemctl is-enabled containerd.service | grep -wq enabled',
    refreshonly => true
  }
  # Restart docker.
  -> exec { 'restart dockerd':
    command     => $dockerd_restart_cmd,
    subscribe   => File[$ssl_ca_file],
    onlyif      => 'systemctl is-enabled dockerd.service | grep -wq enabled',
    refreshonly => true
  }
  -> exec { 'restart sssd service on cert install/uninstall':
    command     => '/usr/local/sbin/pmon-restart sssd',
    subscribe   => File[$ssl_ca_file],
    refreshonly => true,
    onlyif      => "test '${::osfamily }' == 'Debian'",
  }

  if str2bool($::is_controller_active) {
    Exec['restart sssd service on cert install/uninstall']
    -> file { '/etc/platform/.ssl_ca_complete':
      ensure => present,
      owner  => root,
      group  => root,
      mode   => '0644',
    }
  }
}

class platform::config::dccert::params (
  $dc_root_ca_crt = '',
  $dc_adminep_crt = ''
) { }


class platform::config::dc_root_ca
  inherits ::platform::config::dccert::params {
  $dc_root_ca_file = '/etc/pki/ca-trust/source/anchors/dc-adminep-root-ca.crt'
  $dc_adminep_cert_file = '/etc/ssl/private/admin-ep-cert.pem'

  case $::osfamily {
    'RedHat': {
      $ca_update_cmd = 'update-ca-trust'
    }
    default: {
      $ca_update_cmd = 'update-ca-certificates --localcertsdir /etc/pki/ca-trust/source/anchors'
    }
  }

  if ! empty($dc_adminep_crt) {
    file { 'adminep-cert':
      ensure  => present,
      path    => $dc_adminep_cert_file,
      owner   => root,
      group   => root,
      mode    => '0400',
      content => $dc_adminep_crt,
    }
  }

  if ! empty($dc_root_ca_crt) {
    file { 'create-dc-adminep-root-ca-cert':
      ensure  => present,
      path    => $dc_root_ca_file,
      owner   => root,
      group   => root,
      mode    => '0644',
      content => $dc_root_ca_crt,
    }
    -> exec { 'update-dc-ca-trust':
      command     => $ca_update_cmd,
    }
  }
}


class platform::config::runtime {
  include ::platform::config::certs::ssl_ca
}

class platform::config::dc_root_ca::runtime {
  include platform::config::dc_root_ca
}

class platform::config::pre {
  group { 'nobody':
    ensure => 'present',
    gid    => '99',
  }

  include ::platform::config::apparmor
  include ::platform::config::timezone
  include ::platform::config::hostname
  include ::platform::config::hosts
  include ::platform::config::file
  include ::platform::config::tpm
  include ::platform::config::kdump
  include ::platform::config::certs::ssl_ca
  if (($::platform::params::distributed_cloud_role =='systemcontroller' or
        $::platform::params::distributed_cloud_role =='subcloud') and
      $::personality == 'controller') {
    include ::platform::config::dc_root_ca
  }
  include ::platform::coredump::k8s_token_handler::config
  include ::platform::coredump::runtime
}


class platform::config::post
  inherits ::platform::config::params {

  include ::platform::params
  include ::platform::config::dnsmasq

  case $::osfamily {
    'RedHat': {
      $cronservice = 'crond'
    }
    'Debian': {
      $cronservice = 'cron'
    }
    default: {
      fail("unsuported osfamily ${::osfamily}, currently Debian and Redhat are the only supported platforms")
    }
  } # Case $::osfamily

  service { $cronservice:
    ensure => 'running',
    enable => true,
  }

  # When applying manifests to upgrade controller-1, we do not want SM or the
  # sysinv-agent or anything else that depends on these flags to start.
  if ! $::platform::params::controller_upgrade {
    file { '/etc/platform/.config_applied':
      ensure  => present,
      mode    => '0640',
      content => "CONFIG_UUID=${config_uuid}"
    }
  }
}

class platform::config::controller::post
{
  include ::platform::params

  if ! $::platform::params::controller_upgrade {
    file { '/etc/platform/.initial_config_complete':
      ensure => present,
    }
  }

  file { '/etc/platform/.bootstrap_completed':
    ensure => present,
  }

  file { '/etc/platform/.initial_controller_config_complete':
    ensure => present,
  }

  file { '/var/run/.controller_config_complete':
    ensure => present,
  }

  # In standard mode, the active controller will update grub parameters via
  # platform::compute::grub::runtime. But to update a standby controller,
  # platform::compute::grub::audit needs to be called from here like it's being
  # done for the workers.
  # The active controller will also call this code, for both standard and AIO-SX
  # systems, but platform::compute::grub::audit will not execut grub update again
  # since the it was already updated via platform::compute::grub::runtime.
  include ::platform::compute::grub::audit
}

class platform::config::worker::post
{
  include ::platform::params

  if ! $::platform::params::controller_upgrade {
    file { '/etc/platform/.initial_config_complete':
      ensure => present,
    }
  }

  file { '/etc/platform/.bootstrap_completed':
    ensure => present,
  }

  file { '/etc/platform/.initial_worker_config_complete':
    ensure => present,
  }

  file { '/var/run/.worker_config_complete':
    ensure => present,
  }

  include ::platform::compute::grub::audit
}

class platform::config::storage::post
{
  include ::platform::params

  if ! $::platform::params::controller_upgrade {
    file { '/etc/platform/.initial_config_complete':
      ensure => present,
    }
  }

  file { '/etc/platform/.initial_storage_config_complete':
    ensure => present,
  }

  file { '/var/run/.storage_config_complete':
    ensure => present,
  }

  file { '/etc/platform/.bootstrap_completed':
    ensure => present,
  }
}

class platform::config::aio::post
{
  file { '/etc/platform/.initial_controller_config_complete':
    ensure => present,
  }

  file { '/var/run/.controller_config_complete':
    ensure => present,
  }

  include ::platform::config::worker::post
}

class platform::config::bootstrap {
  stage { 'pre':
    before => Stage['main'],
  }

  stage { 'post':
    require => Stage['main'],
  }

  include ::platform::params
  include ::platform::anchors
  include ::platform::config::hostname
  include ::platform::config::hosts
}

class platform::config::pam_systemd {
  file_line { 'rm pam_systemd':
    ensure            => absent,
    path              => '/etc/pam.d/common-session',
    match             => 'pam_systemd.so$',
    match_for_absence => true,
  }
}

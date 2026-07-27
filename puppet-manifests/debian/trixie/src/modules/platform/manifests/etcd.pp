class platform::etcd::params (
  $bind_address         = '0.0.0.0',
  $bind_address_version = 4,
  $port                 = 2379,
  $peer_port            = 2380,
  $node                 = 'controller',
  $etcd_version         = undef,
  $fixed_service_name   = 'etcd-fixed',
  $fixed_basedir        = '/opt/etcd-fixed',
  $fixed_name_prefix    = 'fixed',
  $floating_name        = 'controller',
  $quota_backend_bytes  = 5368508416,
  $controller0_address  = undef,
)
{
  include ::platform::params

  $sw_version = $::platform::params::software_version
  $etcd_basedir = '/opt/etcd'
  $etcd_dir = "${etcd_basedir}/db"

  # The client_url contains IP addresses consistent with
  # /etc/etcd/etcd-server.crt. The CRT contains x509 certificate
  # subjectAltName with: cluster_floating_address (either IPv4 or IPv6),
  # and IPv4 loopback.
  if $bind_address_version == $::platform::params::ipv6 {
    $client_url = "https://[${bind_address}]:${port},https://127.0.0.1:${port}"
  }
  else {
    $client_url = "https://${bind_address}:${port},https://127.0.0.1:${port}"
  }
}

class platform::etcd::symlinks {
  include ::platform::etcd::params
  include ::platform::kubernetes::params

  # Determine the supported etcd version by querying kubeadm for the etcd
  # image associated with the currently installed kubernetes version, then
  # selecting the highest installed version whose major.minor does not
  # exceed the kubernetes-expected major.minor. Falls back to max installed.
  $etcd_version = $::platform::etcd::params::etcd_version
  $kubeadm_version = $::platform::kubernetes::params::kubeadm_version
  $symlink_path = '/var/lib/etcd/stage0'

  # Guard against downgrading symlinks when puppet is applied with stale
  # cached hieradata during boot (e.g., when NFS is unreachable and the
  # host falls back to local cache after an etcd upgrade).
  # Use the higher of hieradata version and current symlink version.
  $current_etcd = strip(generate('/bin/bash', '-c',
    'if [ -L /var/lib/etcd/stage0 ]; then
       basename "$(dirname "$(readlink /var/lib/etcd/stage0)")";
     fi'))

  if $etcd_version != undef {
    # Only update symlink if hieradata version >= current symlink version.
    if $current_etcd != '' and versioncmp($current_etcd, $etcd_version) > 0 {
      $version = $current_etcd
      notice("stage0 symlink: keeping current version ${current_etcd} (hieradata has older ${etcd_version})")
    } else {
      $version = $etcd_version
      notice("setting stage0 symlink, etcd_version is ${etcd_version}")
    }
  } elsif str2bool(inline_template('<%= File.symlink?(@symlink_path) && File.exist?(@symlink_path) %>')) {
    # Leave existing symlink as-is.
    notice('etcd stage0 symlink already exists and no hieradata defined, skipping')
    $version = undef
  } else {
    # Use supported version fallback mechanism.
    $etcd_supported_version = strip(
      generate('/bin/bash', '-c', template('platform/etcd_supported_version.erb'))
    )
    notice("Falling back to etcd_version ${etcd_supported_version} supported version")
    $version = $etcd_supported_version
  }

  file { '/var/lib/etcd':
      ensure => 'directory',
      owner  => 'root',
      group  => 'root',
      mode   => '0755',
  }

  if $version {
    notice("setting stage0 symlink, etcd_version is ${version}")
    file { $symlink_path:
      ensure  => link,
      target  => "/usr/local/etcd/${version}/stage0",
      require => File['/var/lib/etcd'],
    }
  }
}

# Modify the systemd service file for etcd and
# create an init.d script for SM to manage the service.
# Also install the etcd-fixed systemd service for non-simplex.
class platform::etcd::setup {

  include ::platform::params
  include ::platform::k8splatform::params
  include ::platform::etcd::params

  # Ensure the cluster-host floating IP is on the interface before etcd
  # starts. On AIO it is on loopback from bootstrap. On Standard, SM assigns
  # it during go-active but etcd may start before that completes.
  exec { 'ensure cluster-host floating IP for etcd':
    command  => '/usr/local/bin/ensure-etcd-floating-ip.sh',
    provider => shell,
  }

  # Ensure SM status check can find etcd config
  file { '/etc/etcd/etcd.conf':
    ensure => link,
    target => '/etc/default/etcd',
  }

  # Update etcd symlink if needed.
  require platform::etcd::symlinks

  if $::platform::params::system_type == 'All-in-one' and
    $::platform::params::distributed_cloud_role != 'systemcontroller' {
    $etcd_max_procs = $::platform::params::eng_workers
  } else {
    $etcd_max_procs = '$(nproc)'
  }

  file {'etcd_override_dir':
    ensure => directory,
    path   => '/etc/systemd/system/etcd.service.d',
    mode   => '0755',
  }
  -> file { '/etc/systemd/system/etcd.service.d/etcd-override.conf':
    ensure  => file,
    owner   => 'root',
    group   => 'root',
    mode    => '0644',
    content => template('platform/etcd-override.conf.erb'),
  }
  -> file {'etcd_initd_script':
    ensure => 'present',
    path   => '/etc/init.d/etcd',
    mode   => '0755',
    source => "puppet:///modules/${module_name}/etcd"
  }
  # Install etcd-fixed systemd service unit for all configurations.
  # The fixed etcd instance runs on per-controller (non-DRBD) storage.
  # On simplex it is the sole etcd instance; on duplex it coexists with
  # the floating SM-managed instance. Chained here so the single
  # daemon-reload below picks up both unit files in one pass.
  -> file { '/etc/systemd/system/etcd-fixed.service':
    ensure  => file,
    owner   => 'root',
    group   => 'root',
    mode    => '0644',
    content => template('platform/etcd-fixed.service.erb'),
  }
  -> exec { 'systemd-reload-daemon':
    command     => '/usr/bin/systemctl daemon-reload',
  }
  # Mitigate systemd hung behaviour after daemon-reload
  -> exec { 'verify-systemd-running - etcd setup':
    command   => '/usr/local/bin/verify-systemd-running.sh',
    logoutput => true,
  }
  -> Service['etcd']
}

# -----------------------------------------------------------------------
# platform::etcd::init - configure the floating (SM-managed) etcd instance.
#
# Design:
# - Simplex: original behavior — the floating SM-managed etcd is the only
#   instance. No fixed etcd, no clustering.
# - Duplex/Std: the floating etcd instance joins the existing fixed cluster.
# -----------------------------------------------------------------------
class platform::etcd::init (
  $service_enabled = false,
  $bootstrap_mode = false,
) inherits ::platform::etcd::params {

  include ::platform::params

  if $service_enabled {
    $service_ensure = 'running'
  }
  else {
    $service_ensure = 'stopped'
  }

  $client_cert_auth = true
  $cert_file = '/etc/etcd/etcd-server.crt'
  $key_file = '/etc/etcd/etcd-server.key'
  $trusted_ca_file = '/etc/etcd/ca.crt'

  # At host-unlock, cluster_host params are available from system hieradata.
  # At bootstrap they are not — use bind_address (cluster floating IP) as fallback.
  if $bootstrap_mode {
    $cluster_host_floating_address = $bind_address
    if $controller0_address {
      $cluster_host_controller0_address = $controller0_address
    } else {
      $cluster_host_controller0_address = $bind_address
    }
    $cluster_host_controller1_address = $bind_address
    notice("etcd init: bootstrap_mode=true, floating=${cluster_host_floating_address}, fixed0=${cluster_host_controller0_address}")
  } else {
    include ::platform::network::cluster_host::params
    $cluster_host_floating_address = $::platform::network::cluster_host::params::controller_address
    $cluster_host_controller0_address = $::platform::network::cluster_host::params::controller0_address
    $cluster_host_controller1_address = $::platform::network::cluster_host::params::controller1_address
  }

  if $bind_address_version == $::platform::params::ipv6 {
    $floating_client_url = "https://[${cluster_host_floating_address}]:${port}"
    $floating_peer_url = "https://[${cluster_host_floating_address}]:${peer_port}"
    $fixed0_peer_url = "https://[${cluster_host_controller0_address}]:${peer_port}"
    $fixed1_peer_url = "https://[${cluster_host_controller1_address}]:${peer_port}"
  } else {
    $floating_client_url = "https://${cluster_host_floating_address}:${port}"
    $floating_peer_url = "https://${cluster_host_floating_address}:${peer_port}"
    $fixed0_peer_url = "https://${cluster_host_controller0_address}:${peer_port}"
    $fixed1_peer_url = "https://${cluster_host_controller1_address}:${peer_port}"
  }

  if $::platform::params::system_mode == 'simplex' {
    # Simplex: original behavior — floating SM-managed etcd only.
    $etcd_name = $node
    $cluster_enabled = false
    $listen_peer_urls = undef
    $initial_advertise_peer_urls = undef
    $initial_cluster = undef
    $initial_cluster_state = undef
    $listen_client_urls = $client_url
    $advertise_client_urls = $client_url
    $data_dir = "${etcd_dir}/${node}.etcd"
  } else {
    # Duplex/Std: floating instance joins the fixed cluster.
    # The fixed-0 instance is already running as the cluster seed.
    $etcd_name = $floating_name
    $cluster_enabled = true
    $listen_peer_urls = $floating_peer_url
    $initial_advertise_peer_urls = $floating_peer_url
    # Initial cluster includes the seed (fixed-0) and this floating member.
    $initial_cluster = "${fixed_name_prefix}-0=${fixed0_peer_url},${floating_name}=${floating_peer_url}"
    $initial_cluster_state = 'existing'
    $listen_client_urls = $floating_client_url
    $advertise_client_urls = $floating_client_url
    $data_dir = "${etcd_dir}/${node}.etcd"
  }

  class { 'etcd':
    ensure                      => 'present',
    etcd_name                   => $etcd_name,
    service_enable              => false,
    service_ensure              => $service_ensure,
    cluster_enabled             => $cluster_enabled,
    listen_peer_urls            => $listen_peer_urls,
    initial_advertise_peer_urls => $initial_advertise_peer_urls,
    initial_cluster             => $initial_cluster,
    initial_cluster_state       => $initial_cluster_state,
    listen_client_urls          => $listen_client_urls,
    advertise_client_urls       => $advertise_client_urls,
    data_dir                    => $data_dir,
    proxy                       => 'off',
    client_cert_auth            => $client_cert_auth,
    cert_file                   => $cert_file,
    key_file                    => $key_file,
    trusted_ca_file             => $trusted_ca_file,

    peer_cert_file              => $cert_file,
    peer_key_file               => $key_file,
    peer_client_cert_auth       => true,
    peer_trusted_ca_file        => $trusted_ca_file,
  }

  # etcd 3.6 removed v2 proxy support. The upstream puppet-etcd template
  # still generates these deprecated settings which cause etcd to exit
  # immediately. Strip them until the upstream module is updated.
  exec { 'remove deprecated etcd v2 proxy settings':
    command => '/bin/sed -i "/ETCD_ENABLE_V2/d;/ETCD_PROXY/d;/ETCD_DISCOVERY_FALLBACK/d;/ETCD_DISCOVERY_PROXY/d;/ETCD_DEBUG/d" /etc/default/etcd', # lint:ignore:140chars
    onlyif  => '/bin/grep -Eq "ETCD_ENABLE_V2|ETCD_PROXY|ETCD_DISCOVERY_FALLBACK|ETCD_DISCOVERY_PROXY|ETCD_DEBUG" /etc/default/etcd',
    require => File['/etc/default/etcd'],
    before  => Service['etcd'],
  }
}


# -----------------------------------------------------------------------
# platform::etcd (unlock class)
#
# Called on host-unlock for both controllers.
# - The fixed instance (etcd-fixed) does NOT depend on DRBD.
# - The floating instance (SM-managed) depends on DRBD (duplex/std only).
# - On controller-0 unlock: everything was already configured at bootstrap,
#   so this is effectively a no-op (idempotent).
# - On controller-1 unlock: the fixed-1 instance is configured and started,
#   joining the existing cluster.
# -----------------------------------------------------------------------
class platform::etcd
  inherits ::platform::etcd::params {

  include ::platform::params

  if $::platform::params::system_mode == 'simplex' {
    # Simplex: only the fixed etcd instance runs on local storage.
    # No floating SM-managed instance, no DRBD dependency for etcd.
    # The DRBD etcd LV is still created (for simplex-to-duplex conversion)
    # but the SM etcd service is deprovisioned.
    include ::platform::etcd::datadir::fixed
    include ::platform::etcd::setup

    Class['::platform::etcd::datadir::fixed']
    -> Class['::platform::etcd::setup']
    -> class { '::platform::etcd::init':
      service_enabled => false,
    }

    # Do NOT start during a USM upgrade. On simplex the keyspace is relocated
    # from the DRBD path to the local filesystem at activate; starting the
    # service before that founds an empty cluster on the new data directory,
    # which the relocation then has to stop and discard. The duplex path in
    # platform::etcd::membership applies the same gate.
    $fixed_ensure = str2bool($::usm_upgrade_in_progress) ? {
      true    => undef,
      default => running,
    }

    # Only the unit is required here. /etc/default/etcd-fixed is written by
    # platform::etcd::bootstrap, which is not part of this catalog on simplex --
    # requiring it here made the catalog fail to compile with "Could not find
    # resource File[/etc/default/etcd-fixed] in parameter 'require'", so the
    # host could not be unlocked. The duplex path can and does require the
    # environment file, because platform::etcd::membership declares it in the
    # same catalog.
    service { $fixed_service_name:
      ensure  => $fixed_ensure,
      enable  => str2bool($::usm_upgrade_in_progress) ? {
        true    => false,
        default => true,
      },
      require => File['/etc/systemd/system/etcd-fixed.service'],
    }
  } else {
    # Duplex/Std: floating etcd depends on DRBD, fixed does not.
    Class['::platform::drbd::etcd'] -> Class[$name]

    include ::platform::etcd::datadir::fixed
    include ::platform::etcd::datadir::floating
    include ::platform::etcd::setup
    include ::platform::etcd::membership

    # Fixed path (NO DRBD dependency)
    Class['::platform::etcd::datadir::fixed']
    -> Class['::platform::etcd::setup']

    # Floating path (DRBD-dependent)
    Class['::platform::etcd::datadir::floating']
    -> Class['::platform::etcd::setup']

    # Membership must run BEFORE floating etcd starts:
    # 1. Rewrites etcd-fixed config with real IPs and restarts it
    # 2. Adds floating member to the cluster via etcdctl
    # 3. Then floating etcd can start and join the existing cluster
    Class['::platform::etcd::setup']
    -> Class['::platform::etcd::membership']
    -> class { '::platform::etcd::init':
      # The floating instance is SM-managed: platform::drbd::etcd leaves the
      # volume to SM on duplex, so the service belongs to SM too. Starting it
      # here races SM -- at this point SM is still initialising and drbd-etcd
      # is still Secondary, so /opt/etcd cannot be mounted. SM starts etcd
      # itself once etcd-fs is mounted.
      service_enabled => false,
    }
  }
}

# -----------------------------------------------------------------------
# Datadir classes - split for DRBD decoupling
# -----------------------------------------------------------------------

# Fixed datadir: on root filesystem, NO DRBD dependency
class platform::etcd::datadir::fixed
  inherits ::platform::etcd::params {

  file { $fixed_basedir:
    ensure => 'directory',
    owner  => 'root',
    group  => 'root',
    mode   => '0755',
  }

  file { "${fixed_basedir}/db":
    ensure  => 'directory',
    owner   => 'root',
    group   => 'root',
    mode    => '0755',
    require => File[$fixed_basedir],
  }
}

# Floating datadir: on DRBD-backed storage
class platform::etcd::datadir::floating
  inherits ::platform::etcd::params {

  Class['::platform::drbd::etcd'] -> Class[$name]

  if $::platform::params::init_database {
    file { $etcd_dir:
        ensure => 'directory',
        owner  => 'root',
        group  => 'root',
        mode   => '0755',
    }
  }
}

# Legacy datadir class for backward compatibility
class platform::etcd::datadir
  inherits ::platform::etcd::params {

  Class['::platform::drbd::etcd'] -> Class[$name]

  if $::platform::params::init_database {
    file { $etcd_dir:
        ensure => 'directory',
        owner  => 'root',
        group  => 'root',
        mode   => '0755',
    }
  }
}

# -----------------------------------------------------------------------
# Bootstrap datadir: creates both fixed and floating directories.
# Fixed dirs have NO DRBD dependency. Floating (DRBD) dir has DRBD dep.
# -----------------------------------------------------------------------
class platform::etcd::datadir::bootstrap
  inherits ::platform::etcd::params {

  include ::platform::params

  # DRBD bootstrap creates the LV and mounts /opt/etcd
  require ::platform::drbd::etcd::bootstrap
  Class['::platform::drbd::etcd::bootstrap'] -> Class[$name]

  # Floating datadir (DRBD-backed)
  file { $etcd_dir:
      ensure => 'directory',
      owner  => 'root',
      group  => 'root',
      mode   => '0755',
  }

  # Fixed datadir (root filesystem, no DRBD dependency)
  file { $fixed_basedir:
    ensure => 'directory',
    owner  => 'root',
    group  => 'root',
    mode   => '0755',
  }
  -> file { "${fixed_basedir}/db":
    ensure => 'directory',
    owner  => 'root',
    group  => 'root',
    mode   => '0755',
  }
}

# -----------------------------------------------------------------------
# platform::etcd::bootstrap
#
# The fixed etcd instance on controller-0 bootstraps as
# the initial single-node cluster seed. For duplex/std, the floating
# instance is then added to the cluster via etcdctl member add.
#
# The fixed instance:
# - Runs under the 'etcd-fixed' systemd service
# - Stores data at /opt/etcd-fixed/db/fixed-0.etcd (non-DRBD)
# - Listens on the controller-0 cluster-host unit IP
# - ETCD_QUOTA_BACKEND_BYTES limits storage to match DRBD LV size
#
# For duplex/std, after the fixed instance is running:
# - DRBD etcd resource is created and mounted at /opt/etcd
# - The floating instance is added via 'etcdctl member add'
# - Floating is configured with --initial-cluster-state=existing
# - SM etcd service is created and started
#
# For simplex:
# - Only the fixed instance runs
# - DRBD LV is created (for future simplex-to-duplex) but SM etcd is
#   disabled/unmanaged
# -----------------------------------------------------------------------
class platform::etcd::bootstrap
  inherits ::platform::etcd::params {

  include ::platform::params
  include ::platform::etcd::datadir::bootstrap
  include ::platform::etcd::setup

  # During bootstrap, cluster_host params are not available in static.yaml.
  # Use bind_address (set to cluster_floating_address by ansible) as the
  # controller-0 address. On simplex, controller0 = floating. On duplex,
  # the addresses are corrected at host-unlock when full hieradata is available.
  # Use the real controller-0 unit address for fixed-0 (passed via hieradata).
  # For simplex, controller0_address may not be set — fall back to bind_address.
  if $controller0_address {
    $cluster_host_controller0_address = $controller0_address
  } else {
    $cluster_host_controller0_address = $bind_address
  }
  notice("etcd bootstrap: fixed-0 addr=${cluster_host_controller0_address}, floating addr=${bind_address}")

  if $bind_address_version == $::platform::params::ipv6 {
    $fixed0_client_url = "https://[${cluster_host_controller0_address}]:${port}"
    $fixed0_peer_url = "https://[${cluster_host_controller0_address}]:${peer_port}"
  } else {
    $fixed0_client_url = "https://${cluster_host_controller0_address}:${port}"
    $fixed0_peer_url = "https://${cluster_host_controller0_address}:${peer_port}"
  }

  # Write the etcd-fixed environment file for the bootstrap seed (fixed-0)
  # At bootstrap, use 127.0.0.1 for LISTEN to avoid binding to IPs
  # not yet assigned. ADVERTISE uses bind_address (floating IP) so that
  # peers can find this member later. The membership class at unlock will
  # rewrite this file with real controller unit IPs and restart the service.
  $bootstrap_etcd_fixed_content = @("EOF")
ETCD_NAME="${fixed_name_prefix}-0"
ETCD_DATA_DIR="${fixed_basedir}/db/${fixed_name_prefix}-0.etcd"
ETCD_LISTEN_CLIENT_URLS="${fixed0_client_url},https://127.0.0.1:${port}"
ETCD_ADVERTISE_CLIENT_URLS="${fixed0_client_url}"
ETCD_LISTEN_PEER_URLS="${fixed0_peer_url}"
ETCD_INITIAL_ADVERTISE_PEER_URLS="${fixed0_peer_url}"
ETCD_INITIAL_CLUSTER="${fixed_name_prefix}-0=${fixed0_peer_url}"
ETCD_INITIAL_CLUSTER_STATE="new"
ETCD_INITIAL_CLUSTER_TOKEN="etcd-cluster"
ETCD_QUOTA_BACKEND_BYTES="${quota_backend_bytes}"
ETCD_CLIENT_CERT_AUTH="true"
ETCD_CERT_FILE="/etc/etcd/etcd-server.crt"
ETCD_KEY_FILE="/etc/etcd/etcd-server.key"
ETCD_TRUSTED_CA_FILE="/etc/etcd/ca.crt"
ETCD_PEER_CLIENT_CERT_AUTH="true"
ETCD_PEER_CERT_FILE="/etc/etcd/etcd-server.crt"
ETCD_PEER_KEY_FILE="/etc/etcd/etcd-server.key"
ETCD_PEER_TRUSTED_CA_FILE="/etc/etcd/ca.crt"
EOF

  file { '/etc/default/etcd-fixed':
    ensure  => file,
    owner   => 'root',
    group   => 'root',
    mode    => '0644',
    content => $bootstrap_etcd_fixed_content,
  }

  # Configure the floating etcd (stopped at bootstrap, SM will manage it)
  Class['::platform::etcd::datadir::bootstrap']
  -> Class['::platform::etcd::setup']
  -> class { '::platform::etcd::init':
    service_enabled => ($::platform::params::system_mode != 'simplex'),
    bootstrap_mode  => true,
  }
  # This must happen after setup (which installs the systemd unit).
  Class['::platform::etcd::setup']
  -> File['/etc/default/etcd-fixed']
  -> exec { 'start etcd-fixed bootstrap seed':
    command => '/usr/bin/systemctl enable --now etcd-fixed',
    unless  => '/usr/bin/systemctl is-active etcd-fixed',
  }

  # For duplex/std: add the floating instance to the cluster after the
  # fixed seed is running, then start it.
  if $::platform::params::system_mode == 'duplex' or
    $::platform::params::system_type == 'Standard' {
    include ::platform::etcd::membership::bootstrap
    Exec['start etcd-fixed bootstrap seed']
    -> Class['::platform::etcd::membership::bootstrap']
    -> Service['etcd']
  }
}

# -----------------------------------------------------------------------
# platform::etcd::membership::bootstrap
#
# At bootstrap time (duplex/std only): add the floating etcd instance to
# the running fixed-0 cluster, configure it, and start the SM service.
# -----------------------------------------------------------------------
class platform::etcd::membership::bootstrap
  inherits ::platform::etcd::params {

  include ::platform::params

  # During bootstrap, use bind_address for floating and controller0_address for fixed-0
  $cluster_host_floating_address = $bind_address
  if $controller0_address {
    $cluster_host_controller0_address = $controller0_address
  } else {
    $cluster_host_controller0_address = $bind_address
  }
  notice("etcd membership::bootstrap: floating=${cluster_host_floating_address}, fixed0=${cluster_host_controller0_address}")

  if $bind_address_version == $::platform::params::ipv6 {
    $floating_peer_url = "https://[${cluster_host_floating_address}]:${peer_port}"
    $fixed0_endpoint = "https://[${cluster_host_controller0_address}]:${port}"
  } else {
    $floating_peer_url = "https://${cluster_host_floating_address}:${peer_port}"
    $fixed0_endpoint = "https://${cluster_host_controller0_address}:${port}"
  }

  # Add the floating member to the cluster via the fixed-0 endpoint
  $etcdctl_certs = '--cacert /etc/etcd/ca.crt --cert /etc/etcd/etcd-client.crt --key /etc/etcd/etcd-client.key'
  $etcdctl_base = "/usr/bin/etcdctl --endpoints ${fixed0_endpoint} ${etcdctl_certs}"

  exec { 'etcdctl member add floating at bootstrap':
    command     => "${etcdctl_base} member add ${floating_name} --learner --peer-urls=${floating_peer_url}",
    environment => ['ETCDCTL_API=3'],
    unless      => "${etcdctl_base} member list | /bin/grep -q '${floating_name}'",
    require     => Exec['start etcd-fixed bootstrap seed'],
  }
}

# -----------------------------------------------------------------------
# platform::etcd::membership
#
# Called on host-unlock. Ensures the local fixed etcd instance is registered
# in the cluster and running. Idempotent — checks member list before adding.
#
# On controller-0: fixed-0 was already started at bootstrap → no-op.
# On controller-1: fixed-1 is added to the cluster and started.
# -----------------------------------------------------------------------
class platform::etcd::membership
  inherits ::platform::etcd::params {

  include ::platform::params
  include ::platform::network::cluster_host::params

  $cluster_host_controller0_address = $::platform::network::cluster_host::params::controller0_address
  $cluster_host_controller1_address = $::platform::network::cluster_host::params::controller1_address

  if $bind_address_version == $::platform::params::ipv6 {
    $fixed0_endpoint = "https://[${cluster_host_controller0_address}]:${port}"
    $fixed1_endpoint = "https://[${cluster_host_controller1_address}]:${port}"
  } else {
    $fixed0_endpoint = "https://${cluster_host_controller0_address}:${port}"
    $fixed1_endpoint = "https://${cluster_host_controller1_address}:${port}"
  }

  if $::platform::params::hostname == 'controller-0' {
    $local_fixed_name = "${fixed_name_prefix}-0"
    $etcdctl_endpoint = $fixed0_endpoint
  } else {
    $local_fixed_name = "${fixed_name_prefix}-1"
    # Controller-1 connects to fixed-0 (the seed) to add itself
    $etcdctl_endpoint = $fixed0_endpoint
  }

  # Write the etcd-fixed env file (idempotent — uses the template).
  # Notify the service to restart if the config changes (e.g., at first
  # unlock when LISTEN addresses change from 127.0.0.1 to real IPs).
  file { '/etc/default/etcd-fixed':
    ensure  => file,
    owner   => 'root',
    group   => 'root',
    mode    => '0644',
    content => template('platform/etcd-fixed.default.erb'),
  }

  # Get the floating address for adding floating member to cluster
  $cluster_host_floating_address = $::platform::network::cluster_host::params::controller_address

  if $bind_address_version == $::platform::params::ipv6 {
    $fixed0_peer_url = "https://[${cluster_host_controller0_address}]:${peer_port}"
    $floating_peer_url = "https://[${cluster_host_floating_address}]:${peer_port}"
  } else {
    $fixed0_peer_url = "https://${cluster_host_controller0_address}:${peer_port}"
    $floating_peer_url = "https://${cluster_host_floating_address}:${peer_port}"
  }

  $etcdctl_certs = '--cacert /etc/etcd/ca.crt --cert /etc/etcd/etcd-client.crt --key /etc/etcd/etcd-client.key'
  $etcdctl_local = "/usr/bin/etcdctl --endpoints https://127.0.0.1:${port} ${etcdctl_certs}"

  # Update fixed-0's peer URL in the cluster before restarting.
  # At bootstrap, fixed-0 advertises bind_address (floating IP).
  # At unlock, we change it to the real controller-0 unit address.
  # This must happen BEFORE the service restarts with the new config.
  if $::platform::params::hostname == 'controller-0' {
    exec { 'etcdctl member update fixed-0 peer url':
      command     => "${etcdctl_local} member list -w simple | /usr/bin/awk -F', ' '/${fixed_name_prefix}-0/{print \$1}' | /usr/bin/xargs -I{} ${etcdctl_local} member update {} --peer-urls=${fixed0_peer_url}", # lint:ignore:140chars
      environment => ['ETCDCTL_API=3'],
      unless      => "${etcdctl_local} member list | /bin/grep -q '${fixed0_peer_url}'",
      require     => File['/etc/default/etcd-fixed'],
      notify      => Service[$fixed_service_name],
    }
  }

  # Do NOT start during a USM upgrade. At controller-1 unlock the peer this
  # instance must join has not been created yet -- fixed members are added at
  # activate -- so ExecStartPre would wait on an endpoint that never answers
  # and the host reboot-loops with 200.011. Activate starts the service via
  # platform::etcd::fixed::runtime, which is deliberately not gated.
  $fixed_ensure = str2bool($::usm_upgrade_in_progress) ? {
    true    => undef,
    default => running,
  }

  # Restart etcd-fixed when config changes (file notify OR member update notify)
  service { $fixed_service_name:
    ensure  => $fixed_ensure,
    enable  => str2bool($::usm_upgrade_in_progress) ? {
      true    => false,
      default => true,
    },
    require => [
      File['/etc/default/etcd-fixed'],
      File['/etc/systemd/system/etcd-fixed.service'],
    ],
  }

  # After etcd-fixed is running with real IPs, add the floating member
  # to the cluster. This must happen before floating etcd starts.
  # Only controller-0 needs to do this (controller-1 doesn't manage floating).
  if $::platform::params::hostname == 'controller-0' {
    exec { 'etcdctl member add floating':
      command     => "${etcdctl_local} member add ${floating_name} --learner --peer-urls=${floating_peer_url}",
      environment => ['ETCDCTL_API=3'],
      unless      => "${etcdctl_local} member list | /bin/grep -q '${floating_name}'",
      require     => Service[$fixed_service_name],
    }
  }
}

# -----------------------------------------------------------------------
# platform::etcd::fixed::runtime
#
# Runtime class applied by the conductor to start/restart the etcd-fixed
# service on a controller after it has been added to the cluster.
# -----------------------------------------------------------------------
class platform::etcd::fixed::runtime
  inherits ::platform::etcd::params {

  service { $fixed_service_name:
    ensure => running,
    enable => true,
  }
}

# platform::etcd::runtime
#
# Runtime class applied by the conductor on the local controller to
# update kube-apiserver etcd endpoints after the etcd cluster is formed.
class platform::etcd::runtime {
  include ::platform::kubernetes::master::change_apiserver_parameters
}

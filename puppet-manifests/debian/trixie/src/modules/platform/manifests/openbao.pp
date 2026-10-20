#
# Copyright (c) 2026 Wind River Systems, Inc.
#
# SPDX-License-Identifier: Apache-2.0
#

class platform::openbao::params (
  # service_enabled is a temporary developer gate
  $service_enabled = false,
  $data_path = '/var/lib/openbao/data',
  $luks_fs_mount = undef,
  $unseal_key_dir = 'controller/.openbao/auto-unseal',
  $unseal_key_file = 'stx-initial.key',
  $user_auth_dir = 'controller/.openbao/users',
  $cert_path = '/etc/openbao/certs',
  $luks_cert_dir = 'controller/.openbao/certs',
  $config_path = '/etc/openbao',
  $lo_addr = '127.0.0.1',
  $bind_address = undef,
  $bootstrap_listen_address = '[::]',

  # loopback_listen_addresses and mgmt_listen_addresses are lists
  $loopback_listen_addresses = ['127.0.0.1', '::1'],
  $mgmt_listen_addresses = [],
  $node_id = 'stx_raft_node_1',
  $cluster_addr_name = 'controller-0',
  $raft_peers = [],
  $initial_start = false,
  $api_port = 8200,
  $cluster_port = 8201,
  # Logging. log_level is 'trace'|'debug'|'info'|'warn'|'error'
  # NOTE: levels debug/trace may expose secrets
  $log_level = 'info',
  $log_format = 'standard',
  # NOTE: Go only applies tls_cipher_suites to TLS 1.2; TLS 1.3 uses
  # fixed ciphers and cannot be restricted
  $tls_min_version = 'tls12',
  $tls_cipher_suites = [
      'TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384',
      'TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256',
      'TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384',
      'TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256',
      'TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256',
      'TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256',
  ]
) {
  if $service_enabled and $luks_fs_mount == undef {
    fail('platform::openbao::params::luks_fs_mount is required but was not set')
  }
}

# Create required directories.
# Contains directory existence, ownership and modes, plus the LUKS-mount
# guard.
class platform::openbao::dirs
  inherits ::platform::openbao::params {

  # Data directory (mkdir -p handles parent creation)
  exec { 'create-openbao-data-dir':
    command => "/bin/mkdir -p ${data_path}",
    creates => $data_path,
  }
  -> file { $data_path:
    ensure => 'directory',
    owner  => 'openbao',
    group  => 'openbao',
    mode   => '0700',
  }

  # /etc/openbao is provided by the bao package
  # Config directory (/etc/openbao) declared before cert path
  file { $config_path:
    ensure => 'directory',
    owner  => 'openbao',
    group  => 'openbao',
    mode   => '0755',
  }

  # Certificate directory. 0750 (openbao-only): the private key file
  # is delivered by the sysinv agent as root:root 0644 and remains so
  # for ~70s until platform::openbao::certs::perms corrects it.
  -> file { $cert_path:
    ensure => 'directory',
    owner  => 'openbao',
    group  => 'openbao',
    mode   => '0750',
  }

  # Openbao directories on LUKS FS
  # Verify the encrypted LUKS filesystem is mounted before writing any
  # secrets or creating directories. The unseal key and user passwords
  # must not written to a non-encrypted filesystem
  exec { 'verify-openbao-luks-mounted':
    command => "/usr/bin/mountpoint -q ${luks_fs_mount}",
  }
  -> exec { 'create-openbao-key-dir':
    command => "/bin/mkdir -p ${luks_fs_mount}/${unseal_key_dir}",
    creates => "${luks_fs_mount}/${unseal_key_dir}",
  }
  -> exec { 'create-openbao-auth-dir':
    command => "/bin/mkdir -p ${luks_fs_mount}/${user_auth_dir}",
    creates => "${luks_fs_mount}/${user_auth_dir}",
  }
  -> exec { 'create-openbao-cert-dir':
    command => "/bin/mkdir -p ${luks_fs_mount}/${luks_cert_dir}",
    creates => "${luks_fs_mount}/${luks_cert_dir}",
  }
  -> file { "${luks_fs_mount}/${unseal_key_dir}":
    ensure => 'directory',
    owner  => 'openbao',
    group  => 'openbao',
    mode   => '0700',
  }
  # user_auth_dir must be world readable; users read user sub-dirs
  -> file { "${luks_fs_mount}/${user_auth_dir}":
    ensure => 'directory',
    owner  => 'openbao',
    group  => 'openbao',
    mode   => '0755',
  }
  -> file { "${luks_fs_mount}/${luks_cert_dir}":
    ensure => 'directory',
    owner  => 'openbao',
    group  => 'openbao',
    mode   => '0700',
  }
  -> file { "${luks_fs_mount}/${user_auth_dir}/admin":
    ensure => 'directory',
    owner  => 'openbao',
    group  => 'openbao',
    mode   => '0700',
  }
}

# Generate secrets (AES unseal key + admin password).
# Bootstrap only: these are 'initial' tasks. Secrets shared between
# controllers via rsync'd LUKS.
class platform::openbao::secrets
  inherits ::platform::openbao::params {

  # ::dirs includes LUKS mount guard
  require ::platform::openbao::dirs

  # Generate unseal key (only if not already present)
  exec { 'generate-openbao-unseal-key':
    command => "/usr/bin/openssl rand -out ${luks_fs_mount}/${unseal_key_dir}/${unseal_key_file} 32",
    creates => "${luks_fs_mount}/${unseal_key_dir}/${unseal_key_file}",
    require => File["${luks_fs_mount}/${unseal_key_dir}"],
  }
  # Enforce ownership/mode on every run (self-healing; a File resource is
  # idempotent and corrects drift, unlike an 'unless'-gated chmod).
  -> file { "${luks_fs_mount}/${unseal_key_dir}/${unseal_key_file}":
    ensure => file,
    owner  => 'openbao',
    group  => 'openbao',
    mode   => '0600',
  }

  # Generate admin password (only on initial bootstrap)
  exec { 'generate-openbao-admin-pw':
    command  => join([
        '/usr/bin/python3',
        "-c \"import sysinv.common.utils as u;",
        "print(u.generate_random_password(16), end='')\"",
        "> ${luks_fs_mount}/${user_auth_dir}/admin/pw",
    ], ' '),
    provider => 'shell',
    creates  => "${luks_fs_mount}/${user_auth_dir}/admin/pw",
    require  => File["${luks_fs_mount}/${user_auth_dir}/admin"],
  }
  # Enforce ownership/mode on every run (self-healing).
  -> file { "${luks_fs_mount}/${user_auth_dir}/admin/pw":
    ensure => file,
    owner  => 'openbao',
    group  => 'openbao',
    mode   => '0600',
  }
}

# Generate the self-signed initial certificate.
# Bootstrap only: lets openbao serve HTTPS on loopback until
# cert-manager issues the real cert
class platform::openbao::initcert
  inherits ::platform::openbao::params {

  require ::platform::openbao::dirs

  # Generate self-signed certificate for initial startup
  # The new key file is protected by directory permission
  exec { 'generate-openbao-initial-cert':
    command => join([
        '/usr/bin/openssl req -new -x509 -days 3650 -nodes',
        '-newkey ec -sha384',
        '-pkeyopt ec_paramgen_curve:secp384r1',
        "-subj '/C=US/ST=Denial/L=Springfield/O=StarlingX/CN=system-openbao'",
        "-addext 'subjectAltName=DNS:controller-0,DNS:controller,IP:127.0.0.1,IP:::1'",
        "-keyout ${cert_path}/openbao-cert-initial.key",
        "-out ${cert_path}/openbao-cert-initial.crt",
    ], ' '),
    creates => "${cert_path}/openbao-cert-initial.crt",
    require => File[$cert_path],
  }
  -> file { "${cert_path}/openbao-cert-initial.crt":
    ensure => file,
    owner  => 'openbao',
    group  => 'openbao',
    mode   => '0644',
  }
  -> file { "${cert_path}/openbao-cert-initial.key":
    ensure => file,
    owner  => 'openbao',
    group  => 'openbao',
    mode   => '0600',
  }

  # Publish a copy of the initial self-signed cert outside the
  # restricted cert dir so clients can read it during bootstrap.
  -> file { "${config_path}/openbao-cert-initial.crt":
    ensure => file,
    source => "${cert_path}/openbao-cert-initial.crt",
    owner  => 'openbao',
    group  => 'openbao',
    mode   => '0644',
  }

  # Copy, do not clobber, the self-signed pair to the bao server's HCL
  # named cert_path/openbao-cert.{crt,key}. The bao server always reads
  # openbao-cert.{crt,key}.
  -> exec { 'seed-openbao-cert-from-initial':
    command  => join([
        "/bin/cp -p ${cert_path}/openbao-cert-initial.crt",
        "${cert_path}/openbao-cert.crt",
        "&& /bin/cp -p ${cert_path}/openbao-cert-initial.key",
        "${cert_path}/openbao-cert.key",
    ], ' '),
    provider => 'shell',
    creates  => "${cert_path}/openbao-cert.crt",
    require  => [File["${cert_path}/openbao-cert-initial.crt"],
                File["${cert_path}/openbao-cert-initial.key"]],
  }
  # Enforce ownership/mode on the served cert pair (self-healing)
  -> class { '::platform::openbao::certs::perms': }
}

# Enforce ownership and mode on the served openbao cert pair
# (openbao-cert.{crt,key}).
# This class fixes owner/mode after the sysinv agent delivers the pair
# as root:root 0644
class platform::openbao::certs::perms
  inherits ::platform::openbao::params {

  file { "${cert_path}/openbao-cert.crt":
    ensure => file,
    owner  => 'openbao',
    group  => 'openbao',
    mode   => '0644',
  }
  file { "${cert_path}/openbao-cert.key":
    ensure => file,
    owner  => 'openbao',
    group  => 'openbao',
    mode   => '0600',
  }
}

# Generate the openbao configuration file
class platform::openbao::config (
  # initial_start is an explicit parameter so callers can force the
  # value for their phase: the bootstrap path passes true.
  $initial_start = $platform::openbao::params::initial_start,
) inherits ::platform::openbao::params {

  require ::platform::openbao::dirs

  if $initial_start {
    $effective_bind_address = $lo_addr
  } else {
    $effective_bind_address = $bind_address
  }

  $ciphers_list = join($tls_cipher_suites, ',')

  # The HCL config is per-host (node_id/bind_address) and not secret
  # NOTE: File[$config_path] (/etc/openbao) is declared in ::dirs
  file { "${config_path}/stx_openbao_configs.hcl":
    ensure  => file,
    owner   => 'openbao',
    group   => 'openbao',
    mode    => '0640',
    content => template('platform/openbao_configs.hcl.erb'),
    require => File[$config_path],
  }

  # Generate per-host systemd override so openbao finds the correct
  # config path on both controller-0 and controller-1
  file { '/etc/systemd/system/openbao.service.d':
    ensure => 'directory',
  }
  -> file { '/etc/systemd/system/openbao.service.d/openbao-stx-override.conf':
    ensure  => file,
    content => template('platform/openbao-stx-override.conf.erb'),
  }
  -> exec { 'openbao-systemd-daemon-reload':
    command     => '/usr/bin/systemctl daemon-reload',
    refreshonly => true,
    subscribe   => File['/etc/systemd/system/openbao.service.d/openbao-stx-override.conf'],
  }
}

# Manage the openbao systemd service.
#
# service_enabled is read from the inherited params attribute
class platform::openbao::init
  inherits ::platform::openbao::params {

  if $service_enabled {
    $service_ensure = 'running'
  } else {
    $service_ensure = 'stopped'
  }

  service { 'openbao':
    ensure => $service_ensure,
    enable => $service_enabled,
  }
}

# Early server-cert retrieval for a new controller's first unlock.
# Copy crt/key pair from luks fs
#
# On a duplex system, controller-1's first unlock must start openbao
# before sm.service, and openbao must join controller-0's raft
# (retry_join), which requires the cert-manager server leaf on disk.
# The system-local-ca is added to host trust store and luks is sync'd
# (platform::filesystem::luks) before bao puppet classes are run
class platform::openbao::early_cert
  inherits ::platform::openbao::params {

  require ::platform::openbao::dirs

  $luks_cert_path = "${luks_fs_mount}/${luks_cert_dir}"

  # Copy the server leaf from the LUKS only when it is present there
  # and not already on in cert_path.
  exec { 'retrieve-openbao-cert-from-luks':
    command  => join([
        "/bin/cp -p ${luks_cert_path}/openbao-cert.crt",
        "${cert_path}/openbao-cert.crt",
        "&& /bin/cp -p ${luks_cert_path}/openbao-cert.key",
        "${cert_path}/openbao-cert.key",
    ], ' '),
    provider => 'shell',
    onlyif   => "/usr/bin/test -f ${luks_cert_path}/openbao-cert.crt -a -f ${luks_cert_path}/openbao-cert.key",
    creates  => "${cert_path}/openbao-cert.crt",
    require  => File[$cert_path],
  }
  -> class { '::platform::openbao::certs::perms': }
}

# Main class for controller.pp / aio.pp (controller unlock).  Includes:
# create dirs, copy cert if needed at first unlock, creates bao hcl and
# systemd override files, and starts/restarts openbao if needed.
class platform::openbao
  inherits ::platform::openbao::params {

  # openbao's service_enabled is a temporary developer gate
  if $service_enabled {
    include ::platform::openbao::dirs
    include ::platform::openbao::early_cert
    include ::platform::openbao::config
    include ::platform::openbao::init

    Class['::platform::openbao::dirs']
    -> Class['::platform::openbao::early_cert']
    -> Class['::platform::openbao::config']
    -> Class['::platform::openbao::init']

    # Restart on change of the HCL or systemd override file.
    Class['::platform::openbao::config']
    ~> exec { 'restart-openbao-production':
      command     => '/usr/bin/systemctl restart openbao',
      refreshonly => true,
    }
  }
}

# Runtime reload class driven by sysinv cert-mon on a cert change.
#
# The sysinv conductor CERT_MODE_OPENBAO handler writes the new
# cert-manager pair to the fixed path cert_dir/openbao-cert.{crt,key}
#
# Reload bao with SIGHUP instead of restart; re-reads crt/key files
#
# As cert-mon provides crt signed by system-local-ca, after reload
# the initial self-signed crt/key pair is removed.
class platform::openbao::reload::runtime
  inherits ::platform::openbao::params {

  # reassert file permissions and have bao relead the cert files
  class { '::platform::openbao::certs::perms': }
  -> exec { 'reload-openbao':
    command => '/usr/bin/systemctl reload openbao',
    onlyif  => '/usr/bin/systemctl is-active --quiet openbao',
  }
  -> file { "${cert_path}/openbao-cert-initial.crt":
    ensure => absent,
  }
  -> file { "${cert_path}/openbao-cert-initial.key":
    ensure => absent,
  }
  # and also the world readable copy of self-signed cert
  -> file { "${config_path}/openbao-cert-initial.crt":
    ensure => absent,
  }
}

# Bootstrap class for initial controller-0 setup (bao-first phase). This
# is the only path that initializes secrets.
class platform::openbao::bootstrap
  inherits ::platform::openbao::params {

  include ::platform::openbao::dirs
  include ::platform::openbao::secrets
  include ::platform::openbao::initcert

  # initial_start is consumed by config (the HCL template), not by init
  # (which reads service_enabled). Set it true here.
  class { '::platform::openbao::config':
    initial_start => true,
  }

  # init reads service_enabled from inherited params
  include ::platform::openbao::init

  Class['::platform::openbao::dirs']
  -> Class['::platform::openbao::secrets']
  -> Class['::platform::openbao::initcert']
  -> Class['::platform::openbao::config']
  -> Class['::platform::openbao::init']
}

# Runtime class for config changes after deployment
class platform::openbao::runtime
  inherits ::platform::openbao::params {

  include ::platform::openbao::config

  Class['::platform::openbao::config']
  ~> exec { 'restart-openbao':
    command     => '/usr/bin/systemctl restart openbao',
    refreshonly => true,
  }
}

class platform::ldap::params (
  $admin_pw,
  $admin_hashed_pw = undef,
  $provider_uri = $::osfamily ? {
    'RedHat' => 'ldap://controller-1',
    default  => 'ldaps://controller-1',
  },
  $server_id = undef,
  $ldapserver_remote = false,
  $ldapserver_host = undef,
  $bind_anonymous = false,
  $nslcd_threads = 2,
  $nslcd_idle_timelimit = 600,
  $slapd_etc_path = $::osfamily ? {
    'RedHat' => '/etc/openldap',
    default  => '/etc/ldap',
  },
  $slapd_mod_path = $::osfamily ? {
    'RedHat' => '/usr/lib64/openldap',
    default  => '/usr/lib/ldap',
  },
  $nslcd_gid = 'ldap',
  $secure_cert = '',
  $secure_key = '',
  $ca_cert = '',
  $insecure_service = 'enabled',
) {}

class platform::ldap::server
  inherits ::platform::ldap::params {
  Class['platform::password'] -> Class[$name]

  if ! $ldapserver_remote {
    include ::platform::ldap::server::local
  }
}

class platform::ldap::server::local
  inherits ::platform::ldap::params {
  exec { 'slapd-convert-config':
    command => "/usr/sbin/slaptest -f ${slapd_etc_path}/slapd.conf -F ${slapd_etc_path}/schema/",
    onlyif  => "/usr/bin/test -e ${slapd_etc_path}/slapd.conf"
  }

  exec { 'slapd-conf-move-backup':
    command => "/bin/mv -f ${slapd_etc_path}/slapd.conf ${slapd_etc_path}/slapd.conf.backup",
    onlyif  => "/usr/bin/test -e ${slapd_etc_path}/slapd.conf"
  }

  if $::osfamily == 'RedHat' {
    service { 'nscd':
      ensure     => 'running',
      enable     => true,
      name       => 'nscd',
      hasstatus  => true,
      hasrestart => true,
    }
  }

  service { 'openldap':
    ensure     => 'running',
    enable     => true,
    name       => 'slapd',
    hasstatus  => true,
    hasrestart => true,
  }

  exec { 'stop-openldap':
    command => '/usr/bin/systemctl stop slapd.service',
  }

  exec { 'restart-openldap':
    command => '/usr/bin/systemctl restart slapd.service',
    onlyif  => "/usr/bin/test -e ${slapd_etc_path}/slapd.conf"
  }

  exec { 'configure-ldaps':
    command => "ldapmodify -D cn=config -w \"${admin_pw}\" -xH ldap:/// -f ${slapd_etc_path}/certs.ldif",
    onlyif  => ["test -e ${slapd_etc_path}/certs/openldap-cert.crt", "test -e ${slapd_etc_path}/certs/openldap-cert.key"]
  }

  exec { 'update-slapd-conf':
    command => "/bin/sed -i \\
                          -e 's#provider=ldap.*#provider=${provider_uri}#' \\
                          -e 's:serverID.*:serverID ${server_id}:' \\
                          -e 's:credentials.*:credentials=${admin_pw}:' \\
                          -e 's:^rootpw .*:rootpw ${admin_hashed_pw}:' \\
                          -e 's:modulepath .*:modulepath ${slapd_mod_path}:' \\
                          ${slapd_etc_path}/slapd.conf",
    onlyif  => "/usr/bin/test -e ${slapd_etc_path}/slapd.conf"
  }

  # don't populate the adminpw if binding anonymously
  if ! $bind_anonymous {
    file { '/etc/ldapscripts/ldapscripts.passwd':
      content => $admin_pw,
    }
  }

  if $::osfamily == 'RedHat' {
    file { '/var/cracklib':
      ensure  => 'directory',
      recurse => true,
    }
    -> file { '/var/cracklib/cracklib-small':
      ensure => link,
      target => '/usr/share/cracklib/cracklib-small.pwd',
    }
  }

  # start openldap with updated config and updated nsswitch
  # then convert slapd config to db format. Note, slapd must have run and created the db prior to this.
  if $::osfamily == 'RedHat' {
    Exec['stop-openldap']
    -> Exec['update-slapd-conf']
    -> Service['nscd']
    -> Service['nslcd']
    -> Service['openldap']
    -> Exec['slapd-convert-config']
    -> Exec['restart-openldap']
    -> class { '::platform::ldap::secure::config':}
    -> Exec['slapd-conf-move-backup']
  }
  else {
    Exec['stop-openldap']
    -> Exec['update-slapd-conf']
    -> Service['openldap']
    -> Exec['slapd-convert-config']
    -> Exec['restart-openldap']
    -> class { '::platform::ldap::secure::config': }
    -> Exec['configure-ldaps']
    -> Exec['slapd-conf-move-backup']
  }
}


class platform::ldap::client (
  $ldap_protocol = $::osfamily ? {
    'RedHat' => 'ldap',
    default  => 'ldaps',
  },
)
  inherits ::platform::ldap::params {
  include ::platform::params

  $openldap_ca_file = '/etc/pki/ca-trust/source/anchors/openldap-ca.crt'

  case $::osfamily {
    'RedHat': {
      $ca_update_cmd = 'update-ca-trust'
    }
    default: {
      $ca_update_cmd = 'update-ca-certificates --localcertsdir /etc/pki/ca-trust/source/anchors'
    }
  }

  file { "${slapd_etc_path}/ldap.conf":
      ensure  => 'present',
      replace => true,
      content => template('platform/ldap.conf.erb'),
  }

  # Create ldap configuraion for sysadmin user
  file { "${::platform::params::sysadmin_user_dir}/.ldaprc":
      ensure  => 'present',
      replace => true,
      owner   => $::platform::params::sysadmin_user_name,
      group   => $::platform::params::protected_group_name,
      content => template('platform/ldap.conf.erb'),
  }

  if $::osfamily == 'RedHat' {
    file { '/etc/nslcd.conf':
      ensure  => 'present',
      replace => true,
      content => template('platform/nslcd.conf.erb'),
    }
    -> service { 'nslcd':
      ensure     => 'running',
      enable     => true,
      name       => 'nslcd',
      hasstatus  => true,
      hasrestart => true,
    }
  }

  if $::personality == 'controller' {
    file { '/etc/ldapscripts/ldapscripts.conf':
      ensure  => 'present',
      replace => true,
      content => template('platform/ldapscripts.conf.erb'),
    }
  }

  # Install openldap CA certificate
  if (! empty($ca_cert)) {
    file { 'ldap-ca-cert':
      ensure  => present,
      path    => $openldap_ca_file,
      owner   => root,
      group   => root,
      mode    => '0644',
      content => $ca_cert,
    }
    -> exec { 'update-openldap-ca-trust':
      command => $ca_update_cmd,
    }
  }
}

class platform::ldap::client::runtime {
  include ::platform::ldap::client
}

class platform::ldap::bootstrap
  inherits ::platform::ldap::params {
  include ::platform::params
  # When ldapserver_remote is true (always the case for subclouds),
  # it is not necessary to configure the local ldap server
  if ! $ldapserver_remote {
    include ::platform::ldap::server::local
    Class['platform::ldap::server::local'] -> Class[$name]

    $dn = 'cn=ldapadmin,dc=cgcs,dc=local'
    if $::osfamily == 'RedHat' {
      $ldap_admin_group = 'root'
    }
    else {
      $ldap_admin_group = 'users'
    }

    class {'::platform::ldap::client':
      ldap_protocol => 'ldap',
    }
    -> exec { 'populate initial ldap configuration':
      command => "ldapadd -D ${dn} -w \"${admin_pw}\" -f ${slapd_etc_path}/initial_config.ldif"
    }
    -> exec { 'create ldap admin user':
      command => "ldapadduser admin ${ldap_admin_group}"
    }
    -> exec { 'create ldap operator user':
      command => 'ldapadduser operator users'
    }
    -> exec { 'create ldap protected group':
      command => "ldapaddgroup ${::platform::params::protected_group_name} ${::platform::params::protected_group_id}"
    }
    -> exec { 'add admin to sys_protected protected group' :
      command => "ldapaddusertogroup admin ${::platform::params::protected_group_name}",
    }
    -> exec { 'add operator to sys_protected protected group' :
      command => "ldapaddusertogroup operator ${::platform::params::protected_group_name}",
    }
  }
}

class platform::ldap::secure::config
  inherits ::platform::ldap::params {
  # Local ldap server configuration with SSL certificate.
  # It is applied when an openldap certificate is created or updated, during
  # application of controller manifest.

  $certs_etc_path = "${slapd_etc_path}/certs"
  if $::osfamily == 'RedHat' {
    $ldap_user = 'ldap'
    $ldap_group = 'ldap'
  }
  else {
    $ldap_user = 'openldap'
    $ldap_group = 'openldap'
  }

  if (! empty($secure_cert)) and (! empty($secure_key)) {
    file { 'ldap-cert':
      ensure  => present,
      path    => "${certs_etc_path}/openldap-cert.crt",
      owner   => $ldap_user,
      group   => $ldap_group,
      mode    => '0644',
      content => $secure_cert,
    }
    -> file { 'ldap-key':
      ensure  => present,
      path    => "${certs_etc_path}/openldap-cert.key",
      owner   => $ldap_user,
      group   => $ldap_group,
      mode    => '0644',
      content => $secure_key,
    }
  }
}

class platform::ldap::secure::runtime
  inherits ::platform::ldap::params {
  # Local ldap server configuration with SSL certificate.

  class { '::platform::ldap::secure::config':}

  -> exec { 'Restart openldap service':
    command => 'sm-restart-safe service open-ldap',
  }
}

# This class is intended to be used only at runtime to
# enable/disable ldap insecure service.
class platform::ldap::insecure::runtime
  inherits ::platform::ldap::params {
  # Enable/disable local openldap insecure service.

  $init_script = '/etc/init.d/openldap'
  if downcase($insecure_service) == 'enabled' {
    $update_cmd = "/bin/sed -i -e 's#\"ldaps:///\"#\"ldap:/// ldaps:///\"#' ${init_script}"
  }
  else {
    $update_cmd = "/bin/sed -i -e 's#\"ldap:/// ldaps:///\"#\"ldaps:///\"#' ${init_script}"
  }

  exec { 'update openldap init script':
    command => $update_cmd,
  }
  -> exec { 'Restart openldap service':
    command => 'sm-restart-safe service open-ldap',
  }
}

class platform::ldap::params (
  $admin_pw,
  $admin_hashed_pw = undef,
  $provider_uri = 'ldaps://controller-1',
  $server_id = undef,
  $ldapserver_remote = false,
  $ldapserver_host = undef,
  $bind_anonymous = false,
  $nslcd_threads = 2,
  $nslcd_idle_timelimit = 600,
  $slapd_etc_path = '/etc/ldap',
  $slapd_mod_path = '/usr/lib/ldap',
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
  file { '/tmp/slaptest':
    ensure => directory,
    mode   => '0600',
    owner  => 'root',
    group  => 'root',
  }

  exec { 'slapd-convert-config':
    command => "/usr/sbin/slaptest -f ${slapd_etc_path}/slapd.conf -F /tmp/slaptest",
    onlyif  => "/usr/bin/test -e ${slapd_etc_path}/slapd.conf"
  }

  exec { 'slapd-move-converted-config':
    command => "/bin/mv -f /tmp/slaptest/* ${slapd_etc_path}/schema",
    onlyif  => "/usr/bin/test -e ${slapd_etc_path}/slapd.conf"
  }

  exec { 'slapd-conf-move-backup':
    command => "/bin/mv -f ${slapd_etc_path}/slapd.conf ${slapd_etc_path}/slapd.conf.backup",
    onlyif  => "/usr/bin/test -e ${slapd_etc_path}/slapd.conf"
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
    timeout => 90,
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

  # TODO: Remove after stx 13 upgrade.
  # Update password policy to use ppm module attributes (pwdUseCheckModule,
  # pwdCheckModuleArg) and remove the old pwdCheckModule attribute if present.
  # This must run after slapd restarts with the new schema that defines these attributes.
  # Only needed during upgrade — on bootstrap, initial_config.ldif already has the correct values.
  if str2bool($usm_upgrade_in_progress) {
    file { '/tmp/ldap-ppm-policy-upgrade.ldif':
      source => 'puppet:///modules/platform/ldap.ppm-policy-upgrade.ldif',
    }

    file { '/tmp/ldap-ppm-policy-remove-old.ldif':
      source => 'puppet:///modules/platform/ldap.ppm-policy-remove-old.ldif',
    }

    exec { 'upgrade-ppm-policy':
      command => "ldapmodify -x -H ldap:/// -D cn=ldapadmin,dc=cgcs,dc=local -w \"${admin_pw}\" -f /tmp/ldap-ppm-policy-upgrade.ldif",
    }

    exec { 'remove-old-pwdCheckModule':
      command => "ldapmodify -x -H ldap:/// -D cn=ldapadmin,dc=cgcs,dc=local -w \"${admin_pw}\" -f /tmp/ldap-ppm-policy-remove-old.ldif",
      onlyif  => "ldapsearch -x -H ldap:/// -D cn=ldapadmin,dc=cgcs,dc=local -w \"${admin_pw}\" -b cn=default,ou=policies,dc=cgcs,dc=local -s base pwdCheckModule | grep -q 'pwdCheckModule:'",
    }

    Exec['restart-openldap']
    -> File['/tmp/ldap-ppm-policy-upgrade.ldif']
    -> Exec['upgrade-ppm-policy']
    -> File['/tmp/ldap-ppm-policy-remove-old.ldif']
    -> Exec['remove-old-pwdCheckModule']
    -> Class['platform::ldap::secure::config']
  }

  # start openldap with updated config and updated nsswitch
  # then convert slapd config to db format. Note, slapd must have run and created the db prior to this.
  Exec['stop-openldap']
  -> Exec['update-slapd-conf']
  -> Service['openldap']
  -> File['/tmp/slaptest']
  -> Exec['slapd-convert-config']
  -> Exec['slapd-move-converted-config']
  -> Exec['restart-openldap']
  -> class { '::platform::ldap::secure::config': }
  -> Exec['configure-ldaps']
  -> Exec['slapd-conf-move-backup']
}


class platform::ldap::client (
  $ldap_protocol = 'ldaps',
)
  inherits ::platform::ldap::params {
  include ::platform::params

  $openldap_ca_file = '/etc/pki/ca-trust/source/anchors/openldap-ca.crt'
  $ca_update_cmd = 'update-ca-certificates --localcertsdir /etc/pki/ca-trust/source/anchors'

  file { "${slapd_etc_path}/ldap.conf":
      ensure  => 'present',
      replace => true,
      content => template('platform/ldap.conf.erb'),
  }

  # Create ldap configuraion for sysadmin user
  file { "${::platform::params::sysadmin_user_dir}/.ldaprc":
      ensure  => 'present',
      replace => true,
      owner   => $platform::params::sysadmin_user_name,
      group   => $platform::params::protected_group_name,
      content => template('platform/ldap.conf.erb'),
  }

  if $personality == 'controller' {
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
    $ldap_admin_group = 'users'

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
  $ldap_user = 'openldap'
  $ldap_group = 'openldap'

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

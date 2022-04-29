class platform::ldap::params (
  $admin_pw,
  $admin_hashed_pw = undef,
  $provider_uri = undef,
  $server_id = undef,
  $ldapserver_remote = false,
  $ldapserver_host = undef,
  $bind_anonymous = false,
  $nslcd_threads = 2,
  $nslcd_idle_timelimit = 600,
  $slapd_etc_path = $::osfamily ? {
    'RedHat' => '/etc/openldap',
    default   => '/etc/ldap',
  },
  $slapd_mod_path = $::osfamily ? {
    'RedHat' => '/usr/lib64/openldap',
    default   => '/usr/lib/ldap',
  },
  $nslcd_gid = $::osfamily ? {
    'RedHat' => 'ldap',
    default   => 'openldap',
  },
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

  service { 'nscd':
    ensure     => 'running',
    enable     => true,
    name       => 'nscd',
    hasstatus  => true,
    hasrestart => true,
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
  Exec['stop-openldap']
  -> Exec['update-slapd-conf']
  -> Service['nscd']
  -> Service['nslcd']
  -> Service['openldap']
  -> Exec['slapd-convert-config']
  -> Exec['slapd-conf-move-backup']
  -> exec { 'restart-openldap':
    command => '/usr/bin/systemctl restart slapd.service',
  }
}


class platform::ldap::client
  inherits ::platform::ldap::params {
  file { "${slapd_etc_path}/ldap.conf":
      ensure  => 'present',
      replace => true,
      content => template('platform/ldap.conf.erb'),
  }

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

  if $::personality == 'controller' {
    file { '/etc/ldapscripts/ldapscripts.conf':
      ensure  => 'present',
      replace => true,
      content => template('platform/ldapscripts.conf.erb'),
    }
  }
}

class platform::ldap::client::runtime {
  include ::platform::ldap::client
}

class platform::ldap::bootstrap
  inherits ::platform::ldap::params {
  include ::platform::params
  # Local ldap server is configured during bootstrap. It is later
  # replaced by remote ldap server configuration (if needed) during
  # application of controller manifest.
  include ::platform::ldap::server::local
  include ::platform::ldap::client

  Class['platform::ldap::server::local'] -> Class[$name]

  $dn = 'cn=ldapadmin,dc=cgcs,dc=local'

  exec { 'populate initial ldap configuration':
    command => "ldapadd -D ${dn} -w \"${admin_pw}\" -f ${slapd_etc_path}/initial_config.ldif"
  }
  -> exec { 'create ldap admin user':
    command => 'ldapadduser admin root'
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

  # Change operator shell from default to /usr/local/bin/cgcs_cli
  -> file { '/tmp/ldap.cgcs-shell.ldif':
    ensure  => present,
    replace => true,
    source  => "puppet:///modules/${module_name}/ldap.cgcs-shell.ldif"
  }
  -> exec { 'ldap cgcs-cli shell update':
    command =>
      "ldapmodify -D ${dn} -w \"${admin_pw}\" -f /tmp/ldap.cgcs-shell.ldif"
  }
}

class platform::ldap::secure::runtime
  inherits ::platform::ldap::params {
  include ::platform::params
  # Local ldap server configuration with SSL certificate.
  # It is applied when an openldap certificate is created or updated, during
  # application of controller manifest.

  $dn = 'cn=config'
  $openldap_cert_name = 'system-openldap-local-certificate'
  $certs_etc_path = '/etc/openldap/certs'

  exec { 'populate openldap certificate':
    command => "kubectl get secret ${openldap_cert_name} -n deployment --kubeconfig=/etc/kubernetes/admin.conf \
    --template='{{ index .data \"tls.crt\" }}'|base64 -d > ${certs_etc_path}/openldap-cert.crt"
  }
  -> exec { 'populate openldap certificate key':
    command => "kubectl get secret ${openldap_cert_name} -n deployment --kubeconfig=/etc/kubernetes/admin.conf \
    --template='{{ index .data \"tls.key\" }}'|base64 -d > ${certs_etc_path}/openldap-cert.key"
  }
  -> exec { 'Set the owner and group for openldap crt and key files':
    command => "chown -R ldap:ldap ${certs_etc_path}/openldap*",
  }
  -> exec { 'ldap configuration update to enable TLS/SSL':
    command =>
      "ldapmodify -D ${dn} -w \"${admin_pw}\" -f ${slapd_etc_path}/certs.ldif"
  }
    -> exec { 'add ldaps to slapd configuration':
    command =>
      "/bin/sed -i 's,\"ldap:///\",\"ldap:/// ldaps:///\",' /etc/rc.d/init.d/openldap"
  }
    -> exec { 'restart-openldap':
    command => '/usr/bin/systemctl restart slapd.service'
  }
}

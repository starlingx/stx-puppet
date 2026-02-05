class platform::sssd::params (
  $manage_package = false,
  $manage_service = false,
  $reconnection_retries = 3,
  $services = ['nss','pam','sudo'],
  $nss_options = {},
  $pam_options = {},
  $sudo_options = {},
  $domains = {},
  $domain_name = undef,
  $ldap_uri = undef,
  $ldap_access_filter = undef,
  $ldap_search_base = undef,
  $ldap_user_search_base = undef,
  $ldap_group_search_base = undef,
  $ldap_default_bind_dn = undef,
  $ldap_default_authtok = undef,
) {}

class platform::sssd::config
  inherits ::platform::sssd::params {

  if $::osfamily == 'Debian' {
    # Generate sssd systemd override file
    $sssd_override_dir = '/etc/systemd/system/sssd.service.d'

    file { $sssd_override_dir:
      ensure => 'directory',
      owner  => 'root',
      group  => 'root',
      mode   => '0755',
    }
    -> file { "${sssd_override_dir}/sssd-stx-override.conf":
      content => template('platform/sssd.systemd.override.conf.erb'),
      owner   => 'root',
      group   => 'root',
      mode    => '0644',
    }

    # Update sssd configuration
    class { 'sssd':
      manage_package       => $manage_package,
      manage_service       => $manage_service,
      reconnection_retries => $reconnection_retries,
      services             => $services,
      nss_options          => $nss_options,
      pam_options          => $pam_options,
      sudo_options         => $sudo_options,
      domains              => $domains,
    }
  }
}

class platform::sssd
  inherits ::platform::sssd::params {

  if $::personality == 'controller' {
    Class['::platform::ldap::server'] -> Class[$name]
  }

  include ::platform::sssd::config
}

class platform::sssd::domain::runtime
  inherits ::platform::sssd::params {

  include ::platform::sssd::config

  Class['::platform::sssd::config']
  -> exec { 'restart sssd service':
    command => '/usr/local/sbin/pmon-restart sssd',
    onlyif  => "test '${::osfamily }' == 'Debian'",
  }
}

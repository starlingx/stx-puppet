class platform::sssd::params (
  $manage_package = false,
  $manage_service = false,
  $reconnection_retries = 3,
  $services = ['nss','pam'],
  $nss_options = {},
  $pam_options = {},
  $domains = {},
) {}

class platform::sssd::config
  inherits ::platform::sssd::params {

  if $::osfamily == 'Debian' {
    class { 'sssd':
      manage_package       => $manage_package,
      manage_service       => $manage_service,
      reconnection_retries => $reconnection_retries,
      services             => $services,
      nss_options          => $nss_options,
      pam_options          => $pam_options,
      domains              => $domains,
    }
  }
}

class platform::sssd
  inherits ::platform::sssd::params {

  Class['::platform::ldap::server'] -> Class[$name]

  include ::platform::sssd::config
}


class platform::haproxy::params (
  $private_ip_address,
  $public_ip_address,
  $public_address_url,
  $private_dc_ip_address = $private_ip_address,
  $enable_https = false,
  $https_ep_type = 'public',

  $global_options = undef,
  $tpm_object = undef,
  $tpm_engine = '/usr/lib64/openssl/engines/libtpm2.so',
  $public_secondary_ip_address = undef,
) { }


define platform::haproxy::proxy (
  $server_name,
  $private_port,
  $public_port,
  $public_ip_address = undef,
  $private_ip_address = undef,
  $server_timeout = undef,
  $client_timeout = undef,
  $retry_on = undef,
  $x_forwarded_proto = true,
  $enable_https = undef,
  $https_ep_type = undef,
  $public_api = true,
  $mode_option = undef,
  $acl_option = {},
  $public_secondary_ip_address = undef,
  $internal_frontend = false,
) {
  include ::platform::haproxy::params

  if $enable_https != undef {
    $https_enabled = $enable_https
  } else {
    $https_enabled = $::platform::haproxy::params::enable_https
  }

  if $https_ep_type != undef {
    $https_ep = $https_ep_type
  } else {
    $https_ep = $::platform::haproxy::params::https_ep_type
  }

  if $x_forwarded_proto {
    if $https_enabled and $public_api and $https_ep == 'public' {
        $ssl_option = 'ssl crt /etc/ssl/private/server-cert.pem'
        $proto = 'X-Forwarded-Proto:\ https'
        # The value of max-age matches lighttpd.conf, and should be
        # maintained for consistency
        $hsts_option = 'Strict-Transport-Security:\ max-age=63072000;\ includeSubDomains'
    } elsif $https_ep == 'admin' {
        $ssl_option = 'ssl crt /etc/ssl/private/admin-ep-cert.pem'
        $proto = 'X-Forwarded-Proto:\ https'
        $hsts_option = 'Strict-Transport-Security:\ max-age=63072000;\ includeSubDomains'
    } else {
      $ssl_option = ' '
      $proto = 'X-Forwarded-Proto:\ http'
      $hsts_option = undef
    }
  } else {
      $ssl_option = ' '
      $proto = undef
      $hsts_option = undef
  }

  if $public_ip_address != undef and $public_secondary_ip_address == undef {
    $public_ip = $public_ip_address
    $public_secondary_ip = undef
  } elsif $public_ip_address != undef and $public_secondary_ip_address != undef{
    $public_ip = $public_ip_address
    $public_secondary_ip = $public_secondary_ip_address
  } else {
    $public_ip = $::platform::haproxy::params::public_ip_address
    $public_secondary_ip = $::platform::haproxy::params::public_secondary_ip_address
  }

  if $private_ip_address {
    $private_ip = $private_ip_address
  } else {
    $private_ip = $::platform::haproxy::params::private_ip_address
  }

  if $client_timeout {
    $real_client_timeout = "client ${client_timeout}"
  } else {
    $real_client_timeout = undef
  }

  if $proto != undef {
    $header = regsubst($proto, ':\\\ ', ' ')
    $proto_header = "add-header ${header}"
  } else {
    $proto_header = undef
  }

  if $hsts_option != undef {
    $htst_header = regsubst($hsts_option, ':\\\ ', ' ')
    $hsts_option_header = "add-header ${htst_header}"
  } else {
    $hsts_option_header = undef
  }

  $options = {
    'default_backend' => "${name}-internal",
    'timeout'         => $real_client_timeout,
    'mode'            => $mode_option,
    'http-request'    => $proto_header,
    'http-response'   => $hsts_option_header,
  }

  $all_options = $options + $acl_option

  if $public_ip != undef and $public_secondary_ip == undef {
    haproxy::frontend { $name:
      collect_exported => false,
      name             => $name,
      bind             => {
        "${public_ip}:${public_port}" => $ssl_option,
      },
      options          => $all_options
    }
  } elsif $public_ip != undef and $public_secondary_ip != undef {
    haproxy::frontend { $name:
      collect_exported => false,
      name             => $name,
      bind             => {
        "${public_ip}:${public_port}"           => $ssl_option,
        "${public_secondary_ip}:${public_port}" => $ssl_option,
      },
      options          => $all_options
    }
  }

  if $private_ip != undef {
    if $internal_frontend {
      # If internal frontend is true, an extra frontend will be created for
      # the internal endpoint and binded to the private port.
      haproxy::frontend { "${name}-internal":
        collect_exported => false,
        name             => "${name}-internal",
        bind             => {
          "${private_ip}:${private_port}" => ' ',
        },
        options          => $all_options
      }
      # Backend port is private port plus 2 as to not collide w/ admin
      # convention (private + 1)
      $backend_port = $private_port + 2
    } else {
      $backend_port = $private_port
    }

    if $server_timeout {
      $timeout_option = "server ${server_timeout}"
    } else {
      $timeout_option = undef
    }

    haproxy::backend { $name:
      collect_exported => false,
      name             => "${name}-internal",
      options          => {
        'server'   => "${server_name} ${private_ip}:${backend_port}",
        'timeout'  => $timeout_option,
        'mode'     => $mode_option,
        'retry-on' => $retry_on
      }
    }
  }
}

define platform::haproxy::alt_backend (
  $backend_name,
  $server_name,
  $alt_private_port = undef,
  $private_ip_address = undef,
  $server_timeout = undef,
  $retry_on = undef,
  $mode_option = undef,
) {

  if $private_ip_address {
    $private_ip = $private_ip_address
  } else {
    $private_ip = $::platform::haproxy::params::private_ip_address
  }

  if $server_timeout {
    $timeout_option = "server ${server_timeout}"
  } else {
    $timeout_option = undef
  }

  haproxy::backend { $backend_name:
    collect_exported => false,
    name             => $backend_name,
    options          => {
      'server'   => "${server_name} ${private_ip}:${alt_private_port}",
      'timeout'  => $timeout_option,
      'mode'     => $mode_option,
      'retry-on' => $retry_on
    }
  }
}


class platform::haproxy::server {

  include ::platform::params
  include ::platform::haproxy::params

  # If TPM mode is enabled then we need to configure
  # the TPM object and the TPM OpenSSL engine in HAPROXY
  $tpm_object = $::platform::haproxy::params::tpm_object
  $tpm_engine = $::platform::haproxy::params::tpm_engine
  if $tpm_object != undef {
    $tpm_options = {'tpm-object' => $tpm_object, 'tpm-engine' => $tpm_engine}
    $global_options = merge($::platform::haproxy::params::global_options, $tpm_options)
  } else {
    $global_options = $::platform::haproxy::params::global_options
  }

  class { '::haproxy':
      global_options => $global_options,
  }

  user { 'haproxy':
    ensure => 'present',
    shell  => '/sbin/nologin',
    groups => [$::platform::params::protected_group_name],
  } -> Class['::haproxy']
}


class platform::haproxy::k8s_client_certificate {
  $client_pem_file = '/etc/kubernetes/pki/haproxy_client.pem'
  exec { 'Create k8s client certificate bundle':
    command => "python /usr/share/puppet/modules/platform/files/parse_k8s_admin_client_credentials.py --output_file ${client_pem_file}",  # lint:ignore:140chars
    }
}


class platform::haproxy::reload {
  platform::sm::restart {'haproxy': }
}


class platform::haproxy::runtime {
  include ::platform::haproxy::server

  include ::platform::patching::haproxy
  include ::platform::usm::haproxy
  include ::platform::sysinv::haproxy
  include ::platform::nfv::haproxy
  include ::platform::ceph::haproxy
  include ::platform::fm::haproxy
  if ($::platform::params::distributed_cloud_role == 'subcloud') {
    include ::platform::dcagent::haproxy
  }
  if ($::platform::params::distributed_cloud_role == 'systemcontroller' or
      $::platform::params::distributed_cloud_role == 'subcloud') {
    include ::platform::dcdbsync::haproxy
  }
  if $::platform::params::distributed_cloud_role =='systemcontroller' {
    include ::platform::dcmanager::haproxy
    include ::platform::dcorch::haproxy
  }
  include ::platform::docker::haproxy
  include ::openstack::keystone::haproxy
  include ::openstack::barbican::haproxy
  include ::platform::smapi::haproxy
  include ::platform::kubernetes::haproxy
}

class platform::haproxy::restart::runtime {
  class {'::platform::haproxy::reload':
    stage => post
  }
}

class platform::ejbca::params (
  $enabled = false,
  $public_url = undef,
  $public_port = 7443,
  $private_url = 'ejbca-httpd.ejbca.svc.cluster.local:443',
  $private_port = 443,
) {}

class platform::ejbca::haproxy
  inherits ::platform::ejbca::params {

  if $enabled {
    platform::haproxy::proxy { 'ejbca':
      server_name        => 's-ejbca',
      public_port        => $public_port,
      public_api         => false,
      private_ip_address => $private_url,
      private_port       => $private_port,
      x_forwarded_proto  => false,
      mode_option        => 'tcp',
    }
  }
}

class platform::ejbca {
  include ::platform::ejbca::haproxy
}

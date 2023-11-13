class platform::strongswan::params (
  $aikgen = {},
  $attest = {},
  $charon = {},
  $charon_mm = {},
  $charon_systemd = {},
  $imv_policy_manager = {},
  $libimcs = {},
  $libtls = {},
  $libtnccs = {},
  $manager = {},
  $medcli = {},
  $medsrv = {},
  $pki = {},
  $pool = {},
  $pt_tls_client = {},
  $sec_updater = {},
  $sw_collector = {},
  $starter = {},
  $swanctl = {},
  $authorities = {},
  $connections = {},
  $secrets = {},
  $pools = {},
  $strongswan_include = 'strongswan.d/*.conf',
  $charon_logging = {},
  $strongswan = {},
) {
}

class platform::strongswan::config
  inherits ::platform::strongswan::params {

  # Update strongswan configuration
  class { 'strongswan':
    charon             => $::platform::strongswan::params::strongswan,
    strongswan_include => $strongswan_include,
  }

  # Update charon_logging configuration
  -> class { '::strongswan::charon_logging':
    charon_logging => $::platform::strongswan::params::charon_logging,
  }

  # Update charon configuration
  -> class { '::strongswan::charon':
    charon_options => $::platform::strongswan::params::charon,
  }

  # Update swanctl configuration
  -> class { '::strongswan::swanctl':
    connections => $::platform::strongswan::params::swanctl,
  }

  # Restart charon
  -> exec { 'Restart charon to take updated configs':
    command => '/usr/bin/systemctl restart ipsec',
  }
}

class platform::strongswan
  inherits ::platform::strongswan::params {

  include ::platform::strongswan::config
}

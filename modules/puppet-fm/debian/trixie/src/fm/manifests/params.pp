class fm::params {

  case $facts['os']['family'] {
    'RedHat': {
      $client_package = 'python-fmclient'
      $api_package    = 'fm-rest-api'
      $api_service    = 'fm-api'
    }
    'Debian': {
      $client_package = 'python3-fmclient'
      $api_package    = 'fm-rest-api'
      $api_service    = 'fm-api'
    }
    default: {
      fail("Unsupported osfamily: ${facts['os']['family']} operatingsystem")
    }

  } # Case $facts['os']['family']

}

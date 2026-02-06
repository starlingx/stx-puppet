class platform::module::i801::params (
  $i2c_interrupts = undef,
) {}


class platform::module::i801::service::params {
  $service_name = 'i2c-i801.service'
  $service_file = "/etc/systemd/system/${service_name}"
}


define platform::module::i801::create_service (
  Array $disable_features,
  String $device_name = $title,
) {

  include platform::module::i801::service::params

  $disable_features_list = join($disable_features, ',')

  file { $platform::module::i801::service::params::service_file:
    mode    => '0644',
    owner   => 'root',
    group   => 'root',
    content => template("platform/${platform::module::i801::service::params::service_name}.erb"),
  }
  -> service { $platform::module::i801::service::params::service_name:
    ensure   => running,
    enable   => true,
    provider => systemd,
  }
  -> exec { "Enable ${platform::module::i801::service::params::service_name}":
    command  => "/usr/bin/systemctl enable ${platform::module::i801::service::params::service_name}",
    provider => shell,
  }
}


define platform::module::i801::remove_service (
  String $device_name = $title,
) {

  include platform::module::i801::service::params

  exec { "Restart ${device_name} module without disabled features":
    command => "/sbin/modprobe -r ${device_name}; /sbin/modprobe ${device_name}",
  }
  -> service { $platform::module::i801::service::params::service_name:
    enable   => false,
    provider => systemd,
  }
  -> file { $platform::module::i801::service::params::service_file:
    ensure => absent,
  }
}


class platform::module::i801
  inherits platform::module::i801::params {

  if $i2c_interrupts == 'disabled' {
    $disable_interrupts = ['0x10']
  }
  else {
    $disable_interrupts = []
  }

  $disable_features = $disable_interrupts

  if empty($disable_features) {
    platform::module::i801::remove_service { 'i2c_i801': }
  }
  else {
    platform::module::i801::create_service { 'i2c_i801':
      disable_features => $disable_features,
    }
  }
}


class platform::module::runtime {
  include ::platform::module::i801
}

class platform::tty::params (
  $enabled = false,
  $active_device = ''
) { }


class platform::tty
  inherits ::platform::tty::params {
  if $enabled {
    exec { "Enable (${active_device}) local line":
      command => "stty clocal -F /dev/${active_device}"
    }
  } else {
    exec { "Disable (${active_device}) local line":
      command => "stty -clocal -F /dev/${active_device}"
    }
  }
}


class platform::tty::runtime
  inherits ::platform::tty::params {
  include platform::tty
  exec { "Restarting serial-getty@${active_device}":
      command => "systemctl restart serial-getty@${active_device}.service"
    }
}

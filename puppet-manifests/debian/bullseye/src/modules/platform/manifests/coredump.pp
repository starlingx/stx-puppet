class platform::coredump::params (
  $process_size_max = '2G',
  $external_size_max = '2G',
  $max_use = '',
  $keep_free = '1G',
) { }

class platform::coredump
  inherits ::platform::coredump::params {

    file { '/etc/systemd/coredump.conf.d/coredump.conf':
      ensure  => 'present',
      replace => true,
      content => template('platform/coredump.conf.erb'),
    }
  }

class platform::coredump::reload {
  exec {'restart-coredump-service':
    command => 'sysctl -p /etc/sysctl.d/50-coredump.conf'
  }
}

class platform::coredump::runtime {
  include ::platform::coredump

  class {'::platform::coredump::reload':
    stage => post
  }
}

class platform::coredump::k8s_token_handler::controller {
    require platform::kubernetes::master

    exec {'create-k8s-coredump-account':
      command => 'sh /etc/k8s-coredump/create-k8s-account.sh'
    }
}

class platform::coredump::k8s_token_handler::config {
    include ::platform::params

    $sw_version = $::platform::params::software_version

    $token_file = file('/etc/k8s-coredump-conf.json','/dev/null')
    if($token_file != '') {
        exec { 'copy-k8s-coredump-token-to-config-folder':
            command => "cp /etc/k8s-coredump-conf.json /opt/platform/config/${sw_version}/k8s-coredump-conf.json",
            onlyif  => "test -d /opt/platform/config/${sw_version}"
        }
    }
}

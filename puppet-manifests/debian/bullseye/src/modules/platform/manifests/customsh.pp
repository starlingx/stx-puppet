class platform::customsh::params (
  $tmout = 900,
) {}

class platform::customsh::config
  inherits ::platform::customsh::params {

  $customsh_dir = '/etc/profile.d'
  $customsh_conf = '/etc/profile.d/custom.sh'

  file { $customsh_dir:
    ensure => directory,
    owner  => 'root',
    group  => 'root',
    mode   => '0755',
  }
  -> file { $customsh_conf:
    ensure => file,
    owner  => 'root',
    group  => 'root',
    mode   => '0644',
  }

  # Update customsh configuration
  -> file_line { 'customsh_tmout':
    path  => $customsh_conf,
    line  => "readonly TMOUT=${tmout} ; export TMOUT",
    match => '^\s*readonly\s+TMOUT=\d+.*',
  }
}

class platform::customsh::runtime
  inherits ::platform::customsh::params {

  include ::platform::customsh::config
}


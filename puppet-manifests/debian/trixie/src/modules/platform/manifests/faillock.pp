class platform::faillock::params (
  $failed_login_attempts = 5,
  $suspended_timeout = 1800,
) {}

class platform::faillock::config
  inherits ::platform::faillock::params {

  $faillock_dir = '/etc/security'
  $faillock_conf = '/etc/security/faillock.conf'

  file { $faillock_dir:
    ensure => 'directory',
    owner  => 'root',
    group  => 'root',
    mode   => '0755',
  }
  -> file { $faillock_conf:
    ensure => file,
    owner  => 'root',
    group  => 'root',
    mode   => '0644',
  }

  # Update faillock configuration
  -> file_line { 'faillock_deny':
    path  => $faillock_conf,
    line  => "deny = ${failed_login_attempts}",
    match => '^\s*deny\s*=',
  }

  -> file_line { 'faillock_unlock_time':
    path  => $faillock_conf,
    line  => "unlock_time = ${suspended_timeout}",
    match => '^\s*unlock_time\s*=',
  }
}

class platform::faillock::runtime {
  include ::platform::faillock::config
}


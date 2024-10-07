class platform::crontab {

  # Ensure /etc/crontab permissions and ownership
  file { '/etc/crontab':
    ensure => 'file',
    mode   => '0600',
    owner  => 'root',
    group  => 'root',
  }

  # Ensure /etc/cron.hourly permissions and ownership
  file { '/etc/cron.hourly':
    ensure => 'directory',
    mode   => '0700',
    owner  => 'root',
    group  => 'root',
  }

  # Ensure /etc/cron.daily permissions and ownership
  file { '/etc/cron.daily':
    ensure => 'directory',
    mode   => '0700',
    owner  => 'root',
    group  => 'root',
  }

  # Ensure /etc/cron.weekly permissions and ownership
  file { '/etc/cron.weekly':
    ensure => 'directory',
    mode   => '0700',
    owner  => 'root',
    group  => 'root',
  }

  # Ensure /etc/cron.monthly permissions and ownership
  file { '/etc/cron.monthly':
    ensure => 'directory',
    mode   => '0700',
    owner  => 'root',
    group  => 'root',
  }

  # Ensure /etc/cron.d permissions and ownership
  file { '/etc/cron.d':
    ensure  => 'directory',
    mode    => '0700',
    owner   => 'root',
    group   => 'root',
    recurse => true,
    force   => true,
    purge   => false,
  }

  # Ensure /etc/cron.allow file with 'root' user
  file { '/etc/cron.allow':
    ensure  => 'file',
    content => "root\n",
    mode    => '0600',
    owner   => 'root',
    group   => 'root',
  }

  # Ensure /etc/at.allow file is created and configured
  file { '/etc/at.allow':
    ensure  => 'file',
    mode    => '0600',
    owner   => 'root',
    group   => 'root',
    content => '',
  }
}


class platform::logpermission {

  include ::platform::params

  # Set permissions to 640 only for files with less restrictive permissions
  exec { 'set_log_permissions':
    command => 'find /var/log -type f \( -perm -004 -o -perm -020 \) -exec chmod 640 {} \;',
    path    => '/bin:/usr/bin',
    onlyif  => 'find /var/log -type f \( -perm -004 -o -perm -020 \)',
  }

  # Set permissions to 750 for directories under /var/log if not already set
  exec { 'set_log_directory_permissions':
    command => 'find /var/log -type d \( -perm -001 -o -perm -010 -o -perm -100 \) -exec chmod 750 {} \;',
    path    => '/bin:/usr/bin',
    onlyif  => 'find /var/log -type d \( -perm -001 -o -perm -010 -o -perm -100 \)',
  }

  # Change ownership to root:root for specific log files
  file { "/var/log/ceph/ceph-mds.${::platform::params::hostname}.log":
    ensure => 'file',
    owner  => 'root',
    group  => 'root',
    mode   => '0640',
  }

  file { "/var/log/ceph/ceph-mon.${::platform::params::hostname}.log":
    ensure => 'file',
    owner  => 'root',
    group  => 'root',
    mode   => '0640',
  }

  file { '/var/log/ceph/ceph-process-states.log':
    ensure => 'file',
    owner  => 'root',
    group  => 'root',
    mode   => '0640',
  }

  if $::personality == 'controller' {
    # Change ownership to root:root for specific log files
    file { '/var/log/postgresql/postgresql-13-main.log':
      ensure => 'file',
      owner  => 'root',
      group  => 'root',
      mode   => '0640',
    }

    file { '/var/log/nfv-vim-events.log':
      ensure => 'file',
      owner  => 'root',
      group  => 'root',
      mode   => '0640',
    }

    file { '/var/log/nfv-vim-alarms.log':
      ensure => 'file',
      owner  => 'root',
      group  => 'root',
      mode   => '0640',
    }

    file { "/var/log/ceph/ceph-mgr.${::platform::params::hostname}.log":
      ensure => 'file',
      owner  => 'root',
      group  => 'root',
      mode   => '0640',
    }

    file { '/var/log/ceph-manager.log':
      ensure => 'file',
      owner  => 'root',
      group  => 'root',
      mode   => '0640',
    }

    file { '/var/log/ceph/ceph-osd.0.log':
      ensure => 'file',
      owner  => 'root',
      group  => 'root',
      mode   => '0640',
    }

    file { '/var/log/ceph/ceph-osd.1.log':
      ensure => 'file',
      owner  => 'root',
      group  => 'root',
      mode   => '0640',
    }

    file { '/var/log/rabbitmq/startup_log':
      ensure => 'file',
      owner  => 'root',
      group  => 'root',
      mode   => '0640',
    }

    file { '/var/log/rabbitmq/startup_err':
      ensure => 'file',
      owner  => 'root',
      group  => 'root',
      mode   => '0640',
    }

    file { '/var/log/rabbitmq/log/':
      ensure  => 'directory',
      owner   => 'root',
      group   => 'root',
      mode    => '0755',
      recurse => true,   # Ensures subdirectories are created if missing
    }

    file { '/var/log/rabbitmq/log/crash.log':
      ensure  => 'file',
      owner   => 'root',
      group   => 'root',
      mode    => '0640',
      require => File['/var/log/rabbitmq/log/'],  # Ensures the directory exists first
    }

    file { '/var/log/rabbitmq/rabbit@localhost_upgrade.log':
      ensure => 'file',
      owner  => 'root',
      group  => 'root',
      mode   => '0640',
    }

    file { '/var/log/rabbitmq/rabbit@localhost.log':
      ensure => 'file',
      owner  => 'root',
      group  => 'root',
      mode   => '0640',
    }

    file { '/var/log/mgr-restful-plugin.log':
      ensure => 'file',
      owner  => 'root',
      group  => 'root',
      mode   => '0640',
    }

    file { '/var/log/barbican/barbican-api.log':
      ensure => 'file',
      owner  => 'root',
      group  => 'root',
      mode   => '0640',
    }

    # Use exec to change ownership for /var/log/memcached.log to avoid conflicts with other modules
    exec { 'set_memcached_log_ownership':
      command => 'chown root:root /var/log/memcached.log && chmod 640 /var/log/memcached.log',
      path    => '/bin:/usr/bin',
      onlyif  => 'stat -c "%U:%G" /var/log/memcached.log | grep -qv "root:root"',
    }
  }
}


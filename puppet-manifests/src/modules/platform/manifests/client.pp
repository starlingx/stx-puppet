class platform::client::params (
  $admin_username,
  $identity_auth_url,
  $identity_region = 'RegionOne',
  $identity_api_version = 3,
  $admin_user_domain = 'Default',
  $admin_project_domain = 'Default',
  $admin_project_name = 'admin',
  $admin_password = undef,
  $keystone_identity_region = 'RegionOne',
) { }

class platform::client
  inherits ::platform::client::params {

  include ::platform::client::credentials::params
  $keyring_file = $::platform::client::credentials::params::keyring_file

  file {'/etc/platform/openrc':
    ensure  => 'present',
    mode    => '0644',
    owner   => 'root',
    group   => 'root',
    content => template('platform/openrc.admin.erb'),
  }

  -> exec { 'change group ownership for /etc/platform/openrc':
    command => 'chgrp sys_protected /etc/platform/openrc',
    onlyif  => '/usr/bin/test -e /etc/platform/openrc'
  }

  -> file {'/etc/bash_completion.d/openstack':
    ensure  => 'present',
    mode    => '0644',
    content => generate('/usr/bin/openstack', 'complete', '-q'),
  }

  if $::personality == 'controller' {
    file {'/etc/ssl/private/openstack':
      ensure => 'directory',
      owner  => 'root',
      group  => 'root',
      mode   => '0755',
    }
  }

  exec { 'change permission for /etc/apparmor.d/':
    command => 'setfacl -m g:sys_protected:rwx /etc/apparmor.d/',
    onlyif  => '/usr/bin/test -d /etc/apparmor.d/'
  }
}

class platform::client::credentials::params (
  $keyring_base,
  $keyring_directory,
  $keyring_file,
) { }

class platform::client::credentials
  inherits ::platform::client::credentials::params {

  Class['::platform::drbd::platform']
  -> file { $keyring_base:
    ensure => 'directory',
    owner  => 'root',
    group  => 'root',
    mode   => '0755',
  }
  -> file { $keyring_directory:
    ensure => 'directory',
    owner  => 'root',
    group  => 'root',
    mode   => '0755',
  }
  -> file { $keyring_file:
    ensure  => 'file',
    owner   => 'root',
    group   => 'root',
    mode    => '0755',
    content => 'keyring get CGCS admin'
  }
}

class platform::client::bootstrap {
  include ::platform::client
  include ::platform::client::credentials
}

class platform::client::upgrade {
  include ::platform::client
}

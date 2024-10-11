class platform::users::params (
  $sysadmin_password = undef,
  $sysadmin_password_max_age = undef,
) {}


class platform::users
  inherits ::platform::users::params {

  include ::platform::params

  # Create a 'sys_protected' group for sysadmin and all openstack services
  # (including StarlingX services: sysinv, etc.).
  group { $::platform::params::protected_group_name:
    ensure => 'present',
    gid    => $::platform::params::protected_group_id,
  }

  -> user { 'sysadmin':
    ensure           => 'present',
    groups           => ['root', $::platform::params::protected_group_name],
    home             => '/home/sysadmin',
    password         => $sysadmin_password,
    password_max_age => $sysadmin_password_max_age,
    shell            => '/bin/bash',
  }

  # Create a 'denyssh' group for ldap users
  # without ssh access
  -> group { $::platform::params::deny_ssh_group_name:
    ensure => 'present',
    gid    => $::platform::params::deny_ssh_group_id,
  }

  # Create the 'sys_admin' group. This group grants full administrative
  # privileges needed to manage the StarlingX system. Members of this
  # group can perform all tasks, with the exception of those restricted
  # for security reasons.
  -> group { $::platform::params::sys_admin_group_name:
    ensure => 'present',
    gid    => $::platform::params::sys_admin_group_id,
    system => true,
  }

  # Create the 'sys_configurator' group. This group allows its members to
  # perform configuration changes on the StarlingX system. However,
  # security-related tasks (e.g., adding or deleting users) are restricted
  # to the 'sys_admin' group and cannot be performed by members of this group.
  -> group { $::platform::params::sys_configurator_group_name:
    ensure => 'present',
    gid    => $::platform::params::sys_configurator_group_id,
    system => true,
  }

  # Create the 'sys_operator' group. This group allows its members to manage
  # the operational state of the StarlingX system, such as starting and
  # stopping services, but without permission to modify system configurations.
  -> group { $::platform::params::sys_operator_group_name:
    ensure => 'present',
    gid    => $::platform::params::sys_operator_group_id,
    system => true,
  }

  # Create the 'sys_reader' group. This group provides read-only access,
  # allowing its members to view and list system information without the
  # ability to make any modifications.
  -> group { $::platform::params::sys_reader_group_name:
    ensure => 'present',
    gid    => $::platform::params::sys_reader_group_id,
    system => true,
  }
}


class platform::users::bootstrap
  inherits ::platform::users::params {

  include ::platform::params

  group { $::platform::params::protected_group_name:
    ensure => 'present',
    gid    => $::platform::params::protected_group_id,
  }

  -> user { 'sysadmin':
    ensure           => 'present',
    groups           => ['root', $::platform::params::protected_group_name],
    home             => '/home/sysadmin',
    password_max_age => $sysadmin_password_max_age,
    shell            => '/bin/bash',
  }

  # Create a 'denyssh' group for ldap users
  # without ssh access
  -> group { $::platform::params::deny_ssh_group_name:
    ensure => 'present',
    gid    => $::platform::params::deny_ssh_group_id,
  }

  # Create the 'sys_admin' group
  -> group { $::platform::params::sys_admin_group_name:
    ensure => 'present',
    gid    => $::platform::params::sys_admin_group_id,
    system => true,
  }

  # Create the 'sys_configurator' group
  -> group { $::platform::params::sys_configurator_group_name:
    ensure => 'present',
    gid    => $::platform::params::sys_configurator_group_id,
    system => true,
  }

  # Create the 'sys_operator' group
  -> group { $::platform::params::sys_operator_group_name:
    ensure => 'present',
    gid    => $::platform::params::sys_operator_group_id,
    system => true,
  }

  # Create the 'sys_reader' group
  -> group { $::platform::params::sys_reader_group_name:
    ensure => 'present',
    gid    => $::platform::params::sys_reader_group_id,
    system => true,
  }
}


class platform::users::runtime {
  include ::platform::users
}

class platform::users::upgrade {
  include ::platform::users
}


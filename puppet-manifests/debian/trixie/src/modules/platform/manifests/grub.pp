# grub manifest
class platform::grub {
  include platform::grub::security_features
  include platform::grub::kernel_image
  include platform::grub::system_mode
  include platform::grub::kernel_panic
  include platform::grub::cgroup_version
}

# update grub security feature kernel parameters
class platform::grub::security_features {
  include platform::params
  $managed_security_params = 'nopti nospectre_v2 nospectre_v1'

  exec { 'removing managed security kernel params from /boot/efi/EFI/BOOT/boot.env':
    command => "/usr/local/bin/puppet-update-grub-env.py --remove-kernelparams \"${managed_security_params}\"",
  }
  -> exec { 'adding requested security kernel params to /boot/efi/EFI/BOOT/boot.env':
    command => "/usr/local/bin/puppet-update-grub-env.py --add-kernelparams \"${platform::params::security_feature}\"",
    onlyif  => "test -n \"${platform::params::security_feature}\"",
  }
}

# Update kernel image
# based on the lowlatency configuration value
class platform::grub::kernel_image {
  include platform::sysctl::params

  if str2bool($platform::sysctl::params::low_latency) {
    exec { 'set lowlatency(real time) kernel ':
      command => '/usr/local/bin/puppet-update-grub-env.py --set-kernel-lowlatency',
    }
  }
  else {
    exec { 'set standard kernel':
      command => '/usr/local/bin/puppet-update-grub-env.py --set-kernel-standard',
    }
  }
}

# add system_mode variable to boot.env
class platform::grub::system_mode {
  include platform::params

  exec { 'Update system_mode to boot.env':
    command => "/usr/local/bin/puppet-update-grub-env.py --set-boot-variable system_mode=${platform::params::system_mode}",
  }
}

# add panic parameter to boot.env
class platform::grub::kernel_panic {
  include platform::params

  exec { 'Add kernel panic parameter to boot.env':
    command => '/usr/local/bin/puppet-update-grub-env.py --add-kernelparams panic=5',
  }
}

# runtime manifest for updating the grub kernel parameters
class platform::grub::security_features::runtime {
  include platform::grub::security_features
}

# runtime manifest for updating the kernel image
class platform::grub::kernel_image::runtime {
  include platform::grub::kernel_image
}

# Configure cgroup v2 kernel boot parameters
# When cgroup_v2_enabled is true, add unified hierarchy flag
# and remove legacy cgroup v1 controller flag.
# When false, reverse the operation to restore v1 defaults.
# Configure cgroup v2 kernel boot parameters.
# Each param is added/removed individually to avoid issues with
# puppet-update-grub-env.py matching params by key name only.
class platform::grub::cgroup_version {
  include platform::params
  notice("cgroup_v2_enabled: ${platform::params::cgroup_v2_enabled}")

  $grub_env = '/usr/local/bin/puppet-update-grub-env.py'

  # Params to add when enabling v2, remove when disabling (and vice versa).
  $v2_add_params = [
    'systemd.unified_cgroup_hierarchy=1',
    'cgroup_no_v1=all',
  ]
  $v1_add_params = [
    'systemd.unified_cgroup_hierarchy=0',
    'SYSTEMD_CGROUP_ENABLE_LEGACY_FORCE=1',
  ]

  if str2bool($platform::params::cgroup_v2_enabled) {
    # When enabling v2: remove v1 params by key, only if the v1 value
    # is currently present. Then add v2 params if not already set.
    $v1_add_params.each |$param| {
      $key = $param.split('=')[0]
      exec { "remove v1 param ${key}":
        command   => "${grub_env} --remove-kernelparams \"${key}\"",
        onlyif    => "${grub_env} --list-kernelparams | grep -qF '${param}'",
        logoutput => true,
      }
    }
    $v2_add_params.each |$param| {
      exec { "add v2 param ${param}":
        command   => "${grub_env} --add-kernelparams \"${param}\"",
        unless    => "${grub_env} --list-kernelparams | grep -qF '${param}'",
        logoutput => true,
      }
    }
  } else {
    # When enabling v1: remove v2 params by key, only if the v2 value
    # is currently present. Then add v1 params if not already set.
    $v2_add_params.each |$param| {
      $key = $param.split('=')[0]
      exec { "remove v2 param ${key}":
        command   => "${grub_env} --remove-kernelparams \"${key}\"",
        onlyif    => "${grub_env} --list-kernelparams | grep -qF '${param}'",
        logoutput => true,
      }
    }
    $v1_add_params.each |$param| {
      exec { "add v1 param ${param}":
        command   => "${grub_env} --add-kernelparams \"${param}\"",
        unless    => "${grub_env} --list-kernelparams | grep -qF '${param}'",
        logoutput => true,
      }
    }
  }
}

# runtime manifest for cgroup version kernel params
class platform::grub::cgroup_version::runtime {
  include platform::grub::cgroup_version
}

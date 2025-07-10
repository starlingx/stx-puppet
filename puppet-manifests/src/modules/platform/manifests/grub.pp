# grub manifest
class platform::grub {
  include platform::grub::security_features
  include platform::grub::kernel_image
  include platform::grub::system_mode
}

# update grub security feature kernel parameters
class platform::grub::security_features {
  include platform::params
  $managed_security_params = 'nopti nospectre_v2 nospectre_v1'

  if $::osfamily == 'RedHat' {
    # Run grubby to update params
    # First, remove all the parameters we manage, then we add back in the ones
    # we want to use
    exec { 'removing managed security kernel params from command line':
      command => "grubby --update-kernel=`grubby --default-kernel` --remove-args=\"${managed_security_params}\"",
    }
    -> exec { 'removing managed security kernel params from command line for EFI':
      command => "grubby --efi --update-kernel=`grubby --efi --default-kernel` --remove-args=\"${managed_security_params}\"",
    }
    -> exec { 'removing managed security kernel params from /etc/default/grub':
      command   => "/usr/local/bin/puppet-update-default-grub.sh --remove ${managed_security_params}",
      logoutput => true,
    }
    -> exec { 'adding requested security kernel params to command line ':
      command => "grubby --update-kernel=`grubby --default-kernel` --args=\"${platform::params::security_feature}\"",
      onlyif  => "test -n \"${platform::params::security_feature}\"",
    }
    -> exec { 'adding requested security kernel params to command line for EFI':
      command => "grubby --efi --update-kernel=`grubby --efi --default-kernel` --args=\"${platform::params::security_feature}\"",
      onlyif  => "test -n \"${platform::params::security_feature}\""
    }
    -> exec { 'adding requested security kernel params to /etc/default/grub':
      command   => "/usr/local/bin/puppet-update-default-grub.sh --add ${platform::params::security_feature}",
      logoutput => true,
      onlyif    => "test -n \"${platform::params::security_feature}\"",
    }
  } elsif($::osfamily == 'Debian') {
    exec { 'removing managed security kernel params from /boot/efi/EFI/BOOT/boot.env':
      command => "/usr/local/bin/puppet-update-grub-env.py --remove-kernelparams \"${managed_security_params}\"",
    }
    -> exec { 'adding requested security kernel params to /boot/efi/EFI/BOOT/boot.env':
      command => "/usr/local/bin/puppet-update-grub-env.py --add-kernelparams \"${platform::params::security_feature}\"",
      onlyif  => "test -n \"${platform::params::security_feature}\"",
    }
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

# runtime manifest for updating the grub kernel parameters
class platform::grub::security_features::runtime {
  include platform::grub::security_features
}

# runtime manifest for updating the kernel image
class platform::grub::kernel_image::runtime {
  include platform::grub::kernel_image
}

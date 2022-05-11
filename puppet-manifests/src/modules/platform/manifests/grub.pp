class platform::grub
{
  include ::platform::params
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
      command => "grubby --update-kernel=`grubby --default-kernel` --args=\"${::platform::params::security_feature}\"",
      onlyif  => "test -n \"${::platform::params::security_feature}\""
    }
    -> exec { 'adding requested security kernel params to command line for EFI':
      command => "grubby --efi --update-kernel=`grubby --efi --default-kernel` --args=\"${::platform::params::security_feature}\"",
      onlyif  => "test -n \"${::platform::params::security_feature}\""
    }
    -> exec { 'adding requested security kernel params to /etc/default/grub':
      command   => "/usr/local/bin/puppet-update-default-grub.sh --add ${::platform::params::security_feature}",
      logoutput => true,
      onlyif    => "test -n \"${::platform::params::security_feature}\""
    }
  } elsif($::osfamily == 'Debian') {
    exec { 'removing managed security kernel params from /boot/efi/EFI/BOOT/boot.env':
      command => "/usr/local/bin/puppet-update-grub-env.py --remove-kernelparams \"${managed_security_params}\"",
    }
    -> exec { 'adding requested security kernel params to /boot/efi/EFI/BOOT/boot.env':
      command => "/usr/local/bin/puppet-update-grub-env.py --add-kernelparams \"${::platform::params::security_feature}\"",
      onlyif  => "test -n \"${::platform::params::security_feature}\""
    }
  }
}


class platform::grub::runtime
{
  include ::platform::grub
}

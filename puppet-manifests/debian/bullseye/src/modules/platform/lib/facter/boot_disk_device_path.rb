Facter.add("boot_disk_persistent_name") do
  boot_device = Facter::Core::Execution.exec("df --output=source /boot | tail -1")
  if boot_device.include? "mpath"
    cmd = "find -L /dev/disk/by-id/dm-uuid* -samefile #{boot_device} | tail -1"
  else
    cmd = "find -L /dev/disk/by-path/ -samefile #{boot_device} | tail -1"
  end
  setcode do
    Facter::Util::Resolution.exec("#{cmd}")
  end
end

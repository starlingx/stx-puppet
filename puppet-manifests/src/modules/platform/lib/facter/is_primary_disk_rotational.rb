require 'facter'
Facter.add(:is_primary_disk_rotational) do
  rootfs_partition = Facter::Core::Execution.exec("df --output=source /boot | tail -1")
  rootfs_device = Facter::Core::Execution.exec("basename #{rootfs_partition} | sed 's/[0-9]*$//;s/p[0-9]*$//'")
  if rootfs_device.include? "mpath"
    rootfs_device = Facter::Core::Execution.exec("basename `readlink /dev/mapper/#{rootfs_device}`")
  end
  setcode "cat /sys/block/#{rootfs_device}/queue/rotational"
end

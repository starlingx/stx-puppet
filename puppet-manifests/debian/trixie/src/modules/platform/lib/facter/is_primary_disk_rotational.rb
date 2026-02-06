require 'facter'
Facter.add(:is_primary_disk_rotational) do
  boot_device = Facter::Core::Execution.exec("df --output=source /boot | tail -1 | sed 's/[0-9]*$//;s/p[0-9]*$//;s/-part[0-9]*$//'")
  resolved_boot_device = Facter::Core::Execution.exec("readlink -f #{boot_device}")
  block_device = Facter::Core::Execution.exec("basename #{resolved_boot_device}")
  setcode "cat /sys/block/#{block_device}/queue/rotational"
end

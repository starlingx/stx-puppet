# Returns true if Intel N3000 processing accelerator (FEC) device is present
# Look for vendor Intel=8086 and device N3000=0b30
Facter.add("is_n3000_present") do
  setcode do
    Facter::Core::Execution.exec('lspci -Dm -d 8086:0b30 | grep -qi accelerator')
    $?.exitstatus == 0
  end
end

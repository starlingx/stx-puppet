# Returns true if qat device 4940 and 4942 is present
Facter.add("is_qat_device_present") do
  setcode do
    Facter::Core::Execution.exec('lspci -Dm | grep -E "4940|4942"')
    $?.exitstatus == 0
  end
end

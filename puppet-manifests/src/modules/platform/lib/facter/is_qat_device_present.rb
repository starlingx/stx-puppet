# Returns true if qat device 4940, 4942 or 4946 is present
Facter.add("is_qat_device_present") do
  setcode do
    Facter::Core::Execution.exec('lspci -n | grep -E "4940|4942|4946"')
    $?.exitstatus == 0
  end
end

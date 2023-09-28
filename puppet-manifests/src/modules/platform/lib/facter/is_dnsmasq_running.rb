require 'facter'

# Returns whether dnsmasq is running on the local host
Facter.add("is_dnsmasq_running") do
    setcode do
      Facter::Core::Execution.exec("pgrep -f dnsmasq")
      $?.exitstatus == 0
    end
  end
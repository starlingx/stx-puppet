# Returns true is this is the initial config for this node

Facter.add("is_bootstrap_completed") do
  setcode do
    File.exist?('/etc/platform/.bootstrap_completed')
  end
end

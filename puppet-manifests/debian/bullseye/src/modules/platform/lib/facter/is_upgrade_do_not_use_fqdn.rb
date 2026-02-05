# Returns true is this is the initial config for this node

Facter.add("is_upgrade_do_not_use_fqdn") do
    setcode do
      File.exist?('/etc/platform/.upgrade_do_not_use_fqdn')
    end
  end
  
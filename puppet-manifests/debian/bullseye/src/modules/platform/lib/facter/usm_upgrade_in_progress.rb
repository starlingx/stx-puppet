# Returns true the USM upgrade in progress flag exists

Facter.add("usm_upgrade_in_progress") do
  setcode do
    File.exist?('/etc/platform/.usm_upgrade_in_progress')
  end
end

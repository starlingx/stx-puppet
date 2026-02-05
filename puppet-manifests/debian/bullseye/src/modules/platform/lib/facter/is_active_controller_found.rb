# Returns true if active controller found on this node

Facter.add("is_active_controller_found") do
  setcode do
    ! File.exist?('/var/run/.active_controller_not_found')
  end
end

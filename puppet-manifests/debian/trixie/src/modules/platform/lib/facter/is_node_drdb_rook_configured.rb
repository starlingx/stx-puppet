# Returns true if Rook DRBD filesystem has been configured on current node

Facter.add("is_node_drbd_rook_configured") do
  setcode do
    File.exist?('/etc/platform/.node_drbd_rook_configured')
  end
end

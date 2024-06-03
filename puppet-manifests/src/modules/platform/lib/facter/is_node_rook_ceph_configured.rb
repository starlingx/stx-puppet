# Returns true if Rook Ceph has been configured on current node

Facter.add("is_node_rook_configured") do
  setcode do
    File.exist?('/etc/platform/.node_rook_configured')
  end
end

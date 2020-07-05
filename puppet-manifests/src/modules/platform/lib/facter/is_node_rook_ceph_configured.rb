# Returns true if Rook Ceph has been configured on current node

Facter.add("is_node_rook_ceph_configured") do
  setcode do
    File.exist?('/etc/platform/.node_rook_ceph_configured')
  end
end

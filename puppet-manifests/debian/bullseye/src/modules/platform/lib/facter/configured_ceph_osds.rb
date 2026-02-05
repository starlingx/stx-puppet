Facter.add("configured_ceph_osds") do
  setcode do
    Dir.entries("/var/lib/ceph/osd").select { |osd| osd.match("ceph-.*") }
  end
end

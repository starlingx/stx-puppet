# Returns true once upgrade activate has migrated the simplex etcd data

Facter.add("etcd_upgrade_data_migrated") do
  setcode do
    File.exist?('/etc/platform/.etcd_upgrade_data_migrated')
  end
end

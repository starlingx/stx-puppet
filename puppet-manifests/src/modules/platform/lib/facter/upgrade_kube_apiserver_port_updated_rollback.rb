# Returns true the kube-apiserver port is updated during upgrade
# TODO(mdecastr): This fact is to support upgrades to stx 11, it can be removed in later releases.

Facter.add("upgrade_kube_apiserver_port_rollback") do
  setcode do
    File.exist?('/etc/platform/.upgrade_kube_apiserver_port_rollback')
  end
end

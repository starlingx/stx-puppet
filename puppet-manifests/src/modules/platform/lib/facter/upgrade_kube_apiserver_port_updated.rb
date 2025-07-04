# Returns true the kube-apiserver port is updated during upgrade

Facter.add("upgrade_kube_apiserver_port_updated") do
  setcode do
    File.exist?('/etc/platform/.upgrade_kube_apiserver_port_updated')
  end
end

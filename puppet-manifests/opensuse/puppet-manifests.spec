Name:           puppet-manifests
Version:        1.0.0
Release:        %{tis_patch_ver}%{?_tis_dist}
Summary:        Puppet Configuration and Manifests
License:        Apache-2.0
Group:          System/Packages
URL:            https://opendev.org/starlingx/config
Source0:        %{name}-%{version}.tar.gz
BuildArch:      noarch

# List all the required puppet modules

# StarlingX puppet modules
Requires: puppet-dcorch
Requires: puppet-dcmanager
Requires: puppet-mtce
Requires: puppet-nfv
Requires: puppet-patching
Requires: puppet-sysinv
Requires: puppet-sshd
Requires: puppet-smapi
Requires: puppet-fm
Requires: puppet-dcdbsync

# Openstack puppet modules
Requires: puppet-barbican
Requires: puppet-ceph
Requires: puppet-horizon
Requires: puppet-keystone
Requires: puppet-openstacklib
Requires: puppet-vswitch
Requires: puppet-memcached

# Puppetlabs puppet modules
Requires: puppet-concat
Requires: puppet-create_resources
Requires: puppet-drbd
Requires: puppet-firewall
Requires: puppet-haproxy
Requires: puppet-inifile
Requires: puppet-lvm
Requires: puppet-postgresql
Requires: puppet-rabbitmq
Requires: puppet-stdlib
Requires: puppet-sysctl
Requires: puppet-etcd

# 3rdparty puppet modules
Requires: puppet-boolean
Requires: puppet-certmonger
Requires: puppet-dnsmasq
Requires: puppet-filemapper
Requires: puppet-kmod
Requires: puppet-ldap
Requires: puppet-network
Requires: puppet-nslcd
Requires: puppet-nssdb
Requires: puppet-puppi
Requires: puppet-vlan
Requires: puppet-collectd

%description
Platform puppet configuration files and manifests

%define config_dir %{_sysconfdir}/puppet
%define module_dir %{_datadir}/puppet/modules
%define local_bindir /usr/local/bin
%define puppet_modules %{buildroot}%{_prefix}/share/puppet/modules

%prep
%setup -n %{name}-%{version}/src

%build

%install
make install \
     BINDIR=%{buildroot}%{local_bindir} \
     CONFIGDIR=%{buildroot}%{config_dir} \
     MODULEDIR=%{buildroot}%{module_dir}
# This .orig file is not allow in SUSE, and it is not critical for StarlingX functionality
rm %{puppet_modules}/platform/templates/calico.yaml.erb.orig

%files
%defattr(-,root,root,-)
%license LICENSE
%{local_bindir}
%{config_dir}
%{module_dir}
%dir %{_prefix}/share/puppet
%config %{config_dir}/* 

%changelog

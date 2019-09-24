%global module_dir  smapi

Name:           puppet-%{module_dir}
Version:        1.0.0
Release:        stx
Summary:        Puppet %{module_dir} module
License:        Apache-2.0
Group:          Development/Tools/Other
URL:            https://opendev.org/starlingx/config

Source0:        %{name}-%{version}.tar.gz
BuildArch:      noarch

BuildRequires: python2-devel

%description
A puppet module for %{module_dir}

%prep
%autosetup -q -n %{name}-%{version}/src

%build

#
# The src for this puppet module needs to be staged to puppet/modules
#
%install
make install \
     MODULEDIR=%{buildroot}%{_datadir}/puppet/modules

%files
%defattr(-,root,root,-)
%license src/LICENSE
%dir %{_datadir}/puppet
%dir %{_datadir}/puppet/modules
%{_datadir}/puppet/modules/%{module_dir}

%changelog

%global module_dir dcdbsync/

Name:           puppet-dcdbsync
Version:	1.0
Release:	1
License:	Apache-2.0
Summary:	Puppet dcdbsync module
Url:		https://opendev.org/starlingx/config
Group:		Development/Tools/Other
Source0:	%{name}-%{version}.tar.gz
BuildArch:      noarch
BuildRequires:	python2-devel

%description
A puppet module for dcorch dbsync service

%prep
%autosetup -q -n %{name}-%{version}/src

%build

%install
install -d -m 0755 %{buildroot}%{_datadir}/puppet/modules/%{module_dir}
cp -R %{module_dir} %{buildroot}%{_datadir}/puppet/modules
ls

%files
%defattr(-,root,root,-)
%{_datadir}/puppet/
%{_datadir}/puppet/modules/
%{_datadir}/puppet/modules/%{module_dir}

%changelog

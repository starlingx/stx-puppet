class platform::exports {

  include ::platform::params

  file { '/etc/exports':
    ensure => present,
    mode   => '0600',
    owner  => 'root',
    group  => 'root',
  }
  -> file_line { '/etc/exports /etc/platform':
    path  => '/etc/exports',
    line  => ($::platform::params::system_mode == 'simplex' and
              $::platform::params::system_type == 'All-in-one') ? {
                true    => "/etc/platform\t\t (no_root_squash,no_subtree_check,rw)",
                default => "/etc/platform\t\t ${::platform::params::mate_hostname}(no_root_squash,no_subtree_check,rw)",
              },
    match => '^/etc/platform\s',
  }
  -> exec { 'Re-export filesystems':
    command => 'exportfs -r',
  }
}

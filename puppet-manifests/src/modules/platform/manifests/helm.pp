class platform::helm::repositories::params(
  $source_helm_repos_base_dir = '/opt/platform/helm_charts',
  $target_helm_repos_base_dir = '/var/www/pages/helm_charts',
  $helm_repositories = [ 'stx-platform', 'starlingx' ],
) {}

define platform::helm::repository (
  $repo_base = undef,
  $repo_port = undef,
  $create = false,
  $sw_version = undef,
) {

  $repo_path = "${repo_base}/${name}"

  if str2bool($create) {
    file {$repo_path:
      ensure  => directory,
      path    => $repo_path,
      owner   => 'www',
      require => User['www'],
    }

    -> exec { "Generate index: ${repo_path}":
      command   => "helm repo index ${repo_path}",
      logoutput => true,
      user      => 'www',
      group     => 'root',
      require   => User['www'],
    }

    $before_relationship = Exec['Stop lighttpd']
    $require_relationship =  [ User['sysadmin'], Exec["Generate index: ${repo_path}"] ]
  } else {
    $before_relationship = undef
    $require_relationship =  User['sysadmin']
  }

  # Helm versions above 3.3.1 have a breaking change, where 'helm repo add' now returns an
  # error if the repo already exists (reference: https://github.com/helm/helm/issues/8771).
  # The 'force-update' flag is enough to overcome this, but it isn't backward compatible.
  # TODO(mdecastr): Cleanup once upgrade from 22.12 isn't possible (keep 'force-update')
  if $sw_version == '22.12'{
    $base_cmd = 'helm repo add'
  } else {
    $base_cmd = 'helm repo add --force-update'
  }

  exec { "Adding StarlingX helm repo: ${name}":
    before      => $before_relationship,
    environment => [ 'KUBECONFIG=/etc/kubernetes/admin.conf' , 'HOME=/home/sysadmin'],
    command     => "${base_cmd} ${name} http://127.0.0.1:${repo_port}/helm_charts/${name}",
    logoutput   => true,
    user        => 'sysadmin',
    group       => 'sys_protected',
    require     => $require_relationship
  }
}

class platform::helm::repositories
  inherits ::platform::helm::repositories::params {
  include ::openstack::horizon::params
  include ::platform::params
  include ::platform::users

  Anchor['platform::services']

  -> platform::helm::repository { $helm_repositories:
    repo_base  => $target_helm_repos_base_dir,
    repo_port  => $::openstack::horizon::params::http_port,
    create     => $::is_initial_config,
    sw_version => $::platform::params::software_version,
  }

  -> exec { 'Updating info of available charts locally from chart repo':
    environment => [ 'KUBECONFIG=/etc/kubernetes/admin.conf', 'HOME=/home/sysadmin' ],
    command     => 'helm repo update',
    logoutput   => true,
    user        => 'sysadmin',
    group       => 'sys_protected',
    require     => User['sysadmin']
  }
}

class platform::helm
  inherits ::platform::helm::repositories::params {

  include ::platform::docker::params

  file {$target_helm_repos_base_dir:
    ensure  => directory,
    path    => $target_helm_repos_base_dir,
    owner   => 'www',
    require => User['www']
  }

  Drbd::Resource <| |>

  -> file {$source_helm_repos_base_dir:
    ensure  => directory,
    path    => $source_helm_repos_base_dir,
    owner   => 'www',
    require => User['www']
  }

  if (str2bool($::is_initial_config) and $::personality == 'controller') {
    include ::platform::helm::repositories

    Class['::platform::kubernetes::gate']
    # Mitigate systemd hung behaviour for concurrent operations
    # TODO(jgauld): Remove workaround after base OS issue resolved
    -> exec { 'verify-systemd-running - helm':
      command   => '/usr/local/bin/verify-systemd-running.sh',
      logoutput => true,
    }
    -> exec { 'restart lighttpd for helm':
      require   => [File['/etc/lighttpd/lighttpd.conf', $target_helm_repos_base_dir, $source_helm_repos_base_dir]],
      command   => 'systemctl restart lighttpd.service',
      logoutput => true,
    }

    -> Class['::platform::helm::repositories']
  }
}

class platform::helm::runtime {
  include ::platform::helm::repositories
  include ::openstack::lighttpd::runtime

  Exec['sm-restart-lighttpd'] -> Class['::platform::helm::repositories']
}

class platform::ceph::params(
  $service_enabled = false,
  $skip_osds_during_restore = false,
  $cluster_uuid = undef,
  $cluster_name = 'ceph',
  $authentication_type = 'none',
  $mon_lv_name = 'ceph-mon-lv',
  $mon_lv_size = 0,
  $mon_lv_size_reserved = 20,
  $mon_fs_type = 'ext4',
  $mon_fs_options = ' ',
  $mon_mountpoint = '/var/lib/ceph/mon',
  $floating_mon_host = undef,
  $floating_mon_ip = undef,
  $floating_mon_addr = undef,
  $ceph_network='management',
  $mon_0_host = undef,
  $mon_0_ip = undef,
  $mon_0_addr = undef,
  $mon_1_host = undef,
  $mon_1_ip = undef,
  $mon_1_addr = undef,
  $mon_2_host = undef,
  $mon_2_ip = undef,
  $mon_2_addr = undef,
  $rgw_enabled = false,
  $rgw_client_name = 'radosgw.gateway',
  $rgw_user_name = 'root',
  $rgw_frontend_type = 'civetweb',
  $rgw_port = undef,
  $rgw_log_file = '/var/log/radosgw/radosgw.log',
  $rgw_service_domain = undef,
  $rgw_service_project = undef,
  $rgw_service_password = undef,
  $rgw_max_put_size = '53687091200',
  $rgw_gc_max_objs = '977',
  $rgw_gc_obj_min_wait = '600',
  $rgw_gc_processor_max_time = '300',
  $rgw_gc_processor_period = '300',
  $configure_ceph_mon_info = false,
  $simplex_to_duplex_migration = false,
  $cephfs_filesystems = {},
  $ceph_config_file = '/etc/ceph/ceph.conf',
  $node_ceph_configured_flag = '/etc/platform/.node_ceph_configured',
  $ceph_mon_reconfig_flag = '/etc/platform/.ceph_mon_reconfig_required',
  $pmond_ceph_file = '/etc/pmon.d/ceph.conf',
  $auth_id_reclaim = false,
) { }


class platform::ceph
  inherits ::platform::ceph::params {

  $system_mode = $::platform::params::system_mode
  $system_type = $::platform::params::system_type
  if $service_enabled or $configure_ceph_mon_info {
    # Set the minimum set of monitors that form a valid cluster
    if $system_type == 'All-in-one' {
      if $system_mode == 'simplex' {
        # 1 node configuration, a single monitor is available
        $mon_initial_members = $mon_0_host
        $osd_pool_default_size = 1
        if $ceph_network == 'management' {
          $mon_host = $floating_mon_addr
        } else {
          $mon_host = $mon_0_addr
        }
      } else {
        # 2 node configuration, we have a floating monitor
        $mon_initial_members = $floating_mon_host
        $osd_pool_default_size = 2
        $mon_host = "${floating_mon_addr},${mon_0_addr},${mon_1_addr}"
      }
    } else {
      # Multinode & standard, any 2 monitors form a cluster
      $mon_initial_members = undef
      $osd_pool_default_size = 2
      if $mon_2_host {
        $mon_host = "${mon_0_addr},${mon_1_addr},${mon_2_addr}"
      } else {
        $mon_host = "${mon_0_addr},${mon_1_addr}"
      }
    }

    # Update ownership/permissions for /etc/ceph/ceph.conf file.
    # We want it readable by sysinv and sysadmin.
    file { '/etc/ceph/ceph.conf':
      ensure => file,
      owner  => 'root',
      group  => $::platform::params::protected_group_name,
      mode   => '0640',
    }
    -> class { '::ceph':
      fsid                      => $cluster_uuid,
      authentication_type       => $authentication_type,
      mon_initial_members       => $mon_initial_members,
      osd_pool_default_size     => $osd_pool_default_size,
      osd_pool_default_min_size => 1,
      mon_host                  => $mon_host
    }
    -> ceph_config {
      'mon/mon clock drift allowed': value => '.1';
    }
    if $system_type == 'All-in-one' {
      # 1 and 2 node configurations have a single monitor
      if 'duplex' in $system_mode {
        # Floating monitor, running on active controller.
        Class['::ceph']
        -> ceph_config {
          "mon.${floating_mon_host}/host":          value => $floating_mon_host;
          "mon.${mon_0_host}/host":          value => $mon_0_host;
          "mon.${mon_1_host}/host":          value => $mon_1_host;
        }
      } else {
        # Simplex case, a single monitor binded to the controller.
        Class['::ceph']
        -> ceph_config {
          'mon/mon_warn_on_pool_no_redundancy':     value => false;
          "mon.${mon_0_host}/host":     value => $mon_0_host;
        }
      }
    } else {
      # Multinode & standard have 3 monitors
      Class['::ceph']
      -> ceph_config {
        "mon.${mon_0_host}/host":      value => $mon_0_host;
        "mon.${mon_1_host}/host":      value => $mon_1_host;
      }
      if $mon_2_host {
        Class['::ceph']
        -> ceph_config {
          "mon.${mon_2_host}/host":      value => $mon_2_host;
        }
      }
    }

    # Remove old, no longer in use, monitor hosts from Ceph's config file
    if $system_type == 'All-in-one' {
      if $system_mode == 'simplex' {
        $valid_monitors = [ $mon_0_host ]
      } else {
        $valid_monitors = [ $floating_mon_host, $mon_0_host, $mon_1_host ]
      }
    } else {
      $valid_monitors = [ $mon_0_host, $mon_1_host, $mon_2_host ]
    }

    $::configured_ceph_monitors.each |Integer $index, String $monitor| {
      if ! ($monitor in $valid_monitors) {
        notice("Removing ${monitor} from ${ceph_config_file}")

        # Remove all monitor settings of a section
        $mon_settings = {
          "mon.${monitor}" => {
            'public_addr' => { 'ensure' => 'absent' },
            'host'        =>  { 'ensure' => 'absent' },
            'mon_addr'    => { 'ensure' => 'absent' },
          }
        }
        $defaults = { 'path' => $ceph_config_file }
        create_ini_settings($mon_settings, $defaults)

        # Remove section header
        Ini_setting["${ceph_config_file} [mon.${monitor}] public_addr",
                    "${ceph_config_file} [mon.${monitor}] host",
                    "${ceph_config_file} [mon.${monitor}] mon_addr"]
        -> file_line { "[mon.${monitor}]":
          ensure => absent,
          path   => $ceph_config_file,
          line   => "[mon.${monitor}]"
        }
      }
    }
  }
  class { '::platform::ceph::post':
    stage => post
  }
}


class platform::ceph::post
  inherits ::platform::ceph::params {

  if $service_enabled {
    # Ceph configuration on this node is done
    file { $node_ceph_configured_flag:
      ensure  => present,
      content => '',
      owner   => 'root',
      group   => 'root',
      mode    => '0640',
    }
  }
}


class platform::ceph::pmond_config {
  file { '/etc/pmon.d/ceph.conf':
    ensure => link,
    target => '/etc/ceph/ceph.conf.pmon',
    owner  => 'root',
    group  => 'root',
    mode   => '0640',
  }
}


class platform::ceph::fixed_mon_pmond_config {
  file { '/etc/pmon.d/ceph-fixed-mon.conf':
    ensure => link,
    target => '/etc/ceph/ceph-fixed-mon.conf.pmon',
    owner  => 'root',
    group  => 'root',
    mode   => '0640',
  }
}


class platform::ceph::mds_pmond_config {
  file { '/etc/pmon.d/ceph-mds.conf':
    ensure => link,
    target => '/etc/ceph/ceph-mds.conf.pmon',
    owner  => 'root',
    group  => 'root',
    mode   => '0640',
  }
}


class platform::ceph::monitor
  inherits ::platform::ceph::params {

  $system_mode = $::platform::params::system_mode
  $system_type = $::platform::params::system_type

  if $service_enabled {
    # Check if it is necessary to reconfigure ceph mon ip due to mgmt network reconfiguration.
    $ceph_mon_ip_reconfig = find_file($ceph_mon_reconfig_flag)

    if $ceph_mon_ip_reconfig {
      if $ceph_network == 'management' {
        if $system_type == 'All-in-one' and 'simplex' in $system_mode {
          exec { 'Stop ceph-mon':
            command => '/etc/init.d/ceph-init-wrapper stop mon',
          }
          -> exec { 'Extract controller-0 monmap':
            command => 'ceph-mon -i controller-0 --extract-monmap ./monmap.bin',
          }
          -> exec { 'Remove controller-0 monmap':
            command => 'monmaptool --rm controller-0 ./monmap.bin',
          }
          -> exec { 'Add new controller-0 ip on monmap':
            command => "monmaptool --add controller-0 ${mon_0_ip} ./monmap.bin",
          }
          -> exec { 'Inject controller-0 monmap':
            command => 'ceph-mon --name mon.controller-0 --inject-monmap ./monmap.bin',
          }
        }
      }
      exec { "Remove ${ceph_mon_reconfig_flag}" :
          command => "rm -f ${ceph_mon_reconfig_flag}",
      }
    }

    if $system_type == 'All-in-one' and 'duplex' in $system_mode {

      if $::personality == 'controller' {
        # In AIO-DX, the controllers have a fixed Ceph monitor managed by pmon.
        include ::platform::ceph::fixed_mon_pmond_config
        $configure_ceph_mon = true
      } else {
        # If this is a worker node on a AIO-DX, do not configure ceph monitor
        $configure_ceph_mon = false
      }

      if str2bool($::is_controller_active) or str2bool($::is_standalone_controller) {
        # Ceph mon is configured on a DRBD partition,
        # when 'ceph' storage backend is added in sysinv.
        # Then SM takes care of starting ceph after manifests are applied.
        $configure_ceph_mon_floating = true
      } else {
        $configure_ceph_mon_floating = false

        # Ensures public_addr on controllers when mon configuration is not required.
        Class['::ceph']
        -> ceph_config {
          "mon.${floating_mon_host}/public_addr":   value => $floating_mon_ip;
        }

        if $::hostname == $mon_0_host {
          Class['::ceph']
          -> ceph_config {
            "mon.${mon_1_host}/public_addr":   value => $mon_1_ip;
          }
        }
        if $::hostname == $mon_1_host {
          Class['::ceph']
          -> ceph_config {
            "mon.${mon_0_host}/public_addr":   value => $mon_0_ip;
          }
        }
      }
    } else {
      if $::hostname == $mon_0_host or $::hostname == $mon_1_host or $::hostname == $mon_2_host {
        # This host has a Ceph mon
        $configure_ceph_mon = true
      } else {
        # This host does not have a Ceph mon
        $configure_ceph_mon = false
      }
    }
  } else {
    $configure_ceph_mon = false
  }

  if $configure_ceph_mon {
    include ::platform::filesystem::ceph::mountpoint

    if $system_type == 'All-in-one' and 'duplex' in $system_mode {

      # Hiera data will be set to enable this optional host filesystem
      # on controllers when bare-metal ceph is enabled.
      include ::platform::filesystem::ceph::runtime

      # if transition from AIO-SX to AIO-DX has started, we need to
      # wipe the logical volume before mounting DRBD
      # and remove the pmon.d managed ceph daemons
      if ($simplex_to_duplex_migration and str2bool($::is_node_ceph_configured)) {
        contain ::platform::ceph::migration::sx_to_dx::remove_mon
        include ::platform::ceph::migration::sx_to_dx::rebuild_mon

        Class['::platform::ceph::migration::sx_to_dx::remove_mon']
        -> Class['::ceph']

      } else {
        # ensure DRBD config is complete before enabling the ceph monitor
        Drbd::Resource <| |> -> Class['::ceph']
      }
    } else {
      File['/var/lib/ceph']
      -> platform::filesystem { $mon_lv_name:
        lv_name    => $mon_lv_name,
        lv_size    => $mon_lv_size,
        mountpoint => $mon_mountpoint,
        fs_type    => $mon_fs_type,
        fs_options => $mon_fs_options,
      } -> Class['::ceph']

      # Except on AIO-DX, all ceph services are managed by pmon.
      # The system uses the ceph.conf.pmon to initialize/manage all ceph services.
      include ::platform::ceph::pmond_config
    }

    # ensure configuration is complete before creating monitors
    Class['::ceph'] -> Ceph::Mon <| |>

    # ensure we load the crushmap at first unlock
    if $system_type == 'All-in-one' and str2bool($::is_standalone_controller) {
      if 'duplex' in $system_mode {
        $crushmap_txt = '/etc/sysinv/crushmap-controller-model.txt'
      } else {
        $crushmap_txt = '/etc/sysinv/crushmap-aio-sx.txt'
      }
      $crushmap_bin = '/etc/sysinv/crushmap.bin'
      $crushmap_bin_backup = '/etc/sysinv/crushmap.bin.backup'
      Ceph::Mon <| |>
      -> exec { 'Copy crushmap if backup exists':
        command => "mv -f ${crushmap_bin_backup} ${crushmap_bin}",
        onlyif  => "test -f ${crushmap_bin_backup}",
      }
      -> exec { 'Compile crushmap':
        command   => "crushtool -c ${crushmap_txt} -o ${crushmap_bin}",
        onlyif    => "test ! -f ${crushmap_bin}",
        logoutput => true,
      }
      -> exec { 'Set crushmap':
        command   => "ceph osd setcrushmap -i ${crushmap_bin}",
        unless    => 'ceph osd crush rule list --format plain | grep -e "storage_tier_ruleset"',
        logoutput => true,
      }
      -> Platform::Ceph::Platform_ceph_osd <| |>
    }

    # Ensure networking is up before Monitors are configured
    Anchor['platform::networking'] -> Ceph::Mon <| |>

    # default configuration for all ceph monitor resources
    Ceph::Mon {
      fsid => $cluster_uuid,
      authentication_type => $authentication_type,
      service_ensure => 'running'
    }

    if $system_type == 'All-in-one' and 'duplex' in $system_mode {
      if $configure_ceph_mon_floating {
        ceph::mon { $floating_mon_host:
          public_addr => $floating_mon_ip,
        }
        # On AIO-DX there is also a floating Ceph monitor backed by DRBD.
        # Therefore DRBD must be up before Ceph monitor is configured
        Drbd::Resource <| |> -> Ceph::Mon <| |>

        # If the floating monitor is being configured in the host, then
        # the fixed monitor must be started too to prevent Ceph to get unresponsive
        # when there is a reboot and there is not a three monitor quorum defined
        $fixed_mon_service_state = 'running'
      }
      else {
        # If this is the standby controller, defer the start of the fixed monitor.
        $fixed_mon_service_state = 'stopped'
      }

      if $::hostname == $mon_0_host {
        ceph::mon { $mon_0_host:
          public_addr    => $mon_0_ip,
          mon_data       => '/var/lib/ceph/data/ceph-controller-0',
          service_ensure => $fixed_mon_service_state,
        }
      }
      elsif $::hostname == $mon_1_host {
        ceph::mon { $mon_1_host:
          public_addr    => $mon_1_ip,
          mon_data       => '/var/lib/ceph/data/ceph-controller-1',
          service_ensure => $fixed_mon_service_state,
        }
      }
    } else {
      if $::hostname == $mon_0_host {
        ceph::mon { $mon_0_host:
          public_addr => $mon_0_ip,
        }
      }
      elsif $::hostname == $mon_1_host {
        ceph::mon { $mon_1_host:
          public_addr => $mon_1_ip,
        }
      }
      elsif $::hostname == $mon_2_host {
        ceph::mon { $mon_2_host:
          public_addr => $mon_2_ip,
        }
      }
    }

    # Include Pmon configuration for Ceph MDS on every host that
    # has Ceph monitor configured
    include ::platform::ceph::mds_pmond_config
  }

  # explicitly bind ceph-mgr to host-specific address
  # to avoid automatic binding of floating address
  if $::hostname == $mon_0_host {
    ceph_config{
      "mgr.${$::hostname}/public_addr": value => $mon_0_ip;
    }
  }
  elsif $::hostname == $mon_1_host {
    ceph_config{
      "mgr.${$::hostname}/public_addr": value => $mon_1_ip;
    }
  }
}

class platform::ceph::migration::sx_to_dx::remove_mon
  inherits platform::ceph::params {
  include ::platform::filesystem::params

  $vg_name = $::platform::filesystem::params::vg_name
  $drbd_device = $::platform::drbd::cephmon::params::device
  $lv_device = "/dev/${vg_name}/${mon_lv_name}"

  exec { 'Unmounting cephmon logical volume' :
    command => "umount ${mon_mountpoint}",
    onlyif  => "mountpoint -q ${mon_mountpoint}",
  }
  -> exec { "Removing auto mounting ${mon_mountpoint} from fstab" :
    command => "/bin/sed -i '/^.*${mon_lv_name}.*ext4/d' /etc/fstab",
    onlyif  => "grep -q '^.*${mon_lv_name}.*ext4' /etc/fstab",
  }
  -> exec { "wipe start of device ${lv_device}" :
    command => "dd if=/dev/zero of=${lv_device} bs=512 count=34",
    onlyif  => "blkid ${lv_device}",
  }
  -> exec { "wipe end of device ${lv_device}" :
    command => "dd if=/dev/zero of=${lv_device} bs=512 seek=$(($(blockdev --getsz ${lv_device}) - 34)) count=34",
  }
  -> exec { "remove ${pmond_ceph_file}" :
    command => "rm -f ${pmond_ceph_file}",
    onlyif  => "test -f ${pmond_ceph_file}",
  }
  -> Drbd::Resource['drbd-cephmon']
  -> file_line { 'Removing old auto mount for cephmon from fstab' :
    ensure            => absent,
    path              => '/etc/fstab',
    match             => '/var/lib/ceph/mon[[:space:]]',
    match_for_absence => true,
  }
  -> file_line { 'Adding auto mount for drbd-cephmon to fstab' :
    path => '/etc/fstab',
    line => "${drbd_device}\t${mon_mountpoint}\text4\tdefaults,noauto\t0\t0",
  }
  -> exec { 'Mount drbd-cephmon DRBD device' :
    command => "/usr/bin/mount ${mon_mountpoint}",
    unless  => "mountpoint -q ${mon_mountpoint}",
  }
}

class platform::ceph::migration::sx_to_dx::rebuild_mon
  inherits platform::ceph::params {
  # Make sure osds are provisioned
  Class['::platform::ceph::osds'] -> Class[$name]

  $mon_db_path_old = "${$mon_mountpoint}/ceph-${mon_0_host}"
  $mon_db_path_new = "${$mon_mountpoint}/ceph-${floating_mon_host}"

  exec { 'sm-unmanage service ceph-osd to rebuild store.db' :
    command => 'sm-unmanage service ceph-osd',
    onlyif  => 'test -f /var/run/goenabled',
  }
  -> exec { 'sm-unmanage service ceph-mon to rebuild store.db' :
    command => 'sm-unmanage service ceph-mon',
    onlyif  => 'test -f /var/run/goenabled',
  }
  -> exec { 'stop Ceph OSDs' :
    command => '/etc/init.d/ceph-init-wrapper stop osd'
  }
  -> exec { 'stop Ceph Monitor' :
    command => '/etc/init.d/ceph-init-wrapper stop mon.controller'
  }
  -> exec { 'Remove current ceph-controller store.db' :
    command => "rm -rf ${mon_db_path_old}/store.db",
    onlyif  => "test -d ${mon_db_path_old}/store.db"
  }

  $::configured_ceph_osds.each |Integer $index, String $osd| {
    exec { "Rebuilding monitor storage from OSD ${osd}" :
      command => "ceph-objectstore-tool --data-path /var/lib/ceph/osd/${osd} --no-mon-config\
                  --op update-mon-db --mon-store-path ${mon_db_path_new}",
      require => Exec['Remove current ceph-controller store.db'],
    }
    Exec["Rebuilding monitor storage from OSD ${osd}"] -> Exec['Add monitor information to store.db']
  }

  exec { 'Add monitor information to store.db' :
    command => "ceph-monstore-tool ${mon_db_path_new} rebuild --mon-ids ${floating_mon_host} ${mon_0_host} ${mon_1_host}",
  }
  -> exec { 'start Ceph Monitor after rebuilding monitor store' :
    command => '/etc/init.d/ceph-init-wrapper start mon.controller',
  }
  -> exec { 'start other Ceph components after rebuilding monitor store' :
    command => '/etc/init.d/ceph-init-wrapper start osd',
  }
  -> exec { 'sm-manage service ceph-osd after rebuilding monitor store' :
    command => 'sm-manage service ceph-osd',
    onlyif  => 'test -f /var/run/goenabled',
  }
  -> exec { 'sm-manage service ceph-mon after rebuilding monitor store' :
    command => 'sm-manage service ceph-mon',
    onlyif  => 'test -f /var/run/goenabled',
  }

  class { 'platform::ceph::migration::sx_to_dx::active_cluster_updates' :
    stage => post,
  }
}

class platform::ceph::migration::sx_to_dx::active_cluster_updates
  inherits platform::ceph::params {

  exec { 'Ensure Fixed Ceph Monitor is running' :
    command => "/etc/init.d/ceph start mon.${$::hostname}",
  }
  -> exec { 'Ensure Floating Ceph Monitor is running' :
    command => '/etc/init.d/ceph start mon.controller',
  }
  -> exec { 'Ensure Ceph OSDs are running' :
    command => '/etc/init.d/ceph start osd',
  }
  -> exec { 'Ensure Ceph mds is stoped':
    command => '/etc/init.d/ceph stop mds'
  }

  $cephfs_filesystems.each |String $fs, Array $pools| {
    $metadada_pool = $pools[0]
    $data_pool = $pools[1]

    exec { "Rebuilding cephfs filesystem ${fs}" :
      command => "ceph fs new ${fs} ${metadada_pool} ${data_pool} --force",
      require => Exec['Ensure Ceph mds is stoped'],
    }
    -> exec { "Reset cephfs filesystem ${fs}" :
      command => "ceph fs reset ${fs} --yes-i-really-mean-it",
    }

    Exec["Reset cephfs filesystem ${fs}"] -> Exec['Ensure Ceph mds is re-started']
  }

  exec { 'Ensure Ceph mds is re-started':
    command => '/etc/init.d/ceph start mds'
  }
  -> exec { 'Update crushmap to support DX' :
    command => template('platform/ceph_crushmap_add_controller1_bucket.erb'),
  }
}

class platform::ceph::metadataserver::config
  inherits ::platform::ceph::params {
  if $::hostname == $mon_0_host {
        Class['::ceph']
          -> ceph_config {
            "mds.${$::hostname}/host": value => $mon_0_host;
            "mds.${$::hostname}/public_addr": value => $mon_0_ip;
          }
    }
  if $::hostname == $mon_1_host {
        Class['::ceph']
          -> ceph_config {
            "mds.${$::hostname}/host": value => $mon_1_host;
            "mds.${$::hostname}/public_addr": value => $mon_1_ip;
          }
    }
  if $::hostname == $mon_2_host {
        Class['::ceph']
          -> ceph_config {
            "mds.${$::hostname}/host": value => $mon_2_host;
            "mds.${$::hostname}/public_addr": value => $mon_2_ip;
          }
    }
  }

class platform::ceph::metadataserver::controller::runtime
  inherits ::platform::ceph::params {

  include ::platform::ceph::metadataserver::config

  if $::personality == 'controller' {
    include ::platform::sm::ceph::runtime

    # Make sure the metadata config is added before starting services
    Class['::platform::ceph::metadataserver::config'] -> Class[$name]

    # Make sure the ceph SM services are provisioned
    Class['::platform::sm::ceph::runtime'] -> Class[$name]
  }
}

class platform::ceph::metadataserver::worker::runtime
  inherits ::platform::ceph::params {

  include ::platform::ceph::metadataserver::config
  if $::personality == 'worker' {
    if $::hostname == $mon_0_host or $::hostname == $mon_1_host or $::hostname == $mon_2_host {
      # Worker with a monitor assigned:

      # Make sure the metadata config and monitor is added before starting services
      Class['::platform::ceph::monitor'] -> Class[$name]
      Class['::platform::ceph::metadataserver::config'] -> Class[$name]
    }
  }
}

class platform::ceph::metadataserver::runtime {
  include ::platform::ceph::metadataserver::controller::runtime
  include ::platform::ceph::metadataserver::worker::runtime
}

define platform::ceph::osd_crush_location(
  $osd_id,
  $osd_uuid,
  $disk_path,
  $data_path,
  $journal_path,
  $tier_name,
) {
  # Only set the crush location for additional tiers
  if $tier_name != 'storage' {
    ceph_config {
      "osd.${$osd_id}/host":           value => "${$::platform::params::hostname}-${$tier_name}";
      "osd.${$osd_id}/crush_location": value => "root=${tier_name}-tier host=${$::platform::params::hostname}-${$tier_name}";
    }
  }
}

define platform::ceph::osd_location(
  $osd_id,
  $osd_uuid,
  $disk_path,
  $data_path,
  $journal_path,
  $tier_name,
) {
  ceph_config {
    "osd.${$osd_id}/devs": value => $data_path;
  }
}

define platform::ceph::platform_ceph_osd(
  $osd_id,
  $osd_uuid,
  $disk_path,
  $data_path,
  $journal_path,
  $tier_name,
) {

  # If journal path is substring of disk path, it is collocated journal,
  # otherwise it is external journal. In external journal case, class ceph::osd
  # request journal path as argument for ceph osd initializaiton
  if $disk_path in $journal_path {
    $journal = ''
  } elsif 'mpath-' in $disk_path {
    $disk_path_array = split($disk_path, 'mpath-')
    if $disk_path_array[1] in $journal_path {
      $journal = ''
    }
  } else {
    $journal = $journal_path
  }

  Anchor['platform::networking']  # Make sure networking is up before running ceph commands
  -> file { "/var/lib/ceph/osd/ceph-${osd_id}":
    ensure => 'directory',
    owner  => 'root',
    group  => 'root',
    mode   => '0755',
  }
  -> exec { "ceph osd create ${osd_uuid} ${osd_id}":
    logoutput => true,
    command   => template('platform/ceph.osd.create.erb'),
  }
  -> ceph::osd { $disk_path:
    uuid    => $osd_uuid,
    osdid   => $osd_id,
    journal => $journal,
  }
  -> exec { "configure journal location ${name}":
    logoutput => true,
    command   => template('platform/ceph.journal.location.erb')
  }
}


define platform::ceph::platform_ceph_journal(
  $disk_path,
  $journal_sizes,
) {
  exec { "configure journal partitions ${name}":
    logoutput => true,
    command   => template('platform/ceph.journal.partitions.erb')
  }
}


class platform::ceph::osds(
  $osd_config = {},
  $journal_config = {},
) inherits ::platform::ceph::params {

  # skip_osds_during_restore is set to true when the default primary
  # ceph backend "ceph-store" has "restore" as its task and it is
  # not an AIO system.
  if ! $skip_osds_during_restore and $service_enabled {
    file { '/var/lib/ceph/osd':
      ensure => 'directory',
      path   => '/var/lib/ceph/osd',
      owner  => 'root',
      group  => 'root',
      mode   => '0755',
    }

    # Ensure ceph.conf is complete before configuring OSDs
    Class['::ceph'] -> Platform::Ceph::Platform_ceph_osd <| |>

    # Journal disks need to be prepared before the OSDs are configured
    Platform::Ceph::Platform_ceph_journal <| |> -> Platform::Ceph::Platform_ceph_osd <| |>
    # Crush locations in ceph.conf need to be set before the OSDs are configured
    Platform::Ceph::Osd_crush_location <| |> -> Platform::Ceph::Platform_ceph_osd <| |>

    # default configuration for all ceph object resources
    Ceph::Osd {
      cluster => $cluster_name,
      cluster_uuid => $cluster_uuid,
    }

    create_resources('platform::ceph::osd_crush_location', $osd_config)
    create_resources('platform::ceph::platform_ceph_osd', $osd_config)
    create_resources('platform::ceph::platform_ceph_journal', $journal_config)
  }

  # Ensure ceph.conf is created
  Class['::ceph'] -> Platform::Ceph::Osd_location <| |>

  # Update ceph.conf with OSDs present on the node
  create_resources('platform::ceph::osd_location', $osd_config)
}

class platform::ceph::haproxy
  inherits ::platform::ceph::params {

  if $rgw_enabled {
    platform::haproxy::proxy { 'ceph-radosgw-restapi':
      server_name  => 's-ceph-radosgw',
      public_port  => $rgw_port,
      private_port => $rgw_port,
    }
  }
}

class platform::ceph::rgw::keystone (
  $swift_endpts_enabled = false,
  $rgw_admin_domain = undef,
  $rgw_admin_project = undef,
  $rgw_admin_user = 'swift',
  $rgw_admin_password = undef,
) inherits ::platform::ceph::params {
  include ::openstack::keystone::params
  if $rgw_enabled {

    if $swift_endpts_enabled {
      $url = $::openstack::keystone::params::openstack_auth_uri
    } else {
      $url = $::openstack::keystone::params::auth_uri
    }

    ceph::rgw::keystone { $rgw_client_name:
      # keystone admin token is disabled after initial keystone configuration
      # for security reason. Use keystone service tenant credentials instead.
      rgw_keystone_admin_token         => '',
      rgw_keystone_url                 => $url,
      rgw_keystone_version             => $::openstack::keystone::params::api_version,
      rgw_keystone_accepted_roles      => 'admin,_member_',
      user                             => $rgw_user_name,
      use_pki                          => false,
      rgw_keystone_revocation_interval => 0,
      rgw_keystone_token_cache_size    => 0,
      rgw_keystone_admin_domain        => $rgw_admin_domain,
      rgw_keystone_admin_project       => $rgw_admin_project,
      rgw_keystone_admin_user          => $rgw_admin_user,
      rgw_keystone_admin_password      => $rgw_admin_password,
    }
  }
}


class platform::ceph::rgw
  inherits ::platform::ceph::params {
  include ::ceph::params
  include ::ceph::profile::params

  if $rgw_enabled {
    include ::platform::params

    include ::openstack::keystone::params
    $auth_host = $::openstack::keystone::params::host_url

    ceph::rgw { $rgw_client_name:
      user          => $rgw_user_name,
      frontend_type => $rgw_frontend_type,
      rgw_frontends => "${rgw_frontend_type} port=${auth_host}:${rgw_port}",
      # service is managed by SM
      rgw_enable    => false,
      rgw_ensure    => false,
      # The location of the log file shoule be the same as what's specified in
      # /etc/logrotate.d/radosgw in order for log rotation to work properly
      log_file      => $rgw_log_file,
    }

    include ::platform::ceph::rgw::keystone

    ceph_config {
      # increase limit for single operation uploading to 50G (50*1024*1024*1024)
      "client.${rgw_client_name}/rgw_max_put_size": value => $rgw_max_put_size;
      # increase frequency and scope of garbage collection
      "client.${rgw_client_name}/rgw_gc_max_objs": value => $rgw_gc_max_objs;
      "client.${rgw_client_name}/rgw_gc_obj_min_wait": value => $rgw_gc_obj_min_wait;
      "client.${rgw_client_name}/rgw_gc_processor_max_time": value => $rgw_gc_processor_max_time;
      "client.${rgw_client_name}/rgw_gc_processor_period": value => $rgw_gc_processor_period;
    }
  }

  include ::platform::ceph::haproxy
}

class platform::ceph::worker {
  if $::personality == 'worker' {
    include ::platform::ceph
    include ::platform::ceph::monitor
    include ::platform::ceph::metadataserver::config
  }
}

class platform::ceph::storage {
    include ::platform::ceph
    include ::platform::ceph::monitor
    include ::platform::ceph::metadataserver::config
    include ::platform::ceph::osds
    # Ensure ceph is managed by pmond on all storage nodes
    include ::platform::ceph::pmond_config

    # Ensure partitions update prior to ceph storage configuration
    Class['::platform::partitions'] -> Class['::platform::ceph::osds']
}

class platform::ceph::controller {
    include ::platform::ceph
    include ::platform::ceph::monitor
    include ::platform::ceph::metadataserver::config

    # is_active_controller_found is checking the existence of
    # /var/run/.active_controller_not_found, which will be created
    # by /etc/init.d/controller_config if it couldn't detect an active
    # controller. This will be the case for DOR (Dead Office Recovery),
    # during which both controllers are booting up thus there is no
    # active controller. The ceph::osds class has to be skipped in this
    # case otherwise it will fail for not being able to find ceph monitor
    # cluster.
    if str2bool($::is_active_controller_found) {
      include ::platform::ceph::osds

      # Ensure partitions update prior to ceph storage configuration
      Class['::platform::partitions'] -> Class['::platform::ceph::osds']
    }
}

class platform::ceph::runtime_base {
  include ::platform::ceph::monitor
  include ::platform::ceph::metadataserver::runtime
  include ::platform::ceph

  $system_mode = $::platform::params::system_mode
  $system_type = $::platform::params::system_type

  if $::personality == 'controller' {
    if $system_type == 'All-in-one' and 'duplex' in $system_mode {
      Drbd::Resource <| |> -> Class[$name]
    }
    Class[$name] -> Class['::platform::sm::ceph::runtime']
  }

  # Start Ceph processes when the ceph storage backend is configured
  # at runtime. This is needed because mtcClient will not call the
  # ceph.sh script.
  class { '::platform::ceph::start_ceph':
    stage => post,
  }
}

class platform::ceph::start_ceph {
  include ::platform::ceph::post

  Class['::platform::ceph::post']
  -> exec { 'Start ceph processes':
    command => "/etc/services.d/${::personality}/ceph.sh start",
  }
}

class platform::ceph::runtime_osds {
  include ::ceph::params
  include ::platform::ceph
  include ::platform::ceph::osds

  # Since this is runtime we have to avoid checking status of Ceph while we
  # configure it. On AIO-DX ceph-osd processes are monitored by SM & on other
  # deployments they are pmon managed.
  $system_mode = $::platform::params::system_mode
  $system_type = $::platform::params::system_type

  if $system_type == 'All-in-one' and 'duplex' in $system_mode {
    exec { 'sm-unmanage service ceph-osd':
      command => 'sm-unmanage service ceph-osd'
    }
    -> Class['::platform::ceph::osds']
    -> exec { 'start Ceph OSDs':
      command => '/etc/init.d/ceph-init-wrapper start osd'
    }
    -> exec { 'sm-manage service ceph-osd':
      command => 'sm-manage service ceph-osd'
    }
  } else {
    include ::platform::ceph::pmond_config

    exec { 'remove /etc/pmon.d/ceph.conf':
      command => 'rm -f /etc/pmon.d/ceph.conf'
    }
    -> Class['::platform::ceph::osds']
    -> exec { 'start Ceph OSDs':
      command => '/etc/init.d/ceph-init-wrapper start osd'
    }
    -> Class['::platform::ceph::pmond_config']
  }
}

# Used to configure optional radosgw platform service
class platform::ceph::rgw::runtime
  inherits ::platform::ceph::params {

  include platform::ceph::rgw

  # Make sure the ceph configuration is complete before sm dynamically
  # provisions/deprovisions the service
  Class[$name] -> Class['::platform::sm::rgw::runtime']

  unless $rgw_enabled {
    # SM's current behavior will not stop the service being de-provisioned, so
    # stop it when needed
    exec { 'Stopping ceph-radosgw service':
      command => '/etc/init.d/ceph-radosgw stop'
    }
  }
}

# Used to configure radosgw keystone info based on containerized swift endpoints
# being enabled/disabled
class platform::ceph::rgw::keystone::runtime
  inherits ::platform::ceph::params {

  include ::platform::ceph::rgw::keystone

  exec { 'sm-restart-safe service ceph-radosgw':
    command => 'sm-restart-safe service ceph-radosgw'
  }
}

class platform::ceph::mon::runtime
  inherits ::platform::ceph::params {

  if $service_enabled {

    ceph_config {
      'mon/mon warn on insecure global id reclaim':         value => !$auth_id_reclaim;
      'mon/mon warn on insecure global id reclaim allowed': value => !$auth_id_reclaim;
      'mon/auth allow insecure global id reclaim':          value => $auth_id_reclaim;
    } -> exec { "Change allow insecure global id reclaim to ${auth_id_reclaim}":
          command => "ceph tell mon.* injectargs '--mon_warn_on_insecure_global_id_reclaim=${!$auth_id_reclaim}';\
                      ceph tell mon.* injectargs '--mon_warn_on_insecure_global_id_reclaim_allowed=${!$auth_id_reclaim}';\
                      ceph tell mon.* injectargs '--auth_allow_insecure_global_id_reclaim=${auth_id_reclaim}'"
    }
  }
}


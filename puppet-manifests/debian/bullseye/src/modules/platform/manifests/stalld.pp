class platform::stalld::params (

  $config_file        = '/etc/default/stalld',    # Configuration file path
  $package_name       = 'stalld',                 # Package name
  $package_version    = '1.19.6',                 # Package version

  $enable             = false,                    # Enable or disable stalld

  $cpu_list           = undef,                    # List of CPUs to monitor (-c)

  # Logging options
  $log_only           = false,                    # Only log, do not boost (--log_only)
  $verbose            = false,                    # Log to std output (--verbose)
  $log_kmsg           = false,                    # Log to kernel buffer (--log_kmsg)
  $log_syslog         = true,                     # Log to syslog (--log_syslog)

  $foreground         = true,                     # Run in foreground [implicit when --verbose] (--foreground)

  # Boosting options
  $boost_period       = 1000000000,               # Deadline period (ns) (--boost_period)
  $boost_runtime      = 20000,                    # Deadline runtime (ns) (--boost_runtime)
  $boost_duration     = 1,                        # Boost duration (s) (--boost_duration)
  $force_fifo         = false,                    # Use SCHED_FIFO instead of SCHED_DEADLINE (--force_fifo)

  # Monitoring options
  $starving_threshold = 2,                      # Time (s) before a thread is considered starving (--starving_threshold)
  $aggressive_mode    = false,                  # Dispatch a thread per run queue (--aggressive_mode)
  $adaptive_mode      = false,                  # Dispatch a specialized thread to monitor starving threads(--adaptive_mode)
  $power_mode         = false,                  # Work as single thread, saves cpu but loss in precision(--power_mode)
  $granularity        = undef,                  # set the granularity (s) at which stalld checks for starving threads(--granularity)
  $reservation        = undef,                  # percentage of CPU time reserved to stalld using SCHED_DEADLINE(--reservation)
  $affinity           = undef,                  # limit stalld's affinity to specific cpus (--affinity)

  # Extra
  $ignore_threads    = undef,                   # regexes (comma-separated) of thread names that must be ignored(--ignore_threads)
  $ignore_processes  = undef,                   # regexes (comma-separated) of process names that must be ignored (--ignore_processes)
  $backend           = undef,                   # Select backend (sched_debug, queue_track) (--backend)

  # Misc
  $pidfile          = '/run/stalld/stalld.pid', # Path to PID file (--pidfile)
  $systemd          = false,                    # runninig as systemd service, don't fiddle with RT throttling
) {}

class platform::stalld
  inherits ::platform::stalld::params {

  package { $package_name:
    ensure => 'present',
  }

  file { $config_file:
    ensure  => 'file',
    content => template('platform/stalld.erb'),
    mode    => '0644',
    require => Package[$package_name],
    notify  => Service['stalld'],
  }

  notice("Enable stalld service? ${enable}")
  if $enable {
    service { 'stalld':
      ensure     => 'running',
      enable     => true,
      name       => 'stalld',
      hasstatus  => true,
      hasrestart => true,
      require    => [ Package[$package_name], File[$config_file] ],
    }
  } else {
    service { 'stalld':
      ensure => 'stopped',
      enable => false,
    }
  }
}

class platform::stalld::runtime {
  include ::platform::stalld
}

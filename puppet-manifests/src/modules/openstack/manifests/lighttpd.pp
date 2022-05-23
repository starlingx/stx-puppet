class openstack::lighttpd::runtime
  inherits ::openstack::horizon::params {

  Class[$name] -> Class['::platform::helm::runtime']

  file {'/etc/lighttpd/lighttpd.conf':
      ensure  => present,
      content => template('openstack/lighttpd.conf.erb')
  }
  -> platform::sm::restart {'lighttpd': }
}

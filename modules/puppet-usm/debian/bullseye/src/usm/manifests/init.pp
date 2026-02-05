#
# Copyright (c) 2023 Wind River Systems, Inc.
#
# SPDX-License-Identifier: Apache-2.0
#

class usm (
  $controller_multicast = '239.1.1.3',
  $agent_multicast = '239.1.1.4',
  $api_port = 5493,
  $controller_port = 5494,
  $agent_port = 5495,
) {
  include usm::params

  file { $::usm::params::usm_conf:
    ensure => present,
    owner  => 'usm',
    group  => 'usm',
    mode   => '0600',
  }

  usm_config {
    'runtime/controller_multicast':  value => $controller_multicast;
    'runtime/agent_multicast':       value => $agent_multicast;
    'runtime/api_port':              value => $api_port;
    'runtime/controller_port':       value => $controller_port;
    'runtime/agent_port':            value => $agent_port;
  }

  Usm_config<||> ~> service { 'software-agent.service':
    ensure => 'running',
    enable => true,
  }

  if $::personality == 'controller' {
    Usm_config<||> ~> service { 'software-controller-daemon.service':
      ensure => 'running',
      enable => true,
    }
  }
}

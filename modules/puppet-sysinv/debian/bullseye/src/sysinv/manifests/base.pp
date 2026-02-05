#
# Files in this package are licensed under Apache; see LICENSE file.
#
# Copyright (c) 2013-2016 Wind River Systems, Inc.
#
# SPDX-License-Identifier: Apache-2.0
#
#  Aug 2016: rebase mitaka
#  Jun 2016: rebase centos
#  Jun 2015: uprev kilo
#  Dec 2014: uprev juno
#  Jul 2014: rename ironic
#  Dec 2013: uprev grizzly, havana
#  Nov 2013: integrate source from https://github.com/stackforge/puppet-sysinv
#

class sysinv::base (
  $sql_connection,
  $package_ensure         = 'present',
  $api_paste_config       = '/etc/sysinv/api-paste.ini',
  $verbose                = false
) {

  warning('The sysinv::base class is deprecated. Use sysinv instead.')

  class { '::sysinv':
    sql_connection   => $sql_connection,
    package_ensure   => $package_ensure,
    api_paste_config => $api_paste_config,
    verbose          => $verbose,
  }

}

#
# Files in this package are licensed under Apache; see LICENSE file.
#
# Copyright (c) 2013-2016 Wind River Systems, Inc.
#
# SPDX-License-Identifier: Apache-2.0
#
#

class dcmanager::params {

  $dcmanager_dir = '/etc/dcmanager'
  $dcmanager_conf = '/etc/dcmanager/dcmanager.conf'
  $package_name = 'distributedcloud-dcmanager'
  $client_package = 'distributedcloud-client-dcmanagerclient'
  $api_package = false
  $api_service = 'dcmanager-api'
  $manager_package = false
  $manager_service = 'dcmanager-manager'
  $db_sync_command = 'dcmanager-manage db_sync'

}

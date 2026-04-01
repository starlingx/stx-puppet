#
# Files in this package are licensed under Apache; see LICENSE file.
#
# Copyright (c) 2013-2018, 2026 Wind River Systems, Inc.
#
# SPDX-License-Identifier: Apache-2.0
#
#  Dec 2017 Creation based off puppet-sysinv
#

# Class that configures postgresql for dcorch
#
# Requires the Puppetlabs postgresql module.
# === Parameters
#
# [*password*]
#   (Required) Password to connect to the database.
#
# [*dbname*]
#   (Optional) Name of the database.
#   Defaults to 'dcorch'.
#
# [*user*]
#   (Optional) User to connect to the database.
#   Defaults to 'dcorch'.
#
#  [*encoding*]
#    (Optional) The charset to use for the database.
#    Default to undef.
#
#  [*privileges*]
#    (Optional) Privileges given to the database user.
#    Default to 'ALL'
#
class dcorch::db::postgresql(
  $password,
  $dbname = 'dcorch',
  $user   = 'dcorch',
  $encoding   = undef,
  $privileges = 'ALL',
) {

  include dcorch::deps

  ::openstacklib::db::postgresql { 'dcorch':
    password   => $password,
    dbname     => $dbname,
    user       => $user,
    encoding   => $encoding,
    privileges => $privileges,
  }

  # PostgreSQL 15+ revokes CREATE on the public schema by default.
  # Grant it explicitly so Alembic migrations can create tables.
  postgresql_psql { "GRANT CREATE ON SCHEMA public TO \"${user}\"":
    db      => $dbname,
    unless  => "SELECT 1 FROM information_schema.role_table_grants WHERE grantee='${user}' AND table_schema='public' LIMIT 1",
    require => Openstacklib::Db::Postgresql['dcorch'],
  }

  Anchor['dcorch::db::begin']
  ~> Class['dcorch::db::postgresql']
  ~> Anchor['dcorch::db::end']
}

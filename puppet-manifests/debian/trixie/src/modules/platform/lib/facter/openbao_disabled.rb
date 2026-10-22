# Copyright (c) 2026 Wind River Systems, Inc.
#
# SPDX-License-Identifier: Apache-2.0
#
# Returns true if OpenBao is warded from running
#
# The ward is a sentinel file on the (persistent) LUKS filesystem at
# controller/.openbao/.disabled under the LUKS mount
# (/var/luks/stx/luks_fs). The upgrade and backup-and-restore paths
# place this ward while bao upgrade/B&R support is still in development,
# so an upgraded or restored node skips the platform::openbao puppet
# classes
#
# NOTE: the LUKS mount is the default platform::openbao::params
# luks_fs_mount (/var/luks/stx/luks_fs); it is not currently overridden.

Facter.add("openbao_disabled") do
  setcode do
    File.exist?('/var/luks/stx/luks_fs/controller/.openbao/.disabled')
  end
end

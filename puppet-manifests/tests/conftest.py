#
# Copyright (c) 2026 Wind River Systems, Inc.
#
# SPDX-License-Identifier: Apache-2.0
#

"""Pytest conftest for distro-aware test execution.

When STX_DISTRO=trixie is set (e.g. by the py313 or coverage-trixie
tox envs), this redirects all ``debian.bullseye.src.*`` imports to
``debian.trixie.src.*`` so the same tests run against trixie source
without modification.

The swap is done via a session-scoped autouse fixture with try/finally
to guarantee cleanup even if pytest crashes.
"""

import os
import shutil

import pytest  # pylint: disable=import-error


DISTRO = os.environ.get('STX_DISTRO', 'bullseye')

_project_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_bullseye_src = os.path.join(_project_root, 'debian', 'bullseye', 'src')
_target_distro_src = os.path.join(_project_root, 'debian', DISTRO, 'src')
_bullseye_src_backup = _bullseye_src + '.bak_test'


# Auto-recover from any previous broken state (e.g. kill -9)
if os.path.islink(_bullseye_src) and os.path.exists(_bullseye_src_backup):
    os.unlink(_bullseye_src)
    os.rename(_bullseye_src_backup, _bullseye_src)


@pytest.fixture(scope="session", autouse=True)
def swap_distro_source():
    """Swap bullseye src with trixie src if STX_DISTRO != bullseye.

    Uses symlink swap with try/finally to ensure the original
    directory is always restored, even on test failure or crash.
    """
    if DISTRO == 'bullseye':
        yield
        return

    # Guard against parallel runs: if already swapped, skip
    if os.path.islink(_bullseye_src):
        yield
        return

    if not os.path.exists(_bullseye_src):
        # Recover from a previous crashed run
        if os.path.exists(_bullseye_src_backup):
            os.rename(_bullseye_src_backup, _bullseye_src)
        else:
            yield
            return

    if os.path.exists(_bullseye_src_backup):
        # Stale backup from a previous run — remove it
        shutil.rmtree(_bullseye_src_backup)
    os.rename(_bullseye_src, _bullseye_src_backup)
    os.symlink(_target_distro_src, _bullseye_src)
    try:
        yield
    finally:
        if os.path.islink(_bullseye_src):
            os.unlink(_bullseye_src)
        if os.path.exists(_bullseye_src_backup):
            os.rename(_bullseye_src_backup, _bullseye_src)

#
# Copyright (c) 2025 Wind River Systems, Inc.
#
# SPDX-License-Identifier: Apache-2.0
#

"""Base test class for stx-puppet test modules.

Provides common setUp/tearDown patterns for tests
that use temporary YAML files.
"""

import os
import tempfile
import unittest


class TempYamlTestCase(unittest.TestCase):
    """Base test case with temp YAML file management.

    Subclasses get automatic creation and cleanup of
    temporary YAML files via ``self.config_file`` and
    ``self.bak_file``.
    """

    def setUp(self):
        """Create temporary config and backup files."""
        fd, self.config_file = tempfile.mkstemp(
            suffix='.yaml'
        )
        os.close(fd)
        fd, self.bak_file = tempfile.mkstemp(
            suffix='.yaml'
        )
        os.close(fd)

    def tearDown(self):
        """Remove temporary files."""
        for filepath in [self.config_file, self.bak_file]:
            if os.path.exists(filepath):
                os.unlink(filepath)

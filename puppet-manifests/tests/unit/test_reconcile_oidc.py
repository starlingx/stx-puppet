#
# Copyright (c) 2026 Wind River Systems, Inc.
#
# SPDX-License-Identifier: Apache-2.0
#


"""Unit tests for reconcile_oidc_role_bindings.py.

Tests focus on real parsing logic, credential extraction,
and reconciliation state management with real temp files.
"""

import importlib
import os
import sys
import tempfile
import unittest
from unittest.mock import MagicMock
from unittest.mock import patch

# Mock keystone libraries (not installed in test env)
_mock_ks_exc = MagicMock()
_mock_ks_exc.NotFound = type('NotFound', (Exception,), {})
_mock_ks_exc.ClientException = type('ClientException', (Exception,), {})

sys.modules.setdefault('urllib3', MagicMock())
sys.modules.setdefault('keystoneauth1', MagicMock())
sys.modules.setdefault('keystoneauth1.identity', MagicMock())
sys.modules.setdefault('keystoneauth1.identity.v3', MagicMock())
sys.modules.setdefault('keystoneauth1.session', MagicMock())
sys.modules['keystoneauth1.exceptions'] = _mock_ks_exc
sys.modules.setdefault('keystoneclient', MagicMock())
sys.modules.setdefault('keystoneclient.v3', MagicMock())
sys.modules.setdefault('keystoneclient.v3.client', MagicMock())

oidc = importlib.import_module(
    'debian.bullseye.src.bin.reconcile_oidc_role_bindings'
)
# Wire real exception class so isinstance checks work
oidc.ks_exceptions = _mock_ks_exc


class TestParseDesiredBindings(unittest.TestCase):
    """Tests for parse_desired_bindings - pure string parsing."""

    def test_empty_string(self):
        """Empty string returns empty list."""
        self.assertEqual(oidc.parse_desired_bindings(''), [])

    def test_whitespace_only(self):
        """Whitespace returns empty list."""
        self.assertEqual(oidc.parse_desired_bindings('   '), [])

    def test_none_input(self):
        """None returns empty list."""
        self.assertEqual(oidc.parse_desired_bindings(None), [])

    def test_group_with_project_and_role(self):
        """Parses %group:project,role correctly."""
        result = oidc.parse_desired_bindings('%engineers:myproj,admin')
        self.assertEqual(len(result), 1)
        entry = result[0]
        self.assertEqual(entry['type'], 'group')
        self.assertEqual(entry['group_name'], 'engineers')
        self.assertEqual(entry['project'], 'myproj')
        self.assertEqual(entry['role'], 'admin')
        self.assertEqual(entry['domain'], 'Default')

    def test_user_binding(self):
        """User (no % prefix) gets group_name with user_ prefix."""
        result = oidc.parse_desired_bindings('alice:admin,member')
        self.assertEqual(result[0]['type'], 'user')
        self.assertEqual(result[0]['group_name'], 'user_alice')
        self.assertEqual(result[0]['name'], 'alice')
        self.assertEqual(result[0]['role'], 'member')

    def test_with_explicit_domain(self):
        """Parses domain from three-part value."""
        result = oidc.parse_desired_bindings('%ops:Corp,infra,reader')
        self.assertEqual(result[0]['domain'], 'Corp')
        self.assertEqual(result[0]['project'], 'infra')
        self.assertEqual(result[0]['role'], 'reader')

    def test_multiple_semicolon_separated(self):
        """Parses multiple bindings separated by semicolons."""
        result = oidc.parse_desired_bindings(
            '%devs:proj1,admin;%ops:proj2,reader')
        self.assertEqual(len(result), 2)
        self.assertEqual(result[0]['group_name'], 'devs')
        self.assertEqual(result[1]['group_name'], 'ops')

    def test_role_only(self):
        """Single value after colon is the role, project defaults."""
        result = oidc.parse_desired_bindings('%viewers:reader')
        self.assertEqual(result[0]['role'], 'reader')
        self.assertEqual(result[0]['project'], 'admin')

    def test_invalid_entry_no_colon(self):
        """Entry without colon is skipped."""
        result = oidc.parse_desired_bindings('no_colon_here')
        self.assertEqual(result, [])

    def test_mixed_valid_and_invalid(self):
        """Only valid entries are returned."""
        result = oidc.parse_desired_bindings(
            '%good:proj,role;invalid;%ok:admin,member')
        self.assertEqual(len(result), 2)
        self.assertEqual(result[0]['group_name'], 'good')
        self.assertEqual(result[1]['group_name'], 'ok')


class TestGetKeystoneCredentials(unittest.TestCase):
    """Tests for get_keystone_credentials - subprocess + parsing."""

    @patch('subprocess.run')
    def test_extracts_os_vars(self, mock_run):
        """Extracts only OS_* variables from env output."""
        mock_run.return_value = MagicMock(
            returncode=0,
            stdout=(
                'OS_AUTH_URL=http://keystone:5000/v3\n'
                'OS_USERNAME=admin\n'
                'OS_PASSWORD=secret123\n'
                'OS_PROJECT_NAME=admin\n'
                'HOME=/root\n'
                'PATH=/usr/bin\n'
            )
        )
        result = oidc.get_keystone_credentials()
        self.assertEqual(result['OS_AUTH_URL'], 'http://keystone:5000/v3')
        self.assertEqual(result['OS_USERNAME'], 'admin')
        self.assertEqual(result['OS_PASSWORD'], 'secret123')
        self.assertNotIn('HOME', result)
        self.assertNotIn('PATH', result)

    @patch('subprocess.run')
    def test_raises_on_subprocess_failure(self, mock_run):
        """Raises RuntimeError when sourcing openrc fails."""
        mock_run.return_value = MagicMock(
            returncode=1, stderr='No such file')
        with self.assertRaises(RuntimeError) as ctx:
            oidc.get_keystone_credentials()
        self.assertIn('Failed to source', str(ctx.exception))


class TestFindHelpers(unittest.TestCase):
    """Tests for find_group, find_role, find_project."""

    def test_find_group_exists(self):
        """Returns first group when found."""
        ks = MagicMock()
        group_obj = MagicMock()
        ks.domains.find.return_value = MagicMock(id='d1')
        ks.groups.list.return_value = [group_obj]
        result = oidc.find_group(ks, 'mygroup', 'Default')
        self.assertEqual(result, group_obj)

    def test_find_group_empty_list(self):
        """Returns None when no groups match."""
        ks = MagicMock()
        ks.domains.find.return_value = MagicMock()
        ks.groups.list.return_value = []
        self.assertIsNone(oidc.find_group(ks, 'missing', 'Default'))

    def test_find_group_domain_not_found(self):
        """Returns None when domain raises NotFound."""
        ks = MagicMock()
        ks.domains.find.side_effect = _mock_ks_exc.NotFound()
        self.assertIsNone(oidc.find_group(ks, 'grp', 'BadDomain'))

    def test_find_role_exists(self):
        """Returns role object when found."""
        ks = MagicMock()
        role_obj = MagicMock()
        ks.roles.find.return_value = role_obj
        self.assertEqual(oidc.find_role(ks, 'admin'), role_obj)

    def test_find_role_not_found(self):
        """Returns None when role not found."""
        ks = MagicMock()
        ks.roles.find.side_effect = _mock_ks_exc.NotFound()
        self.assertIsNone(oidc.find_role(ks, 'nonexistent'))

    def test_find_project_exists(self):
        """Returns project when found."""
        ks = MagicMock()
        proj_obj = MagicMock()
        ks.domains.find.return_value = MagicMock(id='d1')
        ks.projects.find.return_value = proj_obj
        self.assertEqual(
            oidc.find_project(ks, 'myproj', 'Default'), proj_obj)

    def test_find_project_not_found(self):
        """Returns None when project not found."""
        ks = MagicMock()
        ks.domains.find.return_value = MagicMock()
        ks.projects.find.side_effect = _mock_ks_exc.NotFound()
        self.assertIsNone(oidc.find_project(ks, 'missing', 'Default'))


class TestAssignRole(unittest.TestCase):
    """Tests for assign_role - branching on existing state."""

    @patch.object(oidc, 'has_role_assignment', return_value=False)
    @patch.object(oidc, 'find_project')
    @patch.object(oidc, 'find_role')
    @patch.object(oidc, 'find_group')
    def test_grants_new_assignment(self, mock_fg, mock_fr,
                                   mock_fp, _mock_has):
        """Calls roles.grant when assignment doesn't exist."""
        ks = MagicMock()
        mock_fg.return_value = MagicMock()
        mock_fr.return_value = MagicMock()
        mock_fp.return_value = MagicMock()
        result = oidc.assign_role(ks, 'grp', 'proj', 'Default', 'admin')
        self.assertTrue(result)
        self.assertEqual(ks.roles.grant.call_count, 1)

    @patch.object(oidc, 'has_role_assignment', return_value=True)
    @patch.object(oidc, 'find_project')
    @patch.object(oidc, 'find_role')
    @patch.object(oidc, 'find_group')
    def test_skips_existing_assignment(self, mock_fg, mock_fr,
                                       mock_fp, _mock_has):
        """Does not call grant when already assigned."""
        ks = MagicMock()
        mock_fg.return_value = MagicMock()
        mock_fr.return_value = MagicMock()
        mock_fp.return_value = MagicMock()
        result = oidc.assign_role(ks, 'grp', 'proj', 'Default', 'admin')
        self.assertTrue(result)
        self.assertEqual(ks.roles.grant.call_count, 0)

    @patch.object(oidc, 'find_project', return_value=None)
    @patch.object(oidc, 'find_role', return_value=MagicMock())
    @patch.object(oidc, 'find_group', return_value=MagicMock())
    def test_returns_false_missing_resource(self, _fg, _fr, _fp):
        """Returns False when any resource not found."""
        ks = MagicMock()
        result = oidc.assign_role(ks, 'grp', 'bad', 'Default', 'admin')
        self.assertFalse(result)


class TestRemoveRole(unittest.TestCase):
    """Tests for remove_role - branching on resources."""

    @patch.object(oidc, 'find_project')
    @patch.object(oidc, 'find_role')
    @patch.object(oidc, 'find_group')
    def test_revokes_existing(self, mock_fg, mock_fr, mock_fp):
        """Revokes role when all resources found."""
        ks = MagicMock()
        mock_fg.return_value = MagicMock()
        mock_fr.return_value = MagicMock()
        mock_fp.return_value = MagicMock()
        result = oidc.remove_role(ks, 'grp', 'proj', 'Default', 'admin')
        self.assertTrue(result)
        self.assertEqual(ks.roles.revoke.call_count, 1)

    @patch.object(oidc, 'find_group', return_value=None)
    @patch.object(oidc, 'find_role', return_value=MagicMock())
    @patch.object(oidc, 'find_project', return_value=MagicMock())
    def test_returns_false_missing_group(self, _fp, _fr, _fg):
        """Returns False when group not found."""
        ks = MagicMock()
        result = oidc.remove_role(ks, 'gone', 'proj', 'Default', 'admin')
        self.assertFalse(result)


class TestDeleteGroup(unittest.TestCase):
    """Tests for delete_group."""

    @patch.object(oidc, 'find_group')
    def test_deletes_existing_group(self, mock_fg):
        """Deletes group and returns True."""
        ks = MagicMock()
        group_obj = MagicMock()
        mock_fg.return_value = group_obj
        result = oidc.delete_group(ks, 'old-grp')
        self.assertTrue(result)
        ks.groups.delete.assert_called_once_with(group_obj)

    @patch.object(oidc, 'find_group', return_value=None)
    def test_noop_missing_group(self, _mock_fg):
        """Returns True without deleting when group missing."""
        ks = MagicMock()
        result = oidc.delete_group(ks, 'gone')
        self.assertTrue(result)
        self.assertEqual(ks.groups.delete.call_count, 0)


class TestReconcile(unittest.TestCase):
    """Tests for reconcile - state file management."""

    @patch.object(oidc, 'assign_role', return_value=True)
    @patch.object(oidc, 'create_group', return_value=MagicMock())
    @patch.object(oidc, 'create_keystone_client')
    def test_saves_applied_state(self, _mock_ks, _mock_cg, _mock_ar):
        """Writes current bindings to applied file."""
        fd, path = tempfile.mkstemp()
        os.close(fd)
        try:
            with patch.object(oidc, 'APPLIED_FILE', path):
                oidc.reconcile('%team:proj,admin')
            with open(path, encoding='utf-8') as f:
                self.assertEqual(f.read(), '%team:proj,admin')
        finally:
            os.unlink(path)

    @patch.object(oidc, 'delete_group', return_value=True)
    @patch.object(oidc, 'remove_role', return_value=True)
    @patch.object(oidc, 'create_keystone_client')
    def test_removes_stale_groups(self, _mock_ks, mock_rr, mock_dg):
        """Removes groups in previous state but not desired."""
        fd, path = tempfile.mkstemp()
        try:
            os.write(fd, b'%stale:admin,admin')
            os.close(fd)
            with patch.object(oidc, 'APPLIED_FILE', path):
                oidc.reconcile('')
            self.assertTrue(mock_rr.called)
            self.assertTrue(mock_dg.called)
        finally:
            os.unlink(path)

    @patch.object(oidc, 'remove_role', return_value=True)
    @patch.object(oidc, 'assign_role', return_value=True)
    @patch.object(oidc, 'create_group', return_value=MagicMock())
    @patch.object(oidc, 'create_keystone_client')
    def test_removes_stale_roles_keeps_group(self, _ks, _cg, _ar, mock_rr):
        """Removes only stale roles when group still has other roles."""
        fd, path = tempfile.mkstemp()
        try:
            os.write(fd, b'%team:proj,admin;%team:proj,member')
            os.close(fd)
            with patch.object(oidc, 'APPLIED_FILE', path):
                oidc.reconcile('%team:proj,admin')
            # remove_role called for 'member' (stale)
            self.assertTrue(mock_rr.called)
        finally:
            os.unlink(path)

    @patch.object(oidc, 'create_keystone_client')
    def test_handles_missing_applied_file(self, _mock_ks):
        """Works when applied file doesn't exist (first run)."""
        path = '/tmp/nonexistent_applied_test_file'
        if os.path.exists(path):
            os.unlink(path)
        try:
            with patch.object(oidc, 'APPLIED_FILE', path):
                oidc.reconcile('')
            with open(path, encoding='utf-8') as f:
                self.assertEqual(f.read(), '')
        finally:
            if os.path.exists(path):
                os.unlink(path)


class TestMain(unittest.TestCase):
    """Tests for main() entry point."""

    @patch.object(oidc, 'reconcile')
    def test_passes_argv_to_reconcile(self, mock_rec):
        """Passes sys.argv[1] to reconcile."""
        with patch('sys.argv', ['prog', '%grp:proj,role']):
            oidc.main()
        self.assertEqual(mock_rec.call_count, 1)
        self.assertEqual(mock_rec.call_args[0][0], '%grp:proj,role')

    def test_exits_without_args(self):
        """Exits 1 when no arguments given."""
        with patch('sys.argv', ['prog']):
            with self.assertRaises(SystemExit) as ctx:
                oidc.main()
            self.assertEqual(ctx.exception.code, 1)

    @patch.object(oidc, 'reconcile', side_effect=IOError("disk full"))
    def test_exits_on_reconcile_error(self, _mock_rec):
        """Exits 1 on reconciliation failure."""
        with patch('sys.argv', ['prog', 'bindings']):
            with self.assertRaises(SystemExit) as ctx:
                oidc.main()
            self.assertEqual(ctx.exception.code, 1)


if __name__ == '__main__':
    unittest.main()

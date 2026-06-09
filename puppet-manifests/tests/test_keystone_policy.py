#
# Copyright (c) 2026 Wind River Systems, Inc.
#
# SPDX-License-Identifier: Apache-2.0
#
"""Tests for keystone policy rules using oslo.policy enforcement."""

import os
import random
import re
import unittest

import yaml
from oslo_config import cfg
from oslo_policy import policy


BASE_PATH = os.path.join(
    os.path.dirname(__file__), os.pardir,
    "debian/trixie/src/modules/openstack")

TEMPLATE_PATH = os.path.join(BASE_PATH, "templates/keystone-policy.yaml.erb")

MANIFEST_PATH = os.path.join(BASE_PATH, "manifests/keystone.pp")

PROTECTED_SERVICES = [
    'barbican', 'sysinv', 'mtce', 'fm', 'dcdbsync',
    'dcagent', 'dcorch', 'vim', 'dcmanager', 'smapi', 'usm',
]


def render_policy_template():
    """Turn the ERB template into valid YAML without needing Ruby.

    Expands all @protected_services loops with the test service list.
    """
    with open(TEMPLATE_PATH) as f:
        content = f.read()

    # Find and replace each ERB loop with its expanded form
    loop_re = re.compile(
        r'<%\s*@protected_services\.each\s+do\s+\|svc\|\s*-%>\s*\n'
        r'(.*?)\n'
        r'<%\s*end\s*-%>\s*\n',
        re.DOTALL)

    while True:
        match = loop_re.search(content)
        if not match:
            break
        line_tpl = match.group(1)
        rendered = ''.join(
            line_tpl.replace('<%= svc %>', svc) + '\n'
            for svc in PROTECTED_SERVICES)
        content = content[:match.start()] + rendered + content[match.end():]

    return yaml.safe_load(content)


class PolicyTestBase(unittest.TestCase):
    """Base class that loads and renders the keystone policy template."""

    def setUp(self):
        rules_dict = render_policy_template()
        conf = cfg.ConfigOpts()
        conf(args=[], project="test_keystone_policy")
        self.enforcer = policy.Enforcer(conf, use_conf=False)
        self.enforcer.set_rules(policy.Rules.from_dict(rules_dict))


class TestKeystoneDeleteDomainPolicy(PolicyTestBase):
    """Verify identity:delete_domain policy enforcement behavior."""

    def test_system_scoped_admin_can_delete_domain(self):
        creds = {"roles": ["admin"], "system_scope": "all"}
        result = self.enforcer.enforce(
            "identity:delete_domain", {}, creds, do_raise=False)
        self.assertTrue(
            result, "System-scoped admin must be able to delete domains")

    def test_project_scoped_admin_cannot_delete_domain(self):
        creds = {"roles": ["admin"], "project_id": "some-project"}
        result = self.enforcer.enforce(
            "identity:delete_domain", {}, creds, do_raise=False)
        self.assertFalse(
            result, "Project-scoped admin must NOT be able to delete domains")

    def test_non_admin_cannot_delete_domain(self):
        creds = {"roles": ["member"], "system_scope": "all"}
        result = self.enforcer.enforce(
            "identity:delete_domain", {}, creds, do_raise=False)
        self.assertFalse(
            result, "Non-admin must NOT be able to delete domains")


class TestKeystoneDeleteServicePolicy(PolicyTestBase):
    """Verify identity:delete_service policy enforcement behavior."""

    def test_admin_can_delete_non_protected_service(self):
        creds = {"roles": ["admin"]}
        target = {"target.service.name": "nova"}
        result = self.enforcer.enforce(
            "identity:delete_service", target, creds, do_raise=False)
        self.assertTrue(
            result, "Admin must be able to delete non-protected services")

    def test_admin_cannot_delete_protected_service(self):
        creds = {"roles": ["admin"]}
        target = {"target.service.name": random.choice(PROTECTED_SERVICES)}
        result = self.enforcer.enforce(
            "identity:delete_service", target, creds, do_raise=False)
        self.assertFalse(
            result, "Admin must NOT be able to delete protected services")

    def test_non_admin_cannot_delete_service(self):
        creds = {"roles": ["member"]}
        target = {"target.service.name": "nova"}
        result = self.enforcer.enforce(
            "identity:delete_service", target, creds, do_raise=False)
        self.assertFalse(
            result, "Non-admin must NOT be able to delete any service")


class TestKeystoneDeleteProjectPolicy(PolicyTestBase):
    """Verify identity:delete_project policy enforcement behavior."""

    def test_admin_can_delete_regular_project(self):
        creds = {"roles": ["admin"]}
        target = {"target.project.name": "user-project"}
        result = self.enforcer.enforce(
            "identity:delete_project", target, creds, do_raise=False)
        self.assertTrue(
            result, "Admin must be able to delete regular projects")

    def test_admin_cannot_delete_admin_project(self):
        creds = {"roles": ["admin"]}
        target = {"target.project.name": "admin"}
        result = self.enforcer.enforce(
            "identity:delete_project", target, creds, do_raise=False)
        self.assertFalse(
            result, "Admin must NOT be able to delete the admin project")

    def test_admin_cannot_delete_services_project(self):
        creds = {"roles": ["admin"]}
        target = {"target.project.name": "services"}
        result = self.enforcer.enforce(
            "identity:delete_project", target, creds, do_raise=False)
        self.assertFalse(
            result, "Admin must NOT be able to delete the services project")

    def test_non_admin_cannot_delete_project(self):
        creds = {"roles": ["member"]}
        target = {"target.project.name": "user-project"}
        result = self.enforcer.enforce(
            "identity:delete_project", target, creds, do_raise=False)
        self.assertFalse(
            result, "Non-admin must NOT be able to delete any project")


class TestKeystoneDeleteUserPolicy(PolicyTestBase):
    """Verify identity:delete_user policy enforcement behavior."""

    def test_admin_can_delete_regular_user(self):
        creds = {"roles": ["admin"]}
        target = {"target.user.name": "regular-user"}
        result = self.enforcer.enforce(
            "identity:delete_user", target, creds, do_raise=False)
        self.assertTrue(
            result, "Admin must be able to delete regular users")

    def test_admin_cannot_delete_admin_user(self):
        creds = {"roles": ["admin"]}
        target = {"target.user.name": "admin"}
        result = self.enforcer.enforce(
            "identity:delete_user", target, creds, do_raise=False)
        self.assertFalse(
            result, "Admin must NOT be able to delete the admin user")

    def test_admin_cannot_delete_dcmanager_user(self):
        creds = {"roles": ["admin"]}
        target = {"target.user.name": "dcmanager"}
        result = self.enforcer.enforce(
            "identity:delete_user", target, creds, do_raise=False)
        self.assertFalse(
            result, "Admin must NOT be able to delete the dcmanager user")

    def test_admin_cannot_delete_protected_service_user(self):
        creds = {"roles": ["admin"]}
        target = {"target.user.name": random.choice(PROTECTED_SERVICES)}
        result = self.enforcer.enforce(
            "identity:delete_user", target, creds, do_raise=False)
        self.assertFalse(
            result,
            "Admin must NOT be able to delete protected service users")

    def test_non_admin_cannot_delete_user(self):
        creds = {"roles": ["member"]}
        target = {"target.user.name": "regular-user"}
        result = self.enforcer.enforce(
            "identity:delete_user", target, creds, do_raise=False)
        self.assertFalse(
            result, "Non-admin must NOT be able to delete any user")


class TestKeystoneDeleteRolePolicy(PolicyTestBase):
    """Verify identity:delete_role policy enforcement behavior."""

    def test_admin_can_delete_non_admin_role(self):
        creds = {"roles": ["admin"]}
        target = {"target.role.name": "member"}
        result = self.enforcer.enforce(
            "identity:delete_role", target, creds, do_raise=False)
        self.assertTrue(
            result, "Admin must be able to delete non-admin roles")

    def test_admin_cannot_delete_admin_role(self):
        creds = {"roles": ["admin"]}
        target = {"target.role.name": "admin"}
        result = self.enforcer.enforce(
            "identity:delete_role", target, creds, do_raise=False)
        self.assertFalse(
            result, "Admin must NOT be able to delete the admin role")

    def test_non_admin_cannot_delete_role(self):
        creds = {"roles": ["member"]}
        target = {"target.role.name": "member"}
        result = self.enforcer.enforce(
            "identity:delete_role", target, creds, do_raise=False)
        self.assertFalse(
            result, "Non-admin must NOT be able to delete any role")


class TestKeystoneListServicesPolicy(PolicyTestBase):
    """Verify identity:list_services policy enforcement behavior."""

    def test_admin_can_list_services(self):
        creds = {"roles": ["admin"]}
        result = self.enforcer.enforce(
            "identity:list_services", {}, creds, do_raise=False)
        self.assertTrue(
            result, "Admin must be able to list services")

    def test_reader_can_list_services(self):
        creds = {"roles": ["reader"]}
        result = self.enforcer.enforce(
            "identity:list_services", {}, creds, do_raise=False)
        self.assertTrue(
            result, "Reader must be able to list services")

    def test_member_cannot_list_services(self):
        creds = {"roles": ["member"]}
        result = self.enforcer.enforce(
            "identity:list_services", {}, creds, do_raise=False)
        self.assertFalse(
            result, "Plain member must NOT be able to list services")


class TestKeystoneListEndpointsPolicy(PolicyTestBase):
    """Verify identity:list_endpoints policy enforcement behavior."""

    def test_admin_can_list_endpoints(self):
        creds = {"roles": ["admin"]}
        result = self.enforcer.enforce(
            "identity:list_endpoints", {}, creds, do_raise=False)
        self.assertTrue(
            result, "Admin must be able to list endpoints")

    def test_reader_can_list_endpoints(self):
        creds = {"roles": ["reader"]}
        result = self.enforcer.enforce(
            "identity:list_endpoints", {}, creds, do_raise=False)
        self.assertTrue(
            result, "Reader must be able to list endpoints")

    def test_member_cannot_list_endpoints(self):
        creds = {"roles": ["member"]}
        result = self.enforcer.enforce(
            "identity:list_endpoints", {}, creds, do_raise=False)
        self.assertFalse(
            result, "Plain member must NOT be able to list endpoints")


class TestProtectedServicesSync(unittest.TestCase):
    """Ensure test list matches the puppet manifest."""

    def test_protected_services_matches_manifest(self):
        with open(MANIFEST_PATH) as f:
            content = f.read()
        match = re.search(
            r'\$protected_services\s*=\s*\[(.*?)\]', content, re.DOTALL)
        puppet_services = re.findall(r"'(\w+)'", match.group(1))
        self.assertEqual(
            sorted(PROTECTED_SERVICES), sorted(puppet_services),
            "PROTECTED_SERVICES in test must match $protected_services "
            "in keystone.pp")

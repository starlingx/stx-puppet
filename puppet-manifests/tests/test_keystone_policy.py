#
# Copyright (c) 2026 Wind River Systems, Inc.
#
# SPDX-License-Identifier: Apache-2.0
#
"""Tests for keystone policy rules using oslo.policy enforcement."""

import os
import unittest

import yaml
from oslo_config import cfg
from oslo_policy import policy


TEMPLATE_PATH = os.path.join(
    os.path.dirname(__file__), os.pardir,
    "debian/trixie/src/modules/openstack/templates/keystone-policy.yaml.erb")


class TestKeystoneDeleteDomainPolicy(unittest.TestCase):
    """Verify identity:delete_domain policy enforcement behavior."""

    def setUp(self):
        with open(TEMPLATE_PATH) as f:
            rules_dict = yaml.safe_load(f)
        conf = cfg.ConfigOpts()
        conf(args=[], project="test_keystone_policy")
        self.enforcer = policy.Enforcer(conf, use_conf=False)
        self.enforcer.set_rules(policy.Rules.from_dict(rules_dict))

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

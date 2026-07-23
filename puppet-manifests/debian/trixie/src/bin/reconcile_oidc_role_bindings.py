#!/usr/bin/env python3
"""Reconcile OIDC role bindings in Keystone.

Reads desired state from the role-bindings service parameter,
compares against current Keystone groups and role assignments,
creates missing resources, and removes stale ones.

Usage:
    reconcile_oidc_role_bindings.py '<role_bindings_string>'
    reconcile_oidc_role_bindings.py ''  # empty = remove all managed bindings
"""

import subprocess
import sys
import logging
import urllib3

from keystoneauth1.identity import v3 as identity  # pylint: disable=import-error
from keystoneauth1 import session  # pylint: disable=import-error
from keystoneauth1 import exceptions as ks_exceptions  # pylint: disable=import-error
from keystoneclient.v3 import client as ks_client  # pylint: disable=import-error

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

LOG = logging.getLogger(__name__)
logging.basicConfig(level=logging.INFO, format='%(levelname)s: %(message)s')

RC_FILE = '/etc/platform/openrc'
APPLIED_FILE = '/etc/platform/.rolebindings.applied'


def get_keystone_credentials():
    """Read credentials from openrc file."""
    clean_env = {
        'PATH': '/usr/bin:/usr/sbin:/bin:/sbin:/usr/local/bin',
        'HOME': '/root',
        'LANG': 'en_US.UTF-8',
    }
    result = subprocess.run(
        ['bash', '-c', f'source {RC_FILE} && env'],
        capture_output=True, text=True, timeout=10,
        check=False, env=clean_env
    )
    if result.returncode != 0:
        raise RuntimeError(f"Failed to source {RC_FILE}: {result.stderr}")

    env_vars = {}
    for line in result.stdout.splitlines():
        if '=' in line:
            key, _, value = line.partition('=')
            if key.startswith('OS_'):
                env_vars[key] = value
    return env_vars


def create_keystone_client():
    """Create an authenticated Keystone client."""
    creds = get_keystone_credentials()

    auth = identity.Password(
        auth_url=creds.get('OS_AUTH_URL', 'http://controller.internal:5000/v3'),
        username=creds.get('OS_USERNAME', 'admin'),
        password=creds.get('OS_PASSWORD', ''),
        project_name=creds.get('OS_PROJECT_NAME', 'admin'),
        user_domain_name=creds.get('OS_USER_DOMAIN_NAME', 'Default'),
        project_domain_name=creds.get('OS_PROJECT_DOMAIN_NAME', 'Default'),
    )
    sess = session.Session(auth=auth, verify=False)
    return ks_client.Client(session=sess)


def parse_desired_bindings(bindings_str):
    """Parse role-bindings string into list of dicts."""
    if not bindings_str or bindings_str.isspace():
        return []

    entries = []
    for entry in bindings_str.split(';'):
        parts = entry.split(':', 2)
        if len(parts) != 2:
            continue
        subject = parts[0]
        rhs = parts[1].split(',')

        role = rhs[-1].strip()
        project = rhs[-2].strip() if len(rhs) > 1 else 'admin'
        domain = rhs[-3].strip() if len(rhs) > 2 else 'Default'

        if subject.startswith('%'):
            group_name = subject[1:]
            entries.append({
                'type': 'group',
                'name': group_name,
                'group_name': group_name,
                'domain': domain,
                'project': project,
                'role': role,
            })
        else:
            entries.append({
                'type': 'user',
                'name': subject,
                'group_name': f'user_{subject}',
                'domain': domain,
                'project': project,
                'role': role,
            })
    return entries


def find_group(keystone, group_name, domain_name='Default'):
    """Find a group by name in a domain. Returns group object or None."""
    try:
        domain = keystone.domains.find(name=domain_name)
        groups = keystone.groups.list(domain=domain, name=group_name)
        return groups[0] if groups else None
    except (ks_exceptions.NotFound, IndexError):
        return None


def find_role(keystone, role_name):
    """Find a role by name. Returns role object or None."""
    try:
        return keystone.roles.find(name=role_name)
    except ks_exceptions.NotFound:
        return None


def find_project(keystone, project_name, domain_name='Default'):
    """Find a project by name. Returns project object or None."""
    try:
        domain = keystone.domains.find(name=domain_name)
        return keystone.projects.find(name=project_name, domain_id=domain.id)
    except ks_exceptions.NotFound:
        return None


def create_group(keystone, group_name, domain_name='Default'):
    """Create a group if it doesn't exist. Returns group object."""
    group = find_group(keystone, group_name, domain_name)
    if group:
        LOG.info("Group '%s' already exists", group_name)
        return group

    domain = keystone.domains.find(name=domain_name)
    group = keystone.groups.create(name=group_name, domain=domain)
    LOG.info("Created group '%s'", group_name)
    return group


def has_role_assignment(keystone, group, role, project):
    """Check if a role assignment exists."""
    assignments = keystone.role_assignments.list(
        group=group, project=project, role=role
    )
    return len(assignments) > 0


def assign_role(keystone, group_name, project_name, domain_name, role_name):
    """Assign a role to a group on a project."""
    group = find_group(keystone, group_name, domain_name)
    role = find_role(keystone, role_name)
    project = find_project(keystone, project_name, domain_name)

    if not all([group, role, project]):
        LOG.error("Cannot assign role: group=%s role=%s project=%s",
                  group, role, project)
        return False

    if has_role_assignment(keystone, group, role, project):
        LOG.info("Role '%s' already assigned to group '%s'",
                 role_name, group_name)
        return True

    keystone.roles.grant(role, group=group, project=project)
    LOG.info("Assigned role '%s' to group '%s' on project '%s'",
             role_name, group_name, project_name)
    return True


def remove_role(keystone, group_name, project_name, domain_name, role_name):
    """Remove a role assignment from a group."""
    group = find_group(keystone, group_name, domain_name)
    role = find_role(keystone, role_name)
    project = find_project(keystone, project_name, domain_name)

    if not all([group, role, project]):
        LOG.warning("Cannot remove role (resource not found): "
                    "group=%s role=%s project=%s",
                    group_name, role_name, project_name)
        return False

    try:
        keystone.roles.revoke(role, group=group, project=project)
        LOG.info("Removed role '%s' from group '%s' on project '%s'",
                 role_name, group_name, project_name)
    except ks_exceptions.NotFound:
        LOG.info("Role '%s' was not assigned to group '%s'",
                 role_name, group_name)
    return True


def delete_group(keystone, group_name, domain_name='Default'):
    """Delete a group."""
    group = find_group(keystone, group_name, domain_name)
    if not group:
        LOG.info("Group '%s' does not exist, nothing to delete", group_name)
        return True

    keystone.groups.delete(group)
    LOG.info("Deleted group '%s'", group_name)
    return True


def reconcile(bindings_str):
    """Main reconciliation logic."""
    keystone = create_keystone_client()
    desired = parse_desired_bindings(bindings_str)

    # Build desired state: {group_name: {'roles': set, ...}}
    desired_state = {}
    for entry in desired:
        gn = entry['group_name']
        if gn not in desired_state:
            desired_state[gn] = {
                'roles': set(),
                'domain': entry['domain'],
                'project': entry['project'],
                'type': entry['type'],
            }
        desired_state[gn]['roles'].add(entry['role'])

    # --- CREATE MISSING ---
    for group_name, state in desired_state.items():
        create_group(keystone, group_name, state['domain'])
        for role in state['roles']:
            assign_role(keystone, group_name, state['project'],
                        state['domain'], role)

    # --- REMOVE STALE ---
    try:
        with open(APPLIED_FILE, 'r') as f:
            previous_bindings = f.read().strip()
    except FileNotFoundError:
        previous_bindings = ''

    previous = parse_desired_bindings(previous_bindings)
    previous_state = {}
    for entry in previous:
        gn = entry['group_name']
        if gn not in previous_state:
            previous_state[gn] = {
                'roles': set(),
                'domain': entry['domain'],
                'project': entry['project'],
                'type': entry['type'],
            }
        previous_state[gn]['roles'].add(entry['role'])

    for group_name, prev_state in previous_state.items():
        if group_name not in desired_state:
            for role in prev_state['roles']:
                remove_role(keystone, group_name, prev_state['project'],
                            prev_state['domain'], role)
            delete_group(keystone, group_name, prev_state['domain'])
        else:
            stale_roles = (prev_state['roles'] -
                           desired_state[group_name]['roles'])
            for role in stale_roles:
                remove_role(keystone, group_name, prev_state['project'],
                            prev_state['domain'], role)

    # --- SAVE CURRENT STATE ---
    with open(APPLIED_FILE, 'w') as f:
        f.write(bindings_str if bindings_str else '')

    LOG.info("Reconciliation complete. Desired groups: %s",
             list(desired_state.keys()) if desired_state else '(none)')


def main():
    if len(sys.argv) < 2:
        print("Usage: reconcile_oidc_role_bindings.py '<bindings_string>'")
        sys.exit(1)

    bindings_str = sys.argv[1]
    try:
        reconcile(bindings_str)
    except (ValueError, IOError, OSError,
            ks_exceptions.ClientException,
            subprocess.TimeoutExpired,
            subprocess.SubprocessError) as e:
        LOG.error("Reconciliation failed: %s", e)
        sys.exit(1)


if __name__ == '__main__':
    main()

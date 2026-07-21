#
# Copyright (c) 2026 Wind River Systems, Inc.
#
# SPDX-License-Identifier: Apache-2.0
#

"""Shared test helper functions for stx-puppet tests.

Provides reusable utilities to reduce duplication
across test modules.
"""

import os
import sys
import tempfile
import types
from io import StringIO
from unittest import mock

import ruamel.yaml


def _use_legacy_ruamel_api():
    """Check if we should use the legacy ruamel.yaml API.

    Returns:
        True if ruamel.yaml < 0.18 (legacy API).
    """
    return ruamel.yaml.version_info < (0, 18)


def safe_import_module(module_name):
    """Import a module that has side effects at module level.

    Handles modules with ``time.sleep(wait)`` and
    ``sys.exit(0)`` at module level by pre-seeding
    required variables and mocking side-effect calls.

    Args:
        module_name: Dotted module name to import.

    Returns:
        The loaded module object, or None on failure.
    """
    parts = module_name.split('.')
    rel_path = '/'.join(parts) + '.py'
    base = os.path.dirname(
        os.path.dirname(os.path.abspath(__file__))
    )
    src_path = os.path.join(base, rel_path)

    mod = types.ModuleType(module_name)
    mod.__file__ = src_path
    mod.wait = 0
    mod.__name__ = module_name

    with open(src_path, 'r', encoding='utf-8') as file_handle:
        source = file_handle.read()
    code = compile(source, src_path, 'exec')

    mod.__builtins__ = __builtins__
    with mock.patch('time.sleep'), mock.patch('sys.exit'):
        exec(code, mod.__dict__)  # noqa: S102  # pylint: disable=exec-used

    sys.modules[module_name] = mod
    return mod


def write_yaml_to_tempfile(data, suffix='.yaml'):
    """Write data to a temporary YAML file.

    Caller is responsible for cleanup (os.unlink) after use.
    If the write fails, the temp file is removed automatically.

    Args:
        data: Data to serialize as YAML.
        suffix: File suffix for the temp file.

    Returns:
        Path to the created temporary file.
    """
    with tempfile.NamedTemporaryFile(delete=False, suffix=suffix) as tmp:
        pass
    try:
        with open(tmp.name, 'w', encoding='utf-8') as file_handle:
            yaml_dump(data, file_handle)
    except Exception:
        os.unlink(tmp.name)
        raise
    return tmp.name


def yaml_dump(data, stream=None, **kwargs):
    """Dump data as YAML, compatible with both old and new ruamel.yaml API.

    Args:
        data: Data to serialize.
        stream: File-like object to write to.
        **kwargs: Additional keyword arguments.

    Returns:
        YAML string if stream is None, else None.
    """
    if _use_legacy_ruamel_api():
        return ruamel.yaml.dump(
            data, stream,
            Dumper=ruamel.yaml.RoundTripDumper,
            default_flow_style=False, **kwargs
        )
    yaml_handler = ruamel.yaml.YAML(typ='rt')
    yaml_handler.default_flow_style = False
    if stream is None:
        buf = StringIO()
        yaml_handler.dump(data, buf)
        return buf.getvalue()
    yaml_handler.dump(data, stream)
    return None


def yaml_load(stream):
    """Load YAML data, compatible with both old and new ruamel.yaml API.

    Args:
        stream: File-like object or string to parse.

    Returns:
        Parsed data structure.
    """
    if _use_legacy_ruamel_api():
        return ruamel.yaml.load(
            stream, Loader=ruamel.yaml.RoundTripLoader
        )
    yaml_handler = ruamel.yaml.YAML(typ='rt')
    return yaml_handler.load(stream)

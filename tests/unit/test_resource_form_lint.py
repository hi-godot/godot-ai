"""Lint: every read op under a `<domain>_manage` tool must declare a resource form.

The audit (#363) caught a drift hazard: when a `<domain>_manage` rollup gains
a pure-read op, no convention required the matching `godot://...` resource
to update in lockstep. Clients that prefer URI reads silently get stale data.

This lint enforces the convention. Every op whose handler does NOT call
`require_writable` is classified as a read op and must appear in
`read_resource_forms` on its `register_manage_tool` call — either as a URI
string (declaring the matching resource) or as `None` (explicit waiver
when no resource counterpart exists). Declared URIs must resolve to an
actually-registered resource; phantom URIs (``godot://animations`` was the
motivating example) fail the lint too.

Named ``@mcp.tool`` tools all take ``session_id`` and document their resource
form in the docstring; they are out of scope for this lint per the audit's
literal "handler signature doesn't take session_id" framing.
"""

from __future__ import annotations

import ast
import inspect
import textwrap
from typing import Any

import pytest

from godot_ai.server import create_server
from godot_ai.tools._meta_tool import (
    MANAGE_TOOL_HANDLERS,
    MANAGE_TOOL_OPS,
    MANAGE_TOOL_RESOURCE_FORMS,
)


@pytest.fixture(scope="module")
def mcp():
    ## Triggers all tool + resource registrations, populating the manage-tool
    ## registries this lint walks.
    return create_server(ws_port=0)


def _handler_calls_require_writable(handler: Any) -> bool:
    """Return True if the handler's source contains a ``require_writable(...)`` call.

    AST-based so a string literal mentioning the name (or a comment) doesn't
    register as a call. Walks both bare (``require_writable(rt)``) and
    attribute (``readiness.require_writable(rt)``) call shapes — the
    latter doesn't appear in the codebase today but stays defensible.
    """
    try:
        source = inspect.getsource(handler)
    except (OSError, TypeError):
        return False

    try:
        tree = ast.parse(textwrap.dedent(source))
    except SyntaxError:
        return False

    for node in ast.walk(tree):
        if not isinstance(node, ast.Call):
            continue
        func = node.func
        if isinstance(func, ast.Name) and func.id == "require_writable":
            return True
        if isinstance(func, ast.Attribute) and func.attr == "require_writable":
            return True
    return False


async def _resource_uris(mcp_server) -> set[str]:
    """Collect all registered resource URIs and resource-template URI patterns.

    Resource templates are surfaced as URI patterns (``godot://node/{path*}/properties``)
    so a tool declaring the templated form matches the registered template
    without needing to substitute a path.
    """
    uris: set[str] = set()

    if hasattr(mcp_server, "list_resources"):
        for resource in await mcp_server.list_resources():
            uris.add(str(getattr(resource, "uri", resource)))
    elif hasattr(mcp_server, "get_resources"):
        for resource in await mcp_server.get_resources():
            uris.add(str(getattr(resource, "uri", resource)))

    list_templates = getattr(mcp_server, "list_resource_templates", None) or getattr(
        mcp_server, "get_resource_templates", None
    )
    if list_templates is not None:
        templates = await list_templates()
        if isinstance(templates, dict):
            templates = templates.values()
        for template in templates:
            for attr in ("uriTemplate", "uri_template", "uri"):
                value = getattr(template, attr, None)
                if value is not None:
                    uris.add(str(value))
                    break

    return uris


# ---------------------------------------------------------------------------
# Coverage lint
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_meta_tool_read_ops_declare_resource_form(mcp):
    """Every read op under a `<domain>_manage` tool must declare a form."""
    available_uris = await _resource_uris(mcp)

    missing: list[str] = []
    phantom: list[str] = []

    for tool_name in sorted(MANAGE_TOOL_OPS):
        forms = MANAGE_TOOL_RESOURCE_FORMS.get(tool_name, {})
        handlers = MANAGE_TOOL_HANDLERS.get(tool_name, {})
        for op_name in MANAGE_TOOL_OPS[tool_name]:
            handler = handlers.get(op_name)
            if handler is None:
                continue
            if _handler_calls_require_writable(handler):
                continue  ## write op — exempt
            if op_name not in forms:
                source_module = getattr(handler, "__module__", "<unknown>")
                source_name = getattr(handler, "__qualname__", repr(handler))
                missing.append(f"  {tool_name}.{op_name}  (handler {source_module}.{source_name})")
                continue
            form = forms[op_name]
            if form is not None and form not in available_uris:
                phantom.append(f"  {tool_name}.{op_name}  declares {form!r}")

    parts: list[str] = []
    if missing:
        parts.append(
            "Read ops below have no entry in `read_resource_forms` on their "
            "`register_manage_tool(...)` call. Add either a matching "
            "`godot://...` URI string or `None` (explicit waiver). See "
            "`tests/unit/test_resource_form_lint.py` for the convention.\n" + "\n".join(missing)
        )
    if phantom:
        parts.append(
            "Read ops below declare resource URIs that are not registered "
            "(phantom URI). Either register the resource in "
            "`src/godot_ai/resources/` or change the declaration to `None`.\n"
            "Available URIs:\n"
            + "\n".join(f"  {uri}" for uri in sorted(available_uris))
            + "\n\nDeclarations:\n"
            + "\n".join(phantom)
        )

    if parts:
        pytest.fail("\n\n".join(parts))


# ---------------------------------------------------------------------------
# Self-tests for the require_writable detector
# ---------------------------------------------------------------------------


def test_detector_flags_handler_with_require_writable():
    from godot_ai.handlers.animation import animation_player_create

    assert _handler_calls_require_writable(animation_player_create) is True


def test_detector_does_not_flag_pure_read_handler():
    from godot_ai.handlers.animation import animation_list

    assert _handler_calls_require_writable(animation_list) is False


def test_detector_ignores_string_literal_mentioning_name():
    def fake_handler(rt):
        msg = "this string mentions require_writable but never calls it"
        return {"msg": msg}

    assert _handler_calls_require_writable(fake_handler) is False


def test_detector_handles_attribute_call_shape():
    def fake_handler(rt):
        ns = type("NS", (), {"require_writable": staticmethod(lambda r: None)})
        ns.require_writable(rt)
        return {}

    assert _handler_calls_require_writable(fake_handler) is True

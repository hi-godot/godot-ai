"""Lock the registration order of FastMCP middleware in ``create_server()``.

Closes #297 finding #14: middleware order in ``server.py`` is load-bearing
but was previously undocumented and unenforced. The matching docstring lives
above the ``mcp.add_middleware(...)`` calls in ``src/godot_ai/server.py``
and explains the reasoning. This test pins the order so a reorder fails CI
with a clear diff.

Why runtime introspection rather than source-text:
``mcp.middleware`` is the authoritative ordered list FastMCP iterates when
composing the chain (``fastmcp/server/server.py::_run_middleware`` calls
``reversed(self.middleware)``). Source-text would be a weaker, drift-prone
check — a refactor that moved registration into a helper would silently
break it without changing observable behavior.
"""

from __future__ import annotations

from godot_ai.server import create_server

EXPECTED_ORDER: tuple[str, ...] = (
    "PreserveGodotCommandErrorData",
    "StripClientWrapperKwargs",
    "ParseStringifiedParams",
    "HintOpTypoOnManage",
)


def test_godot_ai_middleware_registered_in_documented_order() -> None:
    """First-added is outermost; reorder fails with the actual list named.

    Filters ``mcp.middleware`` to entries whose class lives in
    ``godot_ai.middleware.*``. FastMCP itself adds internal middleware
    (e.g. ``DereferenceRefsMiddleware`` — see ``fastmcp/server/server.py``
    around the ``DereferenceRefsMiddleware`` append in ``__init__``); the
    filter keeps this test resilient to FastMCP version bumps that change
    or extend the internal set without affecting the godot_ai chain.
    """
    mcp = create_server()
    actual = tuple(
        type(m).__name__
        for m in mcp.middleware
        if type(m).__module__.startswith("godot_ai.middleware")
    )
    assert actual == EXPECTED_ORDER, (
        "godot_ai middleware registration order drifted.\n"
        f"  expected: {list(EXPECTED_ORDER)}\n"
        f"  actual:   {list(actual)}\n"
        "If you intentionally reordered, update the docstring above the "
        "mcp.add_middleware(...) calls in src/godot_ai/server.py and "
        "update EXPECTED_ORDER here in lockstep — the order is load-bearing "
        "(see the rationale block in server.py)."
    )

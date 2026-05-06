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

Why class identities rather than name strings: importing the classes
directly hard-fails at module load if a middleware is renamed or deleted,
which is louder and earlier than a runtime assertion against a name string.
It also lets the godot_ai-vs-FastMCP-internal split be expressed by an
identity-set membership test rather than a stringly-typed module-prefix
filter.
"""

from __future__ import annotations

from godot_ai.middleware import (
    HintOpTypoOnManage,
    ParseStringifiedParams,
    PreserveGodotCommandErrorData,
    StripClientWrapperKwargs,
)
from godot_ai.server import create_server

EXPECTED_ORDER: tuple[type, ...] = (
    PreserveGodotCommandErrorData,
    StripClientWrapperKwargs,
    ParseStringifiedParams,
    HintOpTypoOnManage,
)


def test_godot_ai_middleware_registered_in_documented_order() -> None:
    """First-added is outermost; reorder fails with the actual list named.

    Filters ``mcp.middleware`` to entries whose class is one of the four
    godot_ai middleware classes. FastMCP itself adds internal middleware
    (e.g. ``DereferenceRefsMiddleware`` — see ``fastmcp/server/server.py``
    around the ``DereferenceRefsMiddleware`` append in ``__init__``); the
    identity-set filter excludes them without depending on a stringly-typed
    module prefix.
    """
    mcp = create_server()
    expected_set = set(EXPECTED_ORDER)
    actual = tuple(type(m) for m in mcp.middleware if type(m) in expected_set)
    assert actual == EXPECTED_ORDER, (
        "godot_ai middleware registration order drifted.\n"
        f"  expected: {[c.__name__ for c in EXPECTED_ORDER]}\n"
        f"  actual:   {[c.__name__ for c in actual]}\n"
        "If you intentionally reordered, update the docstring above the "
        "mcp.add_middleware(...) calls in src/godot_ai/server.py and "
        "update EXPECTED_ORDER here in lockstep — the order is load-bearing "
        "(see the rationale block in server.py)."
    )

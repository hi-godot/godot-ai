"""MCP tool for signal listing, connecting, and disconnecting."""

from __future__ import annotations

from fastmcp import FastMCP

from godot_ai.handlers import signal as signal_handlers
from godot_ai.tools._meta_tool import register_manage_tool

_DESCRIPTION = """\
Signals (Godot's event/observer mechanism) — list, connect, disconnect.

Ops:
  • list(path, include_editor=False)
        List all signals on the node and their current connections (built-in
        and custom). Editor-internal observer wiring (SceneTreeDock,
        inspector listeners) is filtered out by default; pass
        include_editor=True to include it. ``editor_connection_count`` in
        the response always reports how many connections are editor-scope —
        it's the dropped count when ``include_editor=False`` and a
        breakdown of the surfaced entries when ``include_editor=True``.
        Each connection carries ``is_editor: bool`` for per-row filtering.
        Non-Node target objects (RefCounted listeners, etc.) are treated
        as user-scope since they're typically legitimate script wiring.
  • connect(path, signal, target, method)
        Connect a signal from ``path`` to a method on the target node.
        Undoable.
  • disconnect(path, signal, target, method)
        Remove an existing connection. Undoable.
"""


def register_signal_tools(mcp: FastMCP) -> None:
    register_manage_tool(
        mcp,
        tool_name="signal_manage",
        description=_DESCRIPTION,
        ops={
            "list": signal_handlers.signal_list,
            "connect": signal_handlers.signal_connect,
            "disconnect": signal_handlers.signal_disconnect,
        },
    )

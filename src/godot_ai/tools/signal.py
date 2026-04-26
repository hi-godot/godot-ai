"""MCP tool for signal listing, connecting, and disconnecting."""

from __future__ import annotations

from fastmcp import FastMCP

from godot_ai.handlers import signal as signal_handlers
from godot_ai.tools._meta_tool import register_manage_tool

_DESCRIPTION = """\
Signals (Godot's event/observer mechanism) — list, connect, disconnect.

Ops:
  • list(path, include_editor_internal=False)
        List all signals on the node and their connections. Editor-internal
        observer connections (e.g. the SceneTree dock listening for
        ``child_order_changed``) are filtered out by default and counted in
        ``editor_connection_count``; set include_editor_internal=True to see
        them. Each connection carries an ``origin`` of ``"scene"`` (Node in
        the edited scene), ``"autoload"`` (a registered autoload),
        ``"object"`` (non-Node Object target — kept by default), or
        ``"editor"`` (filtered by default).
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

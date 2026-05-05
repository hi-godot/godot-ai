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
        and custom). By default editor-internal connections (the
        SceneTreeEditor dock and friends) are filtered out — pass
        ``include_editor=True`` to surface them. The response carries
        ``editor_connection_count`` so an agent can tell how many were hidden.
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
        read_resource_forms={
            "list": None,  ## Per-node signal listing; no aggregate resource.
        },
    )

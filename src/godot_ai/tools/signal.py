"""MCP tools for signal listing, connecting, and disconnecting."""

from __future__ import annotations

from fastmcp import Context, FastMCP

from godot_ai.handlers import signal as signal_handlers
from godot_ai.runtime.direct import DirectRuntime
from godot_ai.tools import DEFER_META


def register_signal_tools(mcp: FastMCP) -> None:
    @mcp.tool(meta=DEFER_META)
    async def signal_list(ctx: Context, path: str, session_id: str = "") -> dict:
        """List all signals (events) on a node and their current connections.

        Signals are Godot's event/observer mechanism — nodes emit signals
        that other nodes subscribe to via `signal_connect`. Returns both
        built-in and custom signals, plus any active connections.

        Args:
            path: Scene path of the node (e.g. "/Player").
            session_id: Optional Godot session to target. Empty = active session.
        """
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await signal_handlers.signal_list(runtime, path=path)

    @mcp.tool(meta=DEFER_META)
    async def signal_connect(
        ctx: Context,
        path: str,
        signal: str,
        target: str,
        method: str,
        session_id: str = "",
    ) -> dict:
        """Connect a signal from one node to a method on another (event subscription / callback).

        Creates an undoable signal connection in the scene. Equivalent
        to Godot's `Node.connect()` and the editor's Node > Signals panel.

        Args:
            path: Scene path of the source node emitting the signal.
            signal: Name of the signal to connect (e.g. "pressed", "body_entered").
            target: Scene path of the target node receiving the signal.
            method: Name of the method to call on the target node.
            session_id: Optional Godot session to target. Empty = active session.
        """
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await signal_handlers.signal_connect(
            runtime, path=path, signal=signal, target=target, method=method
        )

    @mcp.tool(meta=DEFER_META)
    async def signal_disconnect(
        ctx: Context,
        path: str,
        signal: str,
        target: str,
        method: str,
        session_id: str = "",
    ) -> dict:
        """Disconnect a signal connection between two nodes (unsubscribe an event listener).

        Removes an existing signal connection. Undoable.

        Args:
            path: Scene path of the source node.
            signal: Name of the signal to disconnect.
            target: Scene path of the target node.
            method: Name of the method that was connected.
            session_id: Optional Godot session to target. Empty = active session.
        """
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await signal_handlers.signal_disconnect(
            runtime, path=path, signal=signal, target=target, method=method
        )

"""MCP tools for signal listing, connecting, and disconnecting."""

from __future__ import annotations

from fastmcp import Context, FastMCP

from godot_ai.handlers import signal as signal_handlers
from godot_ai.runtime.direct import DirectRuntime


def register_signal_tools(mcp: FastMCP) -> None:
    @mcp.tool()
    async def signal_list(ctx: Context, path: str) -> dict:
        """List all signals on a node and their current connections.

        Returns both built-in and custom signals, plus any active
        signal connections.

        Args:
            path: Scene path of the node (e.g. "/Player").
        """
        runtime = DirectRuntime.from_context(ctx)
        return await signal_handlers.signal_list(runtime, path=path)

    @mcp.tool()
    async def signal_connect(
        ctx: Context,
        path: str,
        signal: str,
        target: str,
        method: str,
    ) -> dict:
        """Connect a signal from one node to a method on another node.

        Creates an undoable signal connection in the scene.

        Args:
            path: Scene path of the source node emitting the signal.
            signal: Name of the signal to connect (e.g. "pressed", "body_entered").
            target: Scene path of the target node receiving the signal.
            method: Name of the method to call on the target node.
        """
        runtime = DirectRuntime.from_context(ctx)
        return await signal_handlers.signal_connect(
            runtime, path=path, signal=signal, target=target, method=method
        )

    @mcp.tool()
    async def signal_disconnect(
        ctx: Context,
        path: str,
        signal: str,
        target: str,
        method: str,
    ) -> dict:
        """Disconnect a signal connection between two nodes.

        Removes an existing signal connection. Undoable.

        Args:
            path: Scene path of the source node.
            signal: Name of the signal to disconnect.
            target: Scene path of the target node.
            method: Name of the method that was connected.
        """
        runtime = DirectRuntime.from_context(ctx)
        return await signal_handlers.signal_disconnect(
            runtime, path=path, signal=signal, target=target, method=method
        )

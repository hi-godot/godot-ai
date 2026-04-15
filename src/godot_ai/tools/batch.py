"""MCP tool for batched command execution."""

from __future__ import annotations

from typing import Annotated

from fastmcp import Context, FastMCP

from godot_ai.handlers import batch as batch_handlers
from godot_ai.runtime.direct import DirectRuntime
from godot_ai.tools import DEFER_META, JsonCoerced


def register_batch_tools(mcp: FastMCP) -> None:
    @mcp.tool(meta=DEFER_META)
    async def batch_execute(
        ctx: Context,
        commands: Annotated[list[dict], JsonCoerced],
        undo: bool = True,
        session_id: str = "",
    ) -> dict:
        """Execute a list of editor sub-commands in order, stopping on first error.

        Each item must be `{"command": "<plugin_command>", "params": {...}}`.
        Use the underlying plugin command names (e.g. `create_node`, `set_property`,
        `delete_node`, `attach_script`), not the MCP tool names. Commands run
        sequentially; execution stops at the first error. When `undo` is True
        (default), any successful sub-commands are rolled back via the scene's
        undo history if a later sub-command fails, producing atomic-on-failure
        semantics.

        Use this to compose multi-step edits (create node + set property +
        attach script) into a single tool call. Rollback works for sub-commands
        that modify the currently edited scene. `batch_execute` itself is not
        allowed as a sub-command.

        Example:
            commands=[
              {"command": "create_node",
               "params": {"type": "Node3D", "name": "Enemy", "parent_path": "/Main"}},
              {"command": "set_property",
               "params": {"path": "/Main/Enemy", "property": "position",
                          "value": {"x": 5, "y": 0, "z": 0}}},
            ]

        Args:
            commands: List of `{"command": str, "params": dict}` items.
            undo: Roll back succeeded sub-commands on failure. Default True.
            session_id: Optional Godot session to target. Empty = active session.

        Returns a dict with `succeeded` (count), `stopped_at` (failing index
        or null), `results` (per-sub-command status/data/error), `rolled_back`
        (whether rollback was performed), and `undoable` (whether the batch
        can be undone as a whole).
        """
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await batch_handlers.batch_execute(
            runtime,
            commands=commands,
            undo=undo,
        )

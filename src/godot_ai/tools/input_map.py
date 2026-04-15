"""MCP tools for managing Godot input map actions and bindings."""

from __future__ import annotations

from fastmcp import Context, FastMCP

from godot_ai.handlers import input_map as input_map_handlers
from godot_ai.runtime.direct import DirectRuntime
from godot_ai.tools import DEFER_META


def register_input_map_tools(mcp: FastMCP) -> None:
    @mcp.tool(meta=DEFER_META)
    async def input_map_list(
        ctx: Context,
        include_builtin: bool = False,
        session_id: str = "",
    ) -> dict:
        """List all input actions (keybindings / control mappings) and their bound events.

        By default returns only project-defined actions. Set
        include_builtin=true to also include Godot's built-in ui_*
        actions.

        Args:
            include_builtin: Include built-in ui_* actions. Default false.
            session_id: Optional Godot session to target. Empty = active session.
        """
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await input_map_handlers.input_map_list(runtime, include_builtin=include_builtin)

    @mcp.tool(meta=DEFER_META)
    async def input_map_add_action(
        ctx: Context,
        action: str,
        deadzone: float = 0.5,
        session_id: str = "",
    ) -> dict:
        """Create a new input action (named keybinding / control slot like "jump" or "move_left").

        Adds an empty input action that can have events bound to it.
        Saved to project.godot.

        Args:
            action: Name for the action (e.g. "move_left", "jump", "attack").
            deadzone: Analog deadzone threshold. Default 0.5.
            session_id: Optional Godot session to target. Empty = active session.
        """
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await input_map_handlers.input_map_add_action(
            runtime, action=action, deadzone=deadzone
        )

    @mcp.tool(meta=DEFER_META)
    async def input_map_remove_action(
        ctx: Context,
        action: str,
        session_id: str = "",
    ) -> dict:
        """Remove an input action and all its bindings.

        Erases the action from InputMap and project.godot.

        Args:
            action: Name of the action to remove.
            session_id: Optional Godot session to target. Empty = active session.
        """
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await input_map_handlers.input_map_remove_action(runtime, action=action)

    @mcp.tool(meta=DEFER_META)
    async def input_map_bind_event(
        ctx: Context,
        action: str,
        event_type: str,
        keycode: str = "",
        ctrl: bool = False,
        alt: bool = False,
        shift: bool = False,
        meta: bool = False,
        button: int | None = None,
        session_id: str = "",
    ) -> dict:
        """Bind keyboard / mouse / gamepad input to an action (configure controls / keybindings).

        Adds the event to an existing action. Saved to project.godot.

        Args:
            action: Name of the action to bind to.
            event_type: One of "key", "mouse_button", or "joy_button".
            keycode: Key name for "key" events (e.g. "W", "Space", "Escape").
            ctrl: Require Ctrl modifier (key events only).
            alt: Require Alt modifier (key events only).
            shift: Require Shift modifier (key events only).
            meta: Require Meta/Cmd modifier (key events only).
            button: Button index for mouse_button (1=left, 2=right) or
                joy_button (0=A/Cross) events. Required for non-key events.
            session_id: Optional Godot session to target. Empty = active session.
        """
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        kwargs = {}
        if keycode:
            kwargs["keycode"] = keycode
        if ctrl:
            kwargs["ctrl"] = ctrl
        if alt:
            kwargs["alt"] = alt
        if shift:
            kwargs["shift"] = shift
        if meta:
            kwargs["meta"] = meta
        if button is not None:
            kwargs["button"] = button
        return await input_map_handlers.input_map_bind_event(
            runtime, action=action, event_type=event_type, **kwargs
        )

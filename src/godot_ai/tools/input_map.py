"""MCP tool for input map (keybinding / control) management."""

from __future__ import annotations

from fastmcp import FastMCP

from godot_ai.handlers import input_map as input_map_handlers
from godot_ai.tools._meta_tool import register_manage_tool

_DESCRIPTION = """\
InputMap actions and bindings (keyboard, mouse, gamepad). Persisted to
``project.godot``.

Resource form: ``godot://input_map`` — prefer for active-session reads.

Ops:
  • list(include_builtin=False)
        List input actions and their bound events. Set include_builtin=True
        to include Godot's built-in ``ui_*`` actions.
  • add_action(action, deadzone=0.5)
        Create a new empty input action.
  • remove_action(action)
        Remove an action and all its event bindings.
  • bind_event(action, event_type, keycode="", ctrl=False, alt=False,
                shift=False, meta=False, button=None)
        Bind a key/mouse/gamepad event to an action. event_type is
        "key" | "mouse_button" | "joy_button". keycode is required for
        "key"; button is required for the others.
"""


def register_input_map_tools(mcp: FastMCP) -> None:
    register_manage_tool(
        mcp,
        tool_name="input_map_manage",
        description=_DESCRIPTION,
        ops={
            "list": input_map_handlers.input_map_list,
            "add_action": input_map_handlers.input_map_add_action,
            "remove_action": input_map_handlers.input_map_remove_action,
            "bind_event": input_map_handlers.input_map_bind_event,
        },
    )

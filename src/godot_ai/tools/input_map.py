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
        List input actions and their bound events. By default only
        user-authored actions (those persisted in ``project.godot`` under
        ``input/<name>``) are returned; pass ``include_builtin=True`` to
        also surface Godot's ``ui_*`` and editor-runtime actions
        (``spatial_editor/*``, etc.). The ``is_builtin`` field on each
        entry is true for any action not authored by the user.
  • add_action(action, deadzone=0.5)
        Create a new empty input action. ``deadzone`` must be in
        ``[0.0, 1.0]`` — Godot uses it as the analog-stick dead-zone
        threshold; values outside this range are rejected with
        ``VALUE_OUT_OF_RANGE``. Typical values are 0.2-0.5; leave the
        default 0.5 unless you have a reason. Not a key-repeat delay.
  • ensure_action(action, deadzone=0.5)
        Idempotently create or persist an input action. If the action exists
        in live InputMap or in project.godot, the existing state is preserved.
  • remove_action(action)
        Remove an action and all its event bindings. Also removes actions
        persisted in project.godot but not loaded in the live InputMap
        (``loaded_in_input_map: false`` in ``list``), e.g. actions created
        by a previous editor session.
  • bind_event(action, event_type, keycode="", ctrl=False, alt=False,
                shift=False, meta=False, button=None, axis=None,
                axis_value=1.0)
        Bind a key/mouse/gamepad event to an action. The action must
        already exist (call ``add_action`` first). ``event_type`` is
        ``"key"`` | ``"mouse_button"`` | ``"joy_button"`` |
        ``"joy_axis"``.
          - ``key``: ``keycode`` is a Godot keycode *name string* like
            ``"A"``, ``"Space"``, ``"Enter"``, ``"Escape"``, ``"F1"``,
            ``"Left"`` — not an integer and not ``KEY_*``. Modifier
            booleans ``ctrl`` / ``alt`` / ``shift`` / ``meta`` optional.
          - ``mouse_button``: ``button`` is an int — 1=left, 2=right,
            3=middle, 4=wheel up, 5=wheel down.
          - ``joy_button``: ``button`` is the ``JoyButton`` index
            (e.g. 0=A/Cross, 1=B/Circle).
          - ``joy_axis``: ``axis`` is the ``JoyAxis`` index and
            ``axis_value`` is the direction/value, usually -1.0 or 1.0.
  • ensure_binding(action, event_type, ...)
        Idempotently ensure the action exists and has the requested binding.
"""


def register_input_map_tools(mcp: FastMCP) -> None:
    register_manage_tool(
        mcp,
        tool_name="input_map_manage",
        description=_DESCRIPTION,
        ops={
            "list": input_map_handlers.input_map_list,
            "add_action": input_map_handlers.input_map_add_action,
            "ensure_action": input_map_handlers.input_map_ensure_action,
            "remove_action": input_map_handlers.input_map_remove_action,
            "bind_event": input_map_handlers.input_map_bind_event,
            "ensure_binding": input_map_handlers.input_map_ensure_binding,
        },
        read_resource_forms={
            "list": "godot://input_map",
        },
    )

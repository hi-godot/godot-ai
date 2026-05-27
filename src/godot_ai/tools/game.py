"""MCP tools for runtime game inspection and input."""

from __future__ import annotations

from fastmcp import FastMCP

from godot_ai.handlers import game as game_handlers
from godot_ai.tools._meta_tool import register_manage_tool

_DESCRIPTION = """\
Runtime game inspection and input simulation.

These ops target the running game process through Godot's EngineDebugger
bridge. Start the project first with project_run and poll editor_state until
game_capture_ready=true.

Ops:
  - get_scene_tree(depth=10, root_path="")
        Inspect the running scene tree. root_path accepts an absolute runtime
        path or a scene-relative path rooted at the current scene.
  - get_node_info(path, include_properties=True)
        Inspect one running node's metadata and optional property snapshot.
  - input_key(key, pressed=True, echo=False)
        Send a key press/release to the running game.
  - input_mouse(event, position=None, button="left", pressed=True)
        Send a mouse motion or button event. event: "motion" | "button".
  - input_gamepad(device=0, control="button", index=0, pressed=True, value=0.0)
        Send a joypad button or axis event. control: "button" | "axis".
  - input_state(actions=None)
        Read current action pressed states. Empty actions = all project actions."""


def register_game_tools(mcp: FastMCP) -> None:
    register_manage_tool(
        mcp,
        tool_name="game_manage",
        description=_DESCRIPTION,
        ops={
            "get_scene_tree": game_handlers.game_get_scene_tree,
            "get_node_info": game_handlers.game_get_node_info,
            "input_key": game_handlers.game_input_key,
            "input_mouse": game_handlers.game_input_mouse,
            "input_gamepad": game_handlers.game_input_gamepad,
            "input_state": game_handlers.game_input_state,
        },
        read_resource_forms={
            "get_scene_tree": None,
            "get_node_info": None,
            "input_key": None,
            "input_mouse": None,
            "input_gamepad": None,
            "input_state": None,
        },
    )

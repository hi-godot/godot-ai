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
  - get_ui_elements(root_path="", include_hidden=False,
                    include_disabled=True, max_depth=10)
        Inspect visible runtime Control nodes for UI testing. Includes path,
        type, text where present, disabled state, and rect metadata.
  - suspend()
        Suspend the running game through Godot's embedded Game View debugger.
  - resume()
        Resume a suspended game. Idempotent when it is already running.
  - next_frame()
        Advance exactly one process tick while suspended. Returns the tick
        target to verify with debug_status(). May focus the embedded Game View;
        any focus handoff is reported explicitly in the response.
  - debug_status()
        Probe suspend state and the game-helper process tick counter through
        the debugger capture, including while SceneTree processing is suspended.
  - input_key(key, pressed=True, echo=False)
        Send a key press/release to the running game.
  - input_mouse(event, position=None, button="left", pressed=True)
        Send a mouse motion or button event. event: "motion" | "button".
        position is a {x, y} object or [x, y] array; omit it to use the
        game's current cursor position. A present but malformed position is
        rejected rather than silently falling back to the cursor.
  - input_gamepad(device=0, control="button", index=0, pressed=True, value=0.0)
        Send a joypad button or axis event. control: "button" | "axis".
  - input_action(action, pressed=True, strength=1.0)
        Set a project action's pressed state directly in the running game.
  - input_sequence(steps, settle_frames=0)
        Apply a frame-timed action timeline in one call — the frame-accurate,
        multi-step form of input_action. Each step is
        {at_frame, action, pressed=True, strength=1.0}; the game applies each
        step's action on its scheduled frame, awaits settle_frames more, then
        replies once. Use this instead of separate input_action calls whenever
        timing matters (jump arcs, combos, walk-into-trigger): per-call network
        latency makes hitting a target frame impossible otherwise. Steps must
        be ordered by non-decreasing at_frame; frames (not ms) are the timing
        basis. Action-based input is focus-independent, so it works on a
        backgrounded game window. Cannot run inside batch_execute.
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
            "get_ui_elements": game_handlers.game_get_ui_elements,
            "suspend": game_handlers.game_suspend,
            "resume": game_handlers.game_resume,
            "next_frame": game_handlers.game_next_frame,
            "debug_status": game_handlers.game_debug_status,
            "input_key": game_handlers.game_input_key,
            "input_mouse": game_handlers.game_input_mouse,
            "input_gamepad": game_handlers.game_input_gamepad,
            "input_action": game_handlers.game_input_action,
            "input_sequence": game_handlers.game_input_sequence,
            "input_state": game_handlers.game_input_state,
        },
        read_resource_forms={
            "get_scene_tree": None,
            "get_node_info": None,
            "get_ui_elements": None,
            "suspend": None,
            "resume": None,
            "next_frame": None,
            "debug_status": None,
            "input_key": None,
            "input_mouse": None,
            "input_gamepad": None,
            "input_action": None,
            "input_sequence": None,
            "input_state": None,
        },
    )

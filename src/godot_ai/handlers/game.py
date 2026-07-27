"""Shared handlers for runtime game tools."""

from __future__ import annotations

from typing import Any

from godot_ai.godot_client.client import GodotCommandError
from godot_ai.protocol.errors import ErrorCode
from godot_ai.runtime.direct import DirectRuntime

GAME_COMMAND_TIMEOUT_SEC = 15.0

## input_sequence drives the game forward one frame per step, so its reply
## legitimately takes seconds — it gets a wider client timeout than the
## one-shot ops, matched by the plugin's INPUT_SEQUENCE_TIMEOUT_SEC and the
## dispatcher's per-request deferred budget.
INPUT_SEQUENCE_TIMEOUT_SEC = 30.0

## Bounds on a single input_sequence, mirrored by the plugin
## (GameHelper.MAX_SEQUENCE_STEPS / MAX_SEQUENCE_FRAMES). Rejecting here keeps
## a runaway `at_frame` from holding the deferred response open indefinitely.
MAX_SEQUENCE_STEPS = 256
MAX_SEQUENCE_FRAMES = 600


async def _game_command(runtime: DirectRuntime, op: str, params: dict[str, Any]) -> dict:
    return await runtime.send_command(
        "game_command",
        {"op": op, "params": params},
        timeout=GAME_COMMAND_TIMEOUT_SEC,
    )


async def game_get_scene_tree(
    runtime: DirectRuntime,
    depth: int = 10,
    root_path: str = "",
) -> dict:
    params: dict[str, Any] = {"depth": depth}
    if root_path:
        params["root_path"] = root_path
    return await _game_command(runtime, "get_scene_tree", params)


async def game_get_node_info(
    runtime: DirectRuntime,
    path: str,
    include_properties: bool = True,
) -> dict:
    return await _game_command(
        runtime,
        "get_node_info",
        {"path": path, "include_properties": include_properties},
    )


async def game_get_ui_elements(
    runtime: DirectRuntime,
    root_path: str = "",
    include_hidden: bool = False,
    include_disabled: bool = True,
    max_depth: int = 10,
) -> dict:
    params: dict[str, Any] = {
        "include_hidden": include_hidden,
        "include_disabled": include_disabled,
        "max_depth": max_depth,
    }
    if root_path:
        params["root_path"] = root_path
    return await _game_command(runtime, "get_ui_elements", params)


async def game_input_key(
    runtime: DirectRuntime,
    key: str,
    pressed: bool = True,
    echo: bool = False,
) -> dict:
    return await _game_command(
        runtime,
        "input_key",
        {"key": key, "pressed": pressed, "echo": echo},
    )


async def game_input_mouse(
    runtime: DirectRuntime,
    event: str,
    position: dict[str, Any] | None = None,
    button: str = "left",
    pressed: bool = True,
) -> dict:
    params: dict[str, Any] = {
        "event": event,
        "position": position or {},
        "button": button,
        "pressed": pressed,
    }
    return await _game_command(runtime, "input_mouse", params)


async def game_input_gamepad(
    runtime: DirectRuntime,
    device: int = 0,
    control: str = "button",
    index: int = 0,
    pressed: bool = True,
    value: float = 0.0,
) -> dict:
    params: dict[str, Any] = {
        "device": device,
        "control": control,
        "index": index,
    }
    if control == "axis":
        params["value"] = value
    else:
        params["pressed"] = pressed
    return await _game_command(runtime, "input_gamepad", params)


async def game_input_action(
    runtime: DirectRuntime,
    action: str,
    pressed: bool = True,
    strength: float = 1.0,
) -> dict:
    return await _game_command(
        runtime,
        "input_action",
        {"action": action, "pressed": pressed, "strength": strength},
    )


async def game_input_state(
    runtime: DirectRuntime,
    actions: list[str] | None = None,
) -> dict:
    params: dict[str, Any] = {}
    if actions is not None:
        params["actions"] = actions
    return await _game_command(runtime, "input_state", params)


def _invalid_params(message: str) -> GodotCommandError:
    return GodotCommandError(code=ErrorCode.INVALID_PARAMS, message=message)


def _validate_input_sequence(
    steps: list[dict[str, Any]], settle_frames: int
) -> list[dict[str, Any]]:
    """Reject the cases the plugin can't safely absorb, up front and clearly.

    Frames only for v1 (deterministic, reproducible). Steps must be ordered by
    ``at_frame`` and stay within the frame/step caps so a large ``at_frame``
    can't hold the deferred reply open indefinitely. Returns the normalized
    step list to forward to the game.
    """
    if not isinstance(steps, list) or not steps:
        raise _invalid_params("steps must be a non-empty list")
    if len(steps) > MAX_SEQUENCE_STEPS:
        raise _invalid_params(f"steps exceeds the {MAX_SEQUENCE_STEPS}-step cap (got {len(steps)})")
    if not isinstance(settle_frames, int) or settle_frames < 0:
        raise _invalid_params("settle_frames must be an integer >= 0")

    normalized: list[dict[str, Any]] = []
    prev_frame = -1
    for i, step in enumerate(steps):
        if not isinstance(step, dict):
            raise _invalid_params(f"steps[{i}] must be an object")
        action = step.get("action")
        if not isinstance(action, str) or not action:
            raise _invalid_params(f"steps[{i}].action is required and must be a non-empty string")
        at_frame = step.get("at_frame", 0)
        if not isinstance(at_frame, int) or isinstance(at_frame, bool) or at_frame < 0:
            raise _invalid_params(f"steps[{i}].at_frame must be an integer >= 0")
        if at_frame < prev_frame:
            raise _invalid_params(
                f"steps must be ordered by at_frame (steps[{i}]={at_frame} < previous {prev_frame})"
            )
        prev_frame = at_frame
        normalized.append(
            {
                "at_frame": at_frame,
                "action": action,
                "pressed": bool(step.get("pressed", True)),
                "strength": float(step.get("strength", 1.0)),
            }
        )

    span = normalized[-1]["at_frame"] + settle_frames
    if span > MAX_SEQUENCE_FRAMES:
        raise _invalid_params(
            f"sequence spans {span} frames, exceeds the {MAX_SEQUENCE_FRAMES}-frame cap"
        )
    return normalized


async def game_input_sequence(
    runtime: DirectRuntime,
    steps: list[dict[str, Any]],
    settle_frames: int = 0,
) -> dict:
    """Apply a frame-timed action timeline in the running game in one call.

    Each step is ``{at_frame, action, pressed=True, strength=1.0}``; the game
    applies each step's action on its scheduled frame, awaits ``settle_frames``
    more, then replies once. See ``game_input_action`` for the per-step
    semantics — this is the frame-accurate, multi-step form.
    """
    normalized = _validate_input_sequence(steps, settle_frames)
    return await runtime.send_command(
        "game_command",
        {
            "op": "input_sequence",
            "params": {"steps": normalized, "settle_frames": settle_frames},
        },
        timeout=INPUT_SEQUENCE_TIMEOUT_SEC,
    )

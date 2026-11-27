"""Shared handlers for runtime game tools."""

from __future__ import annotations

from typing import Any

from godot_ai.godot_client.client import GodotCommandError
from godot_ai.protocol.errors import ErrorCode
from godot_ai.runtime.direct import DirectRuntime

GAME_COMMAND_TIMEOUT_SEC = 15.0
# The editor owns a 5s action timer and the dispatcher allows 6.5s. The MCP
# client must outlive both so their structured result wins over transport timeout.
GAME_DEBUG_TIMEOUT_SEC = 8.0

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

## Bounds on a single type_text payload, mirrored by the plugin
## (GameHelper.MAX_TYPE_TEXT_LENGTH) so one call cannot stall the main thread.
MAX_TYPE_TEXT_LENGTH = 4096  # mirrored cap; plugin side at plugin/addons/godot_ai/runtime/game_helper.gd


async def _game_command(runtime: DirectRuntime, op: str, params: dict[str, Any]) -> dict:
    return await runtime.send_command(
        "game_command",
        {"op": op, "params": params},
        timeout=GAME_COMMAND_TIMEOUT_SEC,
    )


async def _game_debug_control(runtime: DirectRuntime, action: str) -> dict:
    return await runtime.send_command(
        "game_debug_control", {"action": action}, timeout=GAME_DEBUG_TIMEOUT_SEC
    )


async def game_suspend(runtime: DirectRuntime) -> dict:
    return await _game_debug_control(runtime, "suspend")


async def game_resume(runtime: DirectRuntime) -> dict:
    return await _game_debug_control(runtime, "resume")


async def game_next_frame(runtime: DirectRuntime) -> dict:
    return await _game_debug_control(runtime, "next_frame")


async def game_debug_status(runtime: DirectRuntime) -> dict:
    return await _game_debug_control(runtime, "debug_status")


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


# Unicode scalar space and surrogate bounds, source https://www.unicode.org/glossary/
MAX_CODEPOINT = 0x10FFFF
SURROGATE_MIN = 0xD800
SURROGATE_MAX = 0xDFFF
# ASCII C0 control block and DEL, chart U0000
ASCII_CONTROL_MAX = 32  # https://www.unicode.org/charts/PDF/U0000.pdf
DEL_CODEPOINT = 127  # https://www.unicode.org/charts/PDF/U0000.pdf


def _normalize_unicode(unicode: int | str) -> int:
    """Validate and convert an input_key ``unicode`` value to an integer codepoint."""
    if isinstance(unicode, str):
        if len(unicode) != 1:
            raise _invalid_params(
                f"unicode string must be a single character (got length {len(unicode)}); "
                "use op='type_text' to type multi-character strings"
            )
        codepoint = ord(unicode)
    elif isinstance(unicode, int) and not isinstance(unicode, bool):
        codepoint = unicode
    else:
        raise _invalid_params(
            f"unicode must be an integer codepoint or single-character string (got {type(unicode).__name__})"
        )
    if codepoint < 0 or codepoint > MAX_CODEPOINT or (SURROGATE_MIN <= codepoint <= SURROGATE_MAX):
        raise _invalid_params(f"unicode codepoint out of range: {codepoint}")
    return codepoint


async def game_input_key(
    runtime: DirectRuntime,
    key: str = "",
    pressed: bool = True,
    echo: bool = False,
    unicode: int | str | None = None,
) -> dict:
    params: dict[str, Any] = {"key": key, "pressed": pressed, "echo": echo}
    if unicode is None:
        if not key:
            raise _invalid_params("key is required when unicode is not provided")
    else:
        codepoint = _normalize_unicode(unicode)
        if not key and codepoint == 0:
            raise _invalid_params("key or a non-zero unicode codepoint is required")
        params["unicode"] = codepoint
    return await _game_command(runtime, "input_key", params)


async def game_type_text(
    runtime: DirectRuntime,
    text: str,
    submit: bool = False,
) -> dict:
    """Type a string into the running game's currently focused text control."""
    if not isinstance(text, str) or not text:
        raise _invalid_params("text must be a non-empty string")
    if len(text) > MAX_TYPE_TEXT_LENGTH:
        raise _invalid_params(
            f"text exceeds the {MAX_TYPE_TEXT_LENGTH}-character cap (got {len(text)})"
        )
    if not isinstance(submit, bool):
        raise _invalid_params("submit must be a boolean")
    for ch in text:
        cp = ord(ch)
        if (cp < ASCII_CONTROL_MAX and ch not in ("\n", "\r", "\t")) or cp == DEL_CODEPOINT or (SURROGATE_MIN <= cp <= SURROGATE_MAX):
            raise _invalid_params(f"Unsupported control character U+{cp:04X} in text")
    return await _game_command(runtime, "type_text", {"text": text, "submit": submit})


async def game_input_mouse(
    runtime: DirectRuntime,
    event: str,
    position: dict[str, Any] | None = None,
    button: str = "left",
    pressed: bool = True,
    buttons: list[str] | None = None,
) -> dict:
    params: dict[str, Any] = {
        "event": event,
        "position": position or {},
        "button": button,
        "pressed": pressed,
    }
    if buttons is not None:
        params["buttons"] = buttons
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
    if not isinstance(settle_frames, int) or isinstance(settle_frames, bool) or settle_frames < 0:
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

        ## Validate rather than coerce: bool(step["pressed"]) would turn the
        ## string "false" into True, and float(step["strength"]) on a bad
        ## value would escape as an internal error instead of INVALID_PARAMS.
        pressed = step.get("pressed", True)
        if not isinstance(pressed, bool):
            raise _invalid_params(f"steps[{i}].pressed must be a boolean")
        strength = step.get("strength", 1.0)
        if isinstance(strength, bool) or not isinstance(strength, (int, float)):
            raise _invalid_params(f"steps[{i}].strength must be a number")
        ## Clamp to [0, 1] to match the plugin's input_action semantics.
        strength = max(0.0, min(1.0, float(strength)))

        normalized.append(
            {
                "at_frame": at_frame,
                "action": action,
                "pressed": pressed,
                "strength": strength,
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

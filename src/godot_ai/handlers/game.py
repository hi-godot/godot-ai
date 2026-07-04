"""Shared handlers for runtime game tools."""

from __future__ import annotations

from typing import Any

from godot_ai.runtime.direct import DirectRuntime

GAME_COMMAND_TIMEOUT_SEC = 15.0


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

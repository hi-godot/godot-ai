"""Shared handlers for Camera2D / Camera3D authoring."""

from __future__ import annotations

from typing import Any

from godot_ai.handlers._readiness import require_writable
from godot_ai.runtime.interface import Runtime


async def camera_create(
    runtime: Runtime,
    parent_path: str,
    name: str = "Camera",
    type: str = "2d",
    make_current: bool = False,
) -> dict:
    require_writable(runtime)
    return await runtime.send_command(
        "camera_create",
        {
            "parent_path": parent_path,
            "name": name,
            "type": type,
            "make_current": make_current,
        },
    )


async def camera_configure(
    runtime: Runtime,
    camera_path: str,
    properties: dict[str, Any],
) -> dict:
    require_writable(runtime)
    return await runtime.send_command(
        "camera_configure",
        {"camera_path": camera_path, "properties": properties},
    )


async def camera_set_limits_2d(
    runtime: Runtime,
    camera_path: str,
    left: int | None = None,
    right: int | None = None,
    top: int | None = None,
    bottom: int | None = None,
    smoothed: bool | None = None,
) -> dict:
    require_writable(runtime)
    params: dict[str, Any] = {"camera_path": camera_path}
    if left is not None:
        params["left"] = left
    if right is not None:
        params["right"] = right
    if top is not None:
        params["top"] = top
    if bottom is not None:
        params["bottom"] = bottom
    if smoothed is not None:
        params["smoothed"] = smoothed
    return await runtime.send_command("camera_set_limits_2d", params)


async def camera_set_damping_2d(
    runtime: Runtime,
    camera_path: str,
    position_speed: float | None = None,
    rotation_speed: float | None = None,
    drag_margins: dict[str, float] | None = None,
    drag_horizontal_enabled: bool | None = None,
    drag_vertical_enabled: bool | None = None,
) -> dict:
    require_writable(runtime)
    params: dict[str, Any] = {"camera_path": camera_path}
    if position_speed is not None:
        params["position_speed"] = position_speed
    if rotation_speed is not None:
        params["rotation_speed"] = rotation_speed
    if drag_margins is not None:
        params["drag_margins"] = drag_margins
    if drag_horizontal_enabled is not None:
        params["drag_horizontal_enabled"] = drag_horizontal_enabled
    if drag_vertical_enabled is not None:
        params["drag_vertical_enabled"] = drag_vertical_enabled
    return await runtime.send_command("camera_set_damping_2d", params)


async def camera_follow_2d(
    runtime: Runtime,
    camera_path: str,
    target_path: str,
    smoothing_speed: float = 5.0,
    zero_transform: bool = True,
) -> dict:
    require_writable(runtime)
    return await runtime.send_command(
        "camera_follow_2d",
        {
            "camera_path": camera_path,
            "target_path": target_path,
            "smoothing_speed": smoothing_speed,
            "zero_transform": zero_transform,
        },
    )


async def camera_get(runtime: Runtime, camera_path: str = "") -> dict:
    return await runtime.send_command("camera_get", {"camera_path": camera_path})


async def camera_list(runtime: Runtime) -> dict:
    return await runtime.send_command("camera_list", {})


async def camera_apply_preset(
    runtime: Runtime,
    parent_path: str,
    name: str,
    preset: str,
    type: str | None = None,
    make_current: bool = True,
    overrides: dict[str, Any] | None = None,
) -> dict:
    require_writable(runtime)
    params: dict[str, Any] = {
        "parent_path": parent_path,
        "name": name,
        "preset": preset,
        "make_current": make_current,
    }
    if type is not None:
        params["type"] = type
    if overrides:
        params["overrides"] = overrides
    return await runtime.send_command("camera_apply_preset", params)

"""Shared handlers for AnimationPlayer authoring (tracks, keyframes, autoplay)."""

from __future__ import annotations

from typing import Any

from godot_ai.handlers._readiness import require_writable
from godot_ai.runtime.interface import Runtime


async def animation_player_create(
    runtime: Runtime,
    parent_path: str,
    name: str = "AnimationPlayer",
) -> dict:
    require_writable(runtime)
    return await runtime.send_command(
        "animation_player_create",
        {"parent_path": parent_path, "name": name},
    )


async def animation_create(
    runtime: Runtime,
    player_path: str,
    name: str,
    length: float,
    loop_mode: str = "none",
    overwrite: bool = False,
) -> dict:
    require_writable(runtime)
    params: dict = {
        "player_path": player_path,
        "name": name,
        "length": length,
        "loop_mode": loop_mode,
    }
    if overwrite:
        params["overwrite"] = True
    return await runtime.send_command("animation_create", params)


async def animation_add_property_track(
    runtime: Runtime,
    player_path: str,
    animation_name: str,
    track_path: str,
    keyframes: list[dict],
    interpolation: str = "linear",
) -> dict:
    require_writable(runtime)
    return await runtime.send_command(
        "animation_add_property_track",
        {
            "player_path": player_path,
            "animation_name": animation_name,
            "track_path": track_path,
            "keyframes": keyframes,
            "interpolation": interpolation,
        },
    )


async def animation_add_method_track(
    runtime: Runtime,
    player_path: str,
    animation_name: str,
    target_node_path: str,
    keyframes: list[dict],
) -> dict:
    require_writable(runtime)
    return await runtime.send_command(
        "animation_add_method_track",
        {
            "player_path": player_path,
            "animation_name": animation_name,
            "target_node_path": target_node_path,
            "keyframes": keyframes,
        },
    )


async def animation_set_autoplay(
    runtime: Runtime,
    player_path: str,
    animation_name: str = "",
) -> dict:
    require_writable(runtime)
    return await runtime.send_command(
        "animation_set_autoplay",
        {"player_path": player_path, "animation_name": animation_name},
    )


async def animation_play(
    runtime: Runtime,
    player_path: str,
    animation_name: str = "",
) -> dict:
    return await runtime.send_command(
        "animation_play",
        {"player_path": player_path, "animation_name": animation_name},
    )


async def animation_stop(
    runtime: Runtime,
    player_path: str,
) -> dict:
    return await runtime.send_command(
        "animation_stop",
        {"player_path": player_path},
    )


async def animation_list(
    runtime: Runtime,
    player_path: str,
) -> dict:
    return await runtime.send_command(
        "animation_list",
        {"player_path": player_path},
    )


async def animation_get(
    runtime: Runtime,
    player_path: str,
    animation_name: str,
) -> dict:
    return await runtime.send_command(
        "animation_get",
        {"player_path": player_path, "animation_name": animation_name},
    )


async def animation_delete(
    runtime: Runtime,
    player_path: str,
    animation_name: str,
) -> dict:
    require_writable(runtime)
    return await runtime.send_command(
        "animation_delete",
        {"player_path": player_path, "animation_name": animation_name},
    )


async def animation_validate(
    runtime: Runtime,
    player_path: str,
    animation_name: str,
) -> dict:
    # Read-only — no require_writable.
    return await runtime.send_command(
        "animation_validate",
        {"player_path": player_path, "animation_name": animation_name},
    )


async def animation_create_simple(
    runtime: Runtime,
    player_path: str,
    name: str,
    tweens: list[dict[str, Any]],
    length: float | None = None,
    loop_mode: str = "none",
    overwrite: bool = False,
) -> dict:
    require_writable(runtime)
    params: dict[str, Any] = {
        "player_path": player_path,
        "name": name,
        "tweens": tweens,
        "loop_mode": loop_mode,
    }
    if length is not None:
        params["length"] = length
    if overwrite:
        params["overwrite"] = True
    return await runtime.send_command("animation_create_simple", params)

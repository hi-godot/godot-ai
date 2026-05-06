"""Shared handlers for AnimationPlayer authoring (tracks, keyframes, autoplay)."""

from __future__ import annotations

from typing import Any

from godot_ai.handlers._readiness import require_writable
from godot_ai.runtime.direct import DirectRuntime


async def animation_player_create(
    runtime: DirectRuntime,
    parent_path: str,
    name: str = "AnimationPlayer",
) -> dict:
    require_writable(runtime)
    return await runtime.send_command(
        "animation_player_create",
        {"parent_path": parent_path, "name": name},
    )


async def animation_create(
    runtime: DirectRuntime,
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
    runtime: DirectRuntime,
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
    runtime: DirectRuntime,
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
    runtime: DirectRuntime,
    player_path: str,
    animation_name: str = "",
) -> dict:
    require_writable(runtime)
    return await runtime.send_command(
        "animation_set_autoplay",
        {"player_path": player_path, "animation_name": animation_name},
    )


async def animation_play(
    runtime: DirectRuntime,
    player_path: str,
    animation_name: str = "",
) -> dict:
    return await runtime.send_command(
        "animation_play",
        {"player_path": player_path, "animation_name": animation_name},
    )


async def animation_stop(
    runtime: DirectRuntime,
    player_path: str,
) -> dict:
    return await runtime.send_command(
        "animation_stop",
        {"player_path": player_path},
    )


async def animation_list(
    runtime: DirectRuntime,
    player_path: str,
) -> dict:
    return await runtime.send_command(
        "animation_list",
        {"player_path": player_path},
    )


async def animation_get(
    runtime: DirectRuntime,
    player_path: str,
    animation_name: str,
) -> dict:
    return await runtime.send_command(
        "animation_get",
        {"player_path": player_path, "animation_name": animation_name},
    )


async def animation_delete(
    runtime: DirectRuntime,
    player_path: str,
    animation_name: str,
) -> dict:
    require_writable(runtime)
    return await runtime.send_command(
        "animation_delete",
        {"player_path": player_path, "animation_name": animation_name},
    )


async def animation_validate(
    runtime: DirectRuntime,
    player_path: str,
    animation_name: str,
) -> dict:
    # Read-only — no require_writable.
    return await runtime.send_command(
        "animation_validate",
        {"player_path": player_path, "animation_name": animation_name},
    )


async def animation_create_simple(
    runtime: DirectRuntime,
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


async def animation_preset_fade(
    runtime: DirectRuntime,
    player_path: str,
    target_path: str,
    mode: str = "in",
    duration: float = 0.5,
    animation_name: str = "",
    overwrite: bool = False,
) -> dict:
    require_writable(runtime)
    params: dict[str, Any] = {
        "player_path": player_path,
        "target_path": target_path,
        "mode": mode,
        "duration": duration,
    }
    if animation_name:
        params["animation_name"] = animation_name
    if overwrite:
        params["overwrite"] = True
    return await runtime.send_command("animation_preset_fade", params)


async def animation_preset_slide(
    runtime: DirectRuntime,
    player_path: str,
    target_path: str,
    direction: str = "left",
    mode: str = "in",
    distance: float | None = None,
    duration: float = 0.4,
    animation_name: str = "",
    overwrite: bool = False,
) -> dict:
    require_writable(runtime)
    params: dict[str, Any] = {
        "player_path": player_path,
        "target_path": target_path,
        "direction": direction,
        "mode": mode,
        "duration": duration,
    }
    if distance is not None:
        params["distance"] = distance
    if animation_name:
        params["animation_name"] = animation_name
    if overwrite:
        params["overwrite"] = True
    return await runtime.send_command("animation_preset_slide", params)


async def animation_preset_shake(
    runtime: DirectRuntime,
    player_path: str,
    target_path: str,
    intensity: float | None = None,
    duration: float = 0.3,
    frequency: float = 30.0,
    seed: int = 0,
    animation_name: str = "",
    overwrite: bool = False,
) -> dict:
    require_writable(runtime)
    params: dict[str, Any] = {
        "player_path": player_path,
        "target_path": target_path,
        "duration": duration,
        "frequency": frequency,
        "seed": seed,
    }
    if intensity is not None:
        params["intensity"] = intensity
    if animation_name:
        params["animation_name"] = animation_name
    if overwrite:
        params["overwrite"] = True
    return await runtime.send_command("animation_preset_shake", params)


async def animation_preset_pulse(
    runtime: DirectRuntime,
    player_path: str,
    target_path: str,
    from_scale: float = 1.0,
    to_scale: float = 1.1,
    duration: float = 0.4,
    animation_name: str = "",
    overwrite: bool = False,
) -> dict:
    require_writable(runtime)
    params: dict[str, Any] = {
        "player_path": player_path,
        "target_path": target_path,
        "from_scale": from_scale,
        "to_scale": to_scale,
        "duration": duration,
    }
    if animation_name:
        params["animation_name"] = animation_name
    if overwrite:
        params["overwrite"] = True
    return await runtime.send_command("animation_preset_pulse", params)

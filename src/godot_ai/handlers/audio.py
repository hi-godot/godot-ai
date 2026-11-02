"""Shared handlers for AudioStreamPlayer authoring — streams, playback, preview."""

from __future__ import annotations

from typing import Any

from godot_ai.handlers._readiness import require_writable_async
from godot_ai.runtime.direct import DirectRuntime


async def audio_player_create(
    runtime: DirectRuntime,
    parent_path: str,
    name: str = "AudioStreamPlayer",
    type: str = "1d",
) -> dict:
    await require_writable_async(runtime)
    return await runtime.send_command(
        "audio_player_create",
        {"parent_path": parent_path, "name": name, "type": type},
    )


async def audio_player_set_stream(
    runtime: DirectRuntime,
    player_path: str,
    stream_path: str,
) -> dict:
    await require_writable_async(runtime)
    return await runtime.send_command(
        "audio_player_set_stream",
        {"player_path": player_path, "stream_path": stream_path},
    )


async def audio_player_set_playback(
    runtime: DirectRuntime,
    player_path: str,
    volume_db: float | None = None,
    pitch_scale: float | None = None,
    autoplay: bool | None = None,
    bus: str | None = None,
) -> dict:
    await require_writable_async(runtime)
    params: dict[str, Any] = {"player_path": player_path}
    if volume_db is not None:
        params["volume_db"] = volume_db
    if pitch_scale is not None:
        params["pitch_scale"] = pitch_scale
    if autoplay is not None:
        params["autoplay"] = autoplay
    if bus is not None:
        params["bus"] = bus
    return await runtime.send_command("audio_player_set_playback", params)


async def audio_play(
    runtime: DirectRuntime,
    player_path: str,
    from_position: float = 0.0,
) -> dict:
    return await runtime.send_command(
        "audio_play",
        {"player_path": player_path, "from_position": from_position},
    )


async def audio_stop(runtime: DirectRuntime, player_path: str) -> dict:
    return await runtime.send_command("audio_stop", {"player_path": player_path})


async def audio_list(
    runtime: DirectRuntime,
    root: str = "res://",
    include_duration: bool = True,
) -> dict:
    return await runtime.send_command(
        "audio_list",
        {"root": root, "include_duration": include_duration},
    )


async def audio_bus_list(runtime: DirectRuntime) -> dict:
    return await runtime.send_command("audio_bus_list", {})


async def audio_bus_add(
    runtime: DirectRuntime, name: str, at_position: int = -1, send: str = "Master"
) -> dict:
    await require_writable_async(runtime)
    return await runtime.send_command(
        "audio_bus_add", {"name": name, "at_position": at_position, "send": send}
    )


async def audio_bus_remove(runtime: DirectRuntime, name: str) -> dict:
    await require_writable_async(runtime)
    return await runtime.send_command("audio_bus_remove", {"name": name})


async def audio_bus_set(
    runtime: DirectRuntime,
    name: str,
    volume_db: float | None = None,
    send: str | None = None,
    mute: bool | None = None,
    solo: bool | None = None,
    bypass_effects: bool | None = None,
) -> dict:
    await require_writable_async(runtime)
    params: dict[str, Any] = {"name": name}
    for key, value in (
        ("volume_db", volume_db),
        ("send", send),
        ("mute", mute),
        ("solo", solo),
        ("bypass_effects", bypass_effects),
    ):
        if value is not None:
            params[key] = value
    return await runtime.send_command("audio_bus_set", params)


async def audio_bus_effect_add(
    runtime: DirectRuntime,
    bus: str,
    effect_class: str,
    properties: dict | None = None,
    at_position: int = -1,
    enabled: bool = True,
) -> dict:
    await require_writable_async(runtime)
    return await runtime.send_command(
        "audio_bus_effect_add",
        {
            "bus": bus,
            "effect_class": effect_class,
            "properties": properties or {},
            "at_position": at_position,
            "enabled": enabled,
        },
    )


async def audio_bus_effect_set(
    runtime: DirectRuntime,
    bus: str,
    index: int,
    properties: dict | None = None,
    enabled: bool | None = None,
) -> dict:
    await require_writable_async(runtime)
    params: dict[str, Any] = {"bus": bus, "index": index, "properties": properties or {}}
    if enabled is not None:
        params["enabled"] = enabled
    return await runtime.send_command("audio_bus_effect_set", params)


async def audio_bus_effect_remove(runtime: DirectRuntime, bus: str, index: int) -> dict:
    await require_writable_async(runtime)
    return await runtime.send_command("audio_bus_effect_remove", {"bus": bus, "index": index})


async def audio_bus_layout_save(
    runtime: DirectRuntime, path: str = "res://default_bus_layout.tres", overwrite: bool = False
) -> dict:
    await require_writable_async(runtime)
    return await runtime.send_command(
        "audio_bus_layout_save", {"path": path, "overwrite": overwrite}
    )

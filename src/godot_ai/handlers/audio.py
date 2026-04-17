"""Shared handlers for AudioStreamPlayer authoring — streams, playback, preview."""

from __future__ import annotations

from typing import Any

from godot_ai.handlers._readiness import require_writable
from godot_ai.runtime.interface import Runtime


async def audio_player_create(
    runtime: Runtime,
    parent_path: str,
    name: str = "AudioStreamPlayer",
    type: str = "1d",
) -> dict:
    require_writable(runtime)
    return await runtime.send_command(
        "audio_player_create",
        {"parent_path": parent_path, "name": name, "type": type},
    )


async def audio_player_set_stream(
    runtime: Runtime,
    player_path: str,
    stream_path: str,
) -> dict:
    require_writable(runtime)
    return await runtime.send_command(
        "audio_player_set_stream",
        {"player_path": player_path, "stream_path": stream_path},
    )


async def audio_player_set_playback(
    runtime: Runtime,
    player_path: str,
    volume_db: float | None = None,
    pitch_scale: float | None = None,
    autoplay: bool | None = None,
    bus: str | None = None,
) -> dict:
    require_writable(runtime)
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
    runtime: Runtime,
    player_path: str,
    from_position: float = 0.0,
) -> dict:
    return await runtime.send_command(
        "audio_play",
        {"player_path": player_path, "from_position": from_position},
    )


async def audio_stop(runtime: Runtime, player_path: str) -> dict:
    return await runtime.send_command("audio_stop", {"player_path": player_path})


async def audio_list(
    runtime: Runtime,
    root: str = "res://",
    include_duration: bool = True,
) -> dict:
    return await runtime.send_command(
        "audio_list",
        {"root": root, "include_duration": include_duration},
    )

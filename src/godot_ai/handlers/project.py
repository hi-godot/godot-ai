"""Shared handlers for project tools and resources."""

from __future__ import annotations

import asyncio
from typing import Any

from godot_ai.handlers._readiness import require_writable
from godot_ai.runtime.interface import Runtime

COMMON_SETTINGS = [
    "application/config/name",
    "application/config/description",
    "application/run/main_scene",
    "display/window/size/viewport_width",
    "display/window/size/viewport_height",
    "rendering/renderer/rendering_method",
    "physics/2d/default_gravity",
    "physics/3d/default_gravity",
]


async def project_settings_get(runtime: Runtime, key: str) -> dict:
    return await runtime.send_command("get_project_setting", {"key": key})


async def project_run(runtime: Runtime, mode: str = "main", scene: str = "") -> dict:
    params: dict[str, str] = {"mode": mode}
    if scene:
        params["scene"] = scene
    return await runtime.send_command("run_project", params)


async def project_stop(runtime: Runtime) -> dict:
    """Stop the running game and wait for readiness to reflect the stop.

    The plugin's `_process` emits a `readiness_changed` event on the next
    frame once `EditorInterface.is_playing_scene()` flips to false. A write
    tool called immediately after this handler returns would otherwise race
    the event and see stale `readiness="playing"`. We poll `session.readiness`
    until it leaves "playing", bounded by a 1s timeout so a hung play process
    doesn't block the handler indefinitely — in that case readiness stays
    "playing" and the next write tool correctly blocks with EDITOR_NOT_READY.
    """
    result = await runtime.send_command("stop_project")
    session = runtime.get_active_session()
    if session is not None:
        loop = asyncio.get_running_loop()
        deadline = loop.time() + 1.0
        while session.readiness == "playing" and loop.time() < deadline:
            await asyncio.sleep(0.02)
    return result


async def project_settings_set(runtime: Runtime, key: str, value: Any) -> dict:
    require_writable(runtime)
    return await runtime.send_command("set_project_setting", {"key": key, "value": value})


def project_info_resource_data(runtime: Runtime) -> dict:
    session = runtime.get_active_session()
    if session is None:
        return {"error": "No active Godot session", "connected": False}

    info = session.to_dict()
    info.pop("connected_at", None)
    return info


async def project_settings_resource_data(runtime: Runtime) -> dict:
    async def _fetch(key: str) -> tuple[str, object | None, str | None]:
        try:
            result = await runtime.send_command("get_project_setting", {"key": key})
            return key, result.get("value"), None
        except Exception as exc:
            return key, None, str(exc)

    results = await asyncio.gather(*[_fetch(key) for key in COMMON_SETTINGS])
    settings: dict[str, object | None] = {}
    errors: list[dict[str, str]] = []
    for key, value, error in results:
        if error:
            errors.append({"key": key, "error": error})
        else:
            settings[key] = value
    return {"settings": settings, "errors": errors if errors else None}

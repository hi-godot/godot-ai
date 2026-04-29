"""Shared handlers for project tools and resources."""

from __future__ import annotations

import asyncio
from typing import Any

from godot_ai.handlers._readiness import require_writable, sync_readiness_from_snapshot
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


async def project_run(
    runtime: Runtime,
    mode: str = "main",
    scene: str = "",
    autosave: bool = True,
) -> dict:
    params: dict[str, Any] = {"mode": mode}
    if scene:
        params["scene"] = scene
    if not autosave:
        params["autosave"] = False
    return await runtime.send_command("run_project", params)


async def project_stop(runtime: Runtime) -> dict:
    """Stop the running game and reflect authoritative readiness in the session.

    New plugins (issue #29) defer the stop response until after
    `EditorInterface.stop_playing_scene()` has ticked two frames, then return
    `readiness_after` in the payload — a ground-truth snapshot of
    `McpConnection.get_readiness()` after the stop settled. We copy that straight
    onto `session.readiness` so the next write tool can't race the
    `readiness_changed` event.

    Older plugins (pre-#29) omit `readiness_after` and the server still needs
    to wait for the `readiness_changed` event. We fall back to polling
    `session.readiness` bounded by a 1s timeout — a hung play process leaves
    readiness at "playing" and the next write tool correctly blocks with
    EDITOR_NOT_READY.
    """
    result = await runtime.send_command("stop_project")
    if sync_readiness_from_snapshot(runtime, result.get("readiness_after")):
        return result

    session = runtime.get_active_session()
    if session is None:
        return result

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

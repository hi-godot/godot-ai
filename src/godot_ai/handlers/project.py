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
    """Stop the running game and reflect the post-stop readiness.

    The plugin's `stop_project` handler awaits two process_frames before
    returning, so `readiness_after` in the response is authoritative — we
    just copy it into the session and the next write tool sees truth
    without a polling loop.

    Older plugins (pre-#29) don't include `readiness_after`; fall back to
    the legacy event-poll so a version-skew client still converges.
    """
    result = await runtime.send_command("stop_project")
    session = runtime.get_active_session()
    if session is None:
        return result
    readiness_after = result.get("readiness_after")
    if readiness_after is not None:
        session.readiness = readiness_after
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

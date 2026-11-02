"""Shared handlers for project tools and resources."""

from __future__ import annotations

import asyncio
from typing import Any

from godot_ai.godot_client.session_diagnostics import (
    NO_ACTIVE_SESSION_MESSAGE,
    no_active_session_data,
)
from godot_ai.handlers._readiness import require_writable_async, sync_readiness_from_snapshot
from godot_ai.runtime.direct import DirectRuntime

## Must stay above the plugin's own deferred budget for `run_project`
## (`DEFERRED_TIMEOUT_MS_BY_COMMAND["run_project"] = 6000` in dispatcher.gd).
## `run_project` defers: the plugin returns DEFERRED_RESPONSE and re-polls game
## status until the launch resolves, so it can legitimately take the full 6 s on
## a cold start or a large scene. At the inherited 5.0 s default the server gave
## up first and reported a successful launch as a timeout — which `GodotClient`
## then charged to the editor-bridge circuit breaker.
##
## 6.0 s budget + the repo's standing 2 s transport margin for this exact
## cross-language pairing, spelled out in `handlers/custom.py`: "the server-side
## future must outlive that budget ... +2s margin covers transport latency".
## `vision_routing.gd`'s 13 000 ms editor-screenshot override under
## SCREENSHOT_TIMEOUT_SEC = 15.0 is the same +2. Exact ties exist elsewhere
## (game_eval, game_command, check_client_status) and are not wrong, but the
## plugin's timer starts when the dispatcher registers the deferred request —
## strictly after the server began its own — so the margin costs nothing and
## removes the round-trip from the race.
RUN_PROJECT_TIMEOUT_SEC = 8.0

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


async def project_settings_get(runtime: DirectRuntime, key: str) -> dict:
    return await runtime.send_command("get_project_setting", {"key": key})


async def project_run(
    runtime: DirectRuntime,
    mode: str = "main",
    scene: str = "",
    autosave: bool = True,
) -> dict:
    params: dict[str, Any] = {"mode": mode}
    if scene:
        params["scene"] = scene
    if not autosave:
        params["autosave"] = False
    await require_writable_async(runtime, allow_playing_noop=True)
    return await runtime.send_command("run_project", params, timeout=RUN_PROJECT_TIMEOUT_SEC)


async def project_stop(runtime: DirectRuntime) -> dict:
    result = await runtime.send_command("stop_project")
    sync_readiness_from_snapshot(runtime, result.get("readiness_after"))
    return result


async def project_settings_set(runtime: DirectRuntime, key: str, value: Any) -> dict:
    await require_writable_async(runtime)
    return await runtime.send_command("set_project_setting", {"key": key, "value": value})


async def project_set_main_scene(runtime: DirectRuntime, path: str) -> dict:
    """Point ``application/run/main_scene`` at an existing scene.

    ``settings_set`` refuses that key — it is part of the startup-execution
    surface a generic setter can't validate — which left a scaffolded project
    unbootable through MCP alone (#915). The plugin-side op accepts only a
    ``res://`` path inside the project that loads as a ``PackedScene``.
    """
    await require_writable_async(runtime)
    return await runtime.send_command("set_main_scene", {"path": path})


def project_info_resource_data(runtime: DirectRuntime) -> dict:
    session = runtime.get_active_session()
    if session is None:
        return {
            "error": NO_ACTIVE_SESSION_MESSAGE,
            **no_active_session_data(circuit_open=False),
        }

    info = session.to_dict()
    info.pop("connected_at", None)
    return info


async def project_settings_resource_data(runtime: DirectRuntime) -> dict:
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

"""Shared handlers for project tools and resources."""

from __future__ import annotations

import asyncio

from godot_ai.runtime.interface import Runtime
from godot_ai.tools._pagination import paginate

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


async def filesystem_search(
    runtime: Runtime,
    name: str = "",
    type: str = "",
    path: str = "",
    offset: int = 0,
    limit: int = 100,
) -> dict:
    params: dict[str, str] = {}
    if name:
        params["name"] = name
    if type:
        params["type"] = type
    if path:
        params["path"] = path
    result = await runtime.send_command("search_filesystem", params)
    return paginate(result.get("files", []), offset, limit, key="files")


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


"""Shared handlers for resource tools."""

from __future__ import annotations

from godot_ai.handlers._readiness import require_writable_async
from godot_ai.handlers._target import target_params
from godot_ai.runtime.direct import DirectRuntime
from godot_ai.tools._pagination import paginate


async def resource_search(
    runtime: DirectRuntime,
    type: str = "",
    path: str = "",
    offset: int = 0,
    limit: int = 100,
) -> dict:
    result = await runtime.send_command(
        "search_resources",
        {"type": type, "path": path},
    )
    return paginate(result.get("resources", []), offset, limit, key="resources")


async def resource_load(runtime: DirectRuntime, path: str) -> dict:
    return await runtime.send_command("load_resource", {"path": path})


async def resource_assign(
    runtime: DirectRuntime,
    path: str,
    property: str,
    resource_path: str,
) -> dict:
    await require_writable_async(runtime)
    return await runtime.send_command(
        "assign_resource",
        {"path": path, "property": property, "resource_path": resource_path},
    )


async def resource_get_info(runtime: DirectRuntime, type: str) -> dict:
    return await runtime.send_command("get_resource_info", {"type": type})


async def resource_create(
    runtime: DirectRuntime,
    type: str,
    properties: dict | None = None,
    path: str = "",
    property: str = "",
    resource_path: str = "",
    overwrite: bool = False,
) -> dict:
    await require_writable_async(runtime)
    params: dict = {"type": type}
    if properties:
        params["properties"] = properties
    params.update(target_params(path, property, resource_path, overwrite))
    return await runtime.send_command("create_resource", params)


async def resource_inspect(
    runtime: DirectRuntime, node_path: str, property: str, depth: int = 2
) -> dict:
    return await runtime.send_command(
        "inspect_resource", {"node_path": node_path, "property": property, "depth": depth}
    )


async def resource_set_properties(runtime: DirectRuntime, path: str, properties: dict) -> dict:
    """Persist a native resource patch and refresh its held instance without scene undo."""
    await require_writable_async(runtime)
    return await runtime.send_command(
        "set_resource_properties", {"path": path, "properties": properties}
    )


async def sprite_frames_create(
    runtime: DirectRuntime, resource_path: str, animations: list[dict], overwrite: bool = False
) -> dict:
    await require_writable_async(runtime)
    return await runtime.send_command(
        "create_sprite_frames",
        {"resource_path": resource_path, "animations": animations, "overwrite": overwrite},
    )

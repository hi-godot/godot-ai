"""Shared handlers for resource tools."""

from __future__ import annotations

from godot_ai.handlers._readiness import require_writable
from godot_ai.runtime.interface import Runtime
from godot_ai.tools._pagination import paginate


async def resource_search(
    runtime: Runtime,
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


async def resource_load(runtime: Runtime, path: str) -> dict:
    return await runtime.send_command("load_resource", {"path": path})


async def resource_assign(
    runtime: Runtime,
    path: str,
    property: str,
    resource_path: str,
) -> dict:
    require_writable(runtime)
    return await runtime.send_command(
        "assign_resource",
        {"path": path, "property": property, "resource_path": resource_path},
    )


async def resource_create(
    runtime: Runtime,
    type: str,
    properties: dict | None = None,
    path: str = "",
    property: str = "",
    resource_path: str = "",
    overwrite: bool = False,
) -> dict:
    require_writable(runtime)
    params: dict = {"type": type}
    if properties:
        params["properties"] = properties
    if path:
        params["path"] = path
    if property:
        params["property"] = property
    if resource_path:
        params["resource_path"] = resource_path
    if overwrite:
        params["overwrite"] = overwrite
    return await runtime.send_command("create_resource", params)

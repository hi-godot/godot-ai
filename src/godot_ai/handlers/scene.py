"""Shared handlers for scene tools and resources."""

from __future__ import annotations

from godot_ai.handlers._readiness import require_writable
from godot_ai.runtime.direct import DirectRuntime
from godot_ai.tools._pagination import paginate


async def scene_get_hierarchy(
    runtime: DirectRuntime,
    depth: int = 10,
    offset: int = 0,
    limit: int = 100,
) -> dict:
    result = await runtime.send_command("get_scene_tree", {"depth": depth})
    nodes = result.get("nodes", [])
    return {"root": result.get("root", ""), **paginate(nodes, offset, limit, key="nodes")}


async def scene_get_roots(runtime: DirectRuntime) -> dict:
    return await runtime.send_command("get_open_scenes")


async def scene_create(
    runtime: DirectRuntime,
    path: str,
    root_type: str = "Node3D",
    root_name: str = "",
) -> dict:
    require_writable(runtime)
    params: dict = {"path": path, "root_type": root_type}
    if root_name:
        params["root_name"] = root_name
    return await runtime.send_command("create_scene", params)


async def scene_open(runtime: DirectRuntime, path: str) -> dict:
    require_writable(runtime)
    return await runtime.send_command("open_scene", {"path": path})


async def scene_save(runtime: DirectRuntime) -> dict:
    require_writable(runtime)
    return await runtime.send_command("save_scene")


async def scene_save_as(runtime: DirectRuntime, path: str) -> dict:
    require_writable(runtime)
    return await runtime.send_command("save_scene_as", {"path": path})


async def current_scene_resource_data(runtime: DirectRuntime) -> dict:
    state = await runtime.send_command("get_editor_state")
    return {
        "current_scene": state.get("current_scene", ""),
        "project_name": state.get("project_name", ""),
        "is_playing": state.get("is_playing", False),
    }


async def scene_hierarchy_resource_data(runtime: DirectRuntime) -> dict:
    return await runtime.send_command("get_scene_tree", {"depth": 10})

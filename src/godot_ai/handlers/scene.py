"""Shared handlers for scene tools and resources."""

from __future__ import annotations

from godot_ai.runtime.interface import Runtime
from godot_ai.tools._pagination import paginate


async def scene_get_hierarchy(
    runtime: Runtime,
    depth: int = 10,
    offset: int = 0,
    limit: int = 100,
) -> dict:
    result = await runtime.send_command("get_scene_tree", {"depth": depth})
    nodes = result.get("nodes", [])
    return {"root": result.get("root", ""), **paginate(nodes, offset, limit, key="nodes")}


async def scene_get_roots(runtime: Runtime) -> dict:
    return await runtime.send_command("get_open_scenes")


async def current_scene_resource_data(runtime: Runtime) -> dict:
    state = await runtime.send_command("get_editor_state")
    return {
        "current_scene": state.get("current_scene", ""),
        "project_name": state.get("project_name", ""),
        "is_playing": state.get("is_playing", False),
    }


async def scene_hierarchy_resource_data(runtime: Runtime) -> dict:
    return await runtime.send_command("get_scene_tree", {"depth": 10})


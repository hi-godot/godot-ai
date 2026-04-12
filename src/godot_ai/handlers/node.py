"""Shared handlers for node tools."""

from __future__ import annotations

from godot_ai.runtime.interface import Runtime
from godot_ai.tools._pagination import paginate


async def node_create(runtime: Runtime, type: str, name: str = "", parent_path: str = "") -> dict:
    return await runtime.send_command(
        "create_node",
        {"type": type, "name": name, "parent_path": parent_path},
    )


async def node_find(
    runtime: Runtime,
    name: str = "",
    type: str = "",
    group: str = "",
    offset: int = 0,
    limit: int = 100,
) -> dict:
    result = await runtime.send_command(
        "find_nodes",
        {"name": name, "type": type, "group": group},
    )
    return paginate(result.get("nodes", []), offset, limit, key="nodes")


async def node_get_properties(runtime: Runtime, path: str) -> dict:
    return await runtime.send_command("get_node_properties", {"path": path})


async def node_get_children(runtime: Runtime, path: str) -> dict:
    return await runtime.send_command("get_children", {"path": path})


async def node_get_groups(runtime: Runtime, path: str) -> dict:
    return await runtime.send_command("get_groups", {"path": path})


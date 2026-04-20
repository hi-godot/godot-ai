"""Shared handlers for node tools."""

from __future__ import annotations

from godot_ai.handlers._readiness import require_writable
from godot_ai.runtime.interface import Runtime
from godot_ai.tools._pagination import paginate


# Shared wire-level payload builder for scene-mutation commands. The
# `scene_file` guard is opt-in — callers who pass a non-empty value get
# EDITED_SCENE_MISMATCH on drift; empty is omitted so the plugin's
# `params.get("scene_file", "")` stays the single source of the "no guard"
# default and the wire payload / test assertions don't balloon.
def _mutation_params(scene_file: str, **extra) -> dict:
    params: dict = dict(extra)
    if scene_file:
        params["scene_file"] = scene_file
    return params


async def node_create(
    runtime: Runtime,
    type: str = "",
    name: str = "",
    parent_path: str = "",
    scene_path: str = "",
    scene_file: str = "",
) -> dict:
    require_writable(runtime)
    params = _mutation_params(
        scene_file,
        type=type,
        name=name,
        parent_path=parent_path,
    )
    if scene_path:
        params["scene_path"] = scene_path
    return await runtime.send_command("create_node", params)


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


async def node_delete(runtime: Runtime, path: str, scene_file: str = "") -> dict:
    require_writable(runtime)
    return await runtime.send_command(
        "delete_node",
        _mutation_params(scene_file, path=path),
    )


async def node_reparent(runtime: Runtime, path: str, new_parent: str, scene_file: str = "") -> dict:
    require_writable(runtime)
    return await runtime.send_command(
        "reparent_node",
        _mutation_params(scene_file, path=path, new_parent=new_parent),
    )


async def node_set_property(
    runtime: Runtime, path: str, property: str, value, scene_file: str = ""
) -> dict:
    require_writable(runtime)
    return await runtime.send_command(
        "set_property",
        _mutation_params(scene_file, path=path, property=property, value=value),
    )


async def node_rename(runtime: Runtime, path: str, new_name: str, scene_file: str = "") -> dict:
    require_writable(runtime)
    return await runtime.send_command(
        "rename_node",
        _mutation_params(scene_file, path=path, new_name=new_name),
    )


async def node_duplicate(runtime: Runtime, path: str, name: str = "", scene_file: str = "") -> dict:
    require_writable(runtime)
    return await runtime.send_command(
        "duplicate_node",
        _mutation_params(scene_file, path=path, name=name),
    )


async def node_move(runtime: Runtime, path: str, index: int, scene_file: str = "") -> dict:
    require_writable(runtime)
    return await runtime.send_command(
        "move_node",
        _mutation_params(scene_file, path=path, index=index),
    )


async def node_add_to_group(runtime: Runtime, path: str, group: str, scene_file: str = "") -> dict:
    require_writable(runtime)
    return await runtime.send_command(
        "add_to_group",
        _mutation_params(scene_file, path=path, group=group),
    )


async def node_remove_from_group(
    runtime: Runtime, path: str, group: str, scene_file: str = ""
) -> dict:
    require_writable(runtime)
    return await runtime.send_command(
        "remove_from_group",
        _mutation_params(scene_file, path=path, group=group),
    )

"""Shared handlers for material authoring — albedo, metallic, emission, glass, shader uniforms."""

from __future__ import annotations

from typing import Any

from godot_ai.handlers._readiness import require_writable
from godot_ai.runtime.interface import Runtime


async def material_create(
    runtime: Runtime,
    path: str,
    type: str = "standard",
    shader_path: str = "",
    overwrite: bool = False,
) -> dict:
    require_writable(runtime)
    params: dict[str, Any] = {"path": path, "type": type, "overwrite": overwrite}
    if shader_path:
        params["shader_path"] = shader_path
    return await runtime.send_command("material_create", params)


async def material_set_param(
    runtime: Runtime,
    path: str,
    property: str,
    value: Any,
) -> dict:
    require_writable(runtime)
    return await runtime.send_command(
        "material_set_param",
        {"path": path, "property": property, "value": value},
    )


async def material_set_shader_param(
    runtime: Runtime,
    path: str,
    param: str,
    value: Any,
) -> dict:
    require_writable(runtime)
    return await runtime.send_command(
        "material_set_shader_param",
        {"path": path, "param": param, "value": value},
    )


async def material_get(runtime: Runtime, path: str) -> dict:
    return await runtime.send_command("material_get", {"path": path})


async def material_list(
    runtime: Runtime,
    root: str = "res://",
    type: str = "",
) -> dict:
    params: dict[str, Any] = {"root": root}
    if type:
        params["type"] = type
    return await runtime.send_command("material_list", params)


async def material_assign(
    runtime: Runtime,
    node_path: str,
    resource_path: str = "",
    slot: str = "override",
    create_if_missing: bool = False,
    type: str = "standard",
) -> dict:
    require_writable(runtime)
    params: dict[str, Any] = {
        "node_path": node_path,
        "slot": slot,
        "create_if_missing": create_if_missing,
        "type": type,
    }
    if resource_path:
        params["resource_path"] = resource_path
    return await runtime.send_command("material_assign", params)


async def material_apply_to_node(
    runtime: Runtime,
    node_path: str,
    type: str = "standard",
    params: dict[str, Any] | None = None,
    slot: str = "override",
    save_to: str = "",
) -> dict:
    require_writable(runtime)
    payload: dict[str, Any] = {
        "node_path": node_path,
        "type": type,
        "params": params or {},
        "slot": slot,
    }
    if save_to:
        payload["save_to"] = save_to
    return await runtime.send_command("material_apply_to_node", payload)


async def material_apply_preset(
    runtime: Runtime,
    preset: str,
    path: str = "",
    node_path: str = "",
    overrides: dict[str, Any] | None = None,
) -> dict:
    require_writable(runtime)
    params: dict[str, Any] = {"preset": preset}
    if path:
        params["path"] = path
    if node_path:
        params["node_path"] = node_path
    if overrides:
        params["overrides"] = overrides
    return await runtime.send_command("material_apply_preset", params)

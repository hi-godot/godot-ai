"""Shared handlers for particle systems — fire, smoke, sparks, magic, rain, explosions."""

from __future__ import annotations

from typing import Any

from godot_ai.handlers._readiness import require_writable
from godot_ai.runtime.direct import DirectRuntime


async def particle_create(
    runtime: DirectRuntime,
    parent_path: str,
    name: str = "Particles",
    type: str = "gpu_3d",
) -> dict:
    require_writable(runtime)
    return await runtime.send_command(
        "particle_create",
        {"parent_path": parent_path, "name": name, "type": type},
    )


async def particle_set_main(
    runtime: DirectRuntime,
    node_path: str,
    properties: dict[str, Any],
) -> dict:
    require_writable(runtime)
    return await runtime.send_command(
        "particle_set_main",
        {"node_path": node_path, "properties": properties},
    )


async def particle_set_process(
    runtime: DirectRuntime,
    node_path: str,
    properties: dict[str, Any],
) -> dict:
    require_writable(runtime)
    return await runtime.send_command(
        "particle_set_process",
        {"node_path": node_path, "properties": properties},
    )


async def particle_set_draw_pass(
    runtime: DirectRuntime,
    node_path: str,
    pass_: int = 1,
    mesh: str = "",
    texture: str = "",
    material: str = "",
) -> dict:
    require_writable(runtime)
    params: dict[str, Any] = {"node_path": node_path, "pass": pass_}
    if mesh:
        params["mesh"] = mesh
    if texture:
        params["texture"] = texture
    if material:
        params["material"] = material
    return await runtime.send_command("particle_set_draw_pass", params)


async def particle_restart(runtime: DirectRuntime, node_path: str) -> dict:
    return await runtime.send_command("particle_restart", {"node_path": node_path})


async def particle_get(runtime: DirectRuntime, node_path: str) -> dict:
    return await runtime.send_command("particle_get", {"node_path": node_path})


async def particle_apply_preset(
    runtime: DirectRuntime,
    parent_path: str,
    name: str,
    preset: str,
    type: str = "gpu_3d",
    overrides: dict[str, Any] | None = None,
) -> dict:
    require_writable(runtime)
    params: dict[str, Any] = {
        "parent_path": parent_path,
        "name": name,
        "preset": preset,
        "type": type,
    }
    if overrides:
        params["overrides"] = overrides
    return await runtime.send_command("particle_apply_preset", params)

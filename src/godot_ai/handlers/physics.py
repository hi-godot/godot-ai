"""Shared handlers for physics body configuration and collision layers."""

from __future__ import annotations

from typing import Any

from godot_ai.handlers._readiness import require_writable_async
from godot_ai.runtime.direct import DirectRuntime


async def physics_body_get(
    runtime: DirectRuntime,
    path: str,
    scene_file: str = "",
) -> dict:
    """Read a CollisionObject2D/3D's physics configuration."""
    params: dict = {"path": path}
    if scene_file:
        params["scene_file"] = scene_file
    return await runtime.send_command("physics_body_get", params)


async def physics_body_configure(
    runtime: DirectRuntime,
    path: str,
    collision_layer: int | list[str] | None = None,
    collision_mask: int | list[str] | None = None,
    gravity: float | None = None,
    gravity_scale: float | None = None,
    mass: float | None = None,
    linear_damp: float | None = None,
    angular_damp: float | None = None,
    continuous_cd: int | bool | None = None,
    freeze: bool | None = None,
    priority: float | None = None,
    monitoring: bool | None = None,
    monitorable: bool | None = None,
    physics_material_override: str | None = None,
    scene_file: str = "",
) -> dict:
    """Set a subset of a body's/area's physics properties in one undo action."""
    await require_writable_async(runtime)
    optional: dict[str, Any] = {
        "collision_layer": collision_layer,
        "collision_mask": collision_mask,
        "gravity": gravity,
        "gravity_scale": gravity_scale,
        "mass": mass,
        "linear_damp": linear_damp,
        "angular_damp": angular_damp,
        "continuous_cd": continuous_cd,
        "freeze": freeze,
        "priority": priority,
        "monitoring": monitoring,
        "monitorable": monitorable,
        "physics_material_override": physics_material_override,
    }
    params: dict[str, Any] = {"path": path}
    for key, value in optional.items():
        if value is not None:
            params[key] = value
    if scene_file:
        params["scene_file"] = scene_file
    return await runtime.send_command("physics_body_configure", params)


async def physics_layers_get(
    runtime: DirectRuntime,
    dimension: str = "3d",
) -> dict:
    """List the project's named physics layers for one dimension."""
    return await runtime.send_command("physics_layers_get", {"dimension": dimension})


async def physics_layers_set(
    runtime: DirectRuntime,
    dimension: str,
    layers: dict[int, str],
) -> dict:
    """Name project physics layers ({layer_index: name}, indexes 1-32)."""
    await require_writable_async(runtime)
    return await runtime.send_command(
        "physics_layers_set",
        {"dimension": dimension, "layers": layers},
    )

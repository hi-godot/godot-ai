"""Shared handlers for CSG authoring tools."""

from __future__ import annotations

from godot_ai.handlers._readiness import require_writable_async
from godot_ai.runtime.direct import DirectRuntime

CSG_BAKE_PLUGIN_TIMEOUT_MS = 30000
CSG_BAKE_TIMEOUT_SEC = CSG_BAKE_PLUGIN_TIMEOUT_MS / 1000.0 + 2.0


async def csg_bake_mesh(
    runtime: DirectRuntime,
    path: str,
    resource_path: str,
    scene_file: str = "",
    apply_material_override: bool = False,
) -> dict:
    """Bake the edited CSG root into a fresh project mesh asset."""
    await require_writable_async(runtime)
    params: dict = {"path": path, "resource_path": resource_path}
    if scene_file:
        params["scene_file"] = scene_file
    if apply_material_override:
        params["apply_material_override"] = True
    return await runtime.send_command("csg_bake_mesh", params, timeout=CSG_BAKE_TIMEOUT_SEC)


async def csg_create(
    runtime: DirectRuntime,
    parent_path: str,
    name: str = "",
    shape: str = "box",
    operation: str = "union",
) -> dict:
    """Create a CSG shape (box, sphere, cylinder, torus, prism) under a
    Node3D parent, with a boolean operation (union / intersection /
    subtraction).
    """
    await require_writable_async(runtime)
    return await runtime.send_command(
        "csg_create",
        {
            "parent_path": parent_path,
            "name": name,
            "shape": shape,
            "operation": operation,
        },
    )


async def csg_set_operation(
    runtime: DirectRuntime,
    path: str,
    operation: str,
) -> dict:
    """Set the boolean operation of a CSG shape (union / intersection /
    subtraction).
    """
    await require_writable_async(runtime)
    return await runtime.send_command(
        "csg_set_operation",
        {
            "path": path,
            "operation": operation,
        },
    )

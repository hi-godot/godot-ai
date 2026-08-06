"""Shared handlers for CSG authoring tools."""

from __future__ import annotations

from godot_ai.handlers._readiness import require_writable_async
from godot_ai.runtime.direct import DirectRuntime


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

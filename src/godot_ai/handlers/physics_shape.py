"""Shared handlers for physics_shape tools."""

from __future__ import annotations

from godot_ai.handlers._readiness import require_writable_async
from godot_ai.runtime.direct import DirectRuntime

PHYSICS_SHAPE_GENERATE_TIMEOUT_SEC = 35.0


async def physics_shape_generate(
    runtime: DirectRuntime,
    paths: list[str],
    shape_type: str = "box",
    body_type: str = "static",
) -> dict:
    """Generate sibling physics bodies and shapes for 3D meshes."""
    await require_writable_async(runtime)
    return await runtime.send_command(
        "physics_shape_generate",
        {
            "paths": paths,
            "shape_type": shape_type,
            "body_type": body_type,
        },
        timeout=PHYSICS_SHAPE_GENERATE_TIMEOUT_SEC,
    )


async def physics_shape_autofit(
    runtime: DirectRuntime,
    path: str,
    source_path: str = "",
    shape_type: str = "",
) -> dict:
    await require_writable_async(runtime)
    params: dict = {"path": path}
    if source_path:
        params["source_path"] = source_path
    if shape_type:
        params["shape_type"] = shape_type
    return await runtime.send_command("physics_shape_autofit", params)

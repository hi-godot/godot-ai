"""Shared handlers for physics_shape tools."""

from __future__ import annotations

from godot_ai.handlers._readiness import require_writable_async
from godot_ai.runtime.direct import DirectRuntime

## The plugin's deferred budget for one generate request
## (`_GENERATE_DEFERRED_TIMEOUT_MS` in physics_shape_handler.gd; a source-shape
## test keeps the two together) plus the same transport margin custom.py adds.
PHYSICS_SHAPE_GENERATE_PLUGIN_TIMEOUT_MS = 30000
PHYSICS_SHAPE_GENERATE_TIMEOUT_SEC = PHYSICS_SHAPE_GENERATE_PLUGIN_TIMEOUT_MS / 1000.0 + 2.0


async def physics_shape_generate(
    runtime: DirectRuntime,
    paths: list[str],
    shape_type: str = "box",
    body_type: str = "static",
    scene_file: str = "",
) -> dict:
    """Generate sibling physics bodies and shapes for 3D meshes."""
    await require_writable_async(runtime)
    params: dict = {
        "paths": paths,
        "shape_type": shape_type,
        "body_type": body_type,
    }
    ## Opt-in like every node mutation: a non-empty scene_file pins the request
    ## to that edited scene (EDITED_SCENE_MISMATCH otherwise).
    if scene_file:
        params["scene_file"] = scene_file
    return await runtime.send_command(
        "physics_shape_generate",
        params,
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

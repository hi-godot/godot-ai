"""Shared handlers for physics_shape tools."""

from __future__ import annotations

from godot_ai.handlers._readiness import require_writable_async
from godot_ai.runtime.direct import DirectRuntime


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

"""Shared handlers for physics_shape tools."""

from __future__ import annotations

from godot_ai.handlers._readiness import require_writable
from godot_ai.runtime.interface import Runtime


async def physics_shape_autofit(
    runtime: Runtime,
    path: str,
    source_path: str = "",
    shape_type: str = "",
) -> dict:
    require_writable(runtime)
    params: dict = {"path": path}
    if source_path:
        params["source_path"] = source_path
    if shape_type:
        params["shape_type"] = shape_type
    return await runtime.send_command("physics_shape_autofit", params)

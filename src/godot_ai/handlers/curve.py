"""Shared handlers for curve tools."""

from __future__ import annotations

from godot_ai.handlers._readiness import require_writable
from godot_ai.runtime.interface import Runtime


async def curve_set_points(
    runtime: Runtime,
    points: list,
    path: str = "",
    property: str = "",
    resource_path: str = "",
) -> dict:
    require_writable(runtime)
    params: dict = {"points": points}
    if path:
        params["path"] = path
    if property:
        params["property"] = property
    if resource_path:
        params["resource_path"] = resource_path
    return await runtime.send_command("curve_set_points", params)

"""Shared handlers for curve tools."""

from __future__ import annotations

from godot_ai.handlers._readiness import require_writable
from godot_ai.handlers._target import target_params
from godot_ai.runtime.direct import DirectRuntime


async def curve_set_points(
    runtime: DirectRuntime,
    points: list,
    path: str = "",
    property: str = "",
    resource_path: str = "",
) -> dict:
    require_writable(runtime)
    # curve_set_points writes to an existing .tres (not a new create), so it
    # has no overwrite param — pass False to the shared helper.
    params: dict = {"points": points}
    params.update(target_params(path, property, resource_path, False))
    return await runtime.send_command("curve_set_points", params)

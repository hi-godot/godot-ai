"""Shared handlers for Control-level vector decoration (control_draw_recipe)."""

from __future__ import annotations

from godot_ai.handlers._readiness import require_writable
from godot_ai.runtime.direct import DirectRuntime


async def control_draw_recipe(
    runtime: DirectRuntime,
    path: str,
    ops: list[dict],
    clear_existing: bool = True,
) -> dict:
    require_writable(runtime)
    return await runtime.send_command(
        "control_draw_recipe",
        {"path": path, "ops": ops, "clear_existing": clear_existing},
    )

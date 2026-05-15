"""Shared handlers for UI (Control layout) tools."""

from __future__ import annotations

from typing import Any

from godot_ai.handlers._readiness import require_writable_async
from godot_ai.runtime.direct import DirectRuntime


async def ui_set_anchor_preset(
    runtime: DirectRuntime,
    path: str,
    preset: str,
    resize_mode: str = "minsize",
    margin: int = 0,
) -> dict:
    await require_writable_async(runtime)
    return await runtime.send_command(
        "set_anchor_preset",
        {
            "path": path,
            "preset": preset,
            "resize_mode": resize_mode,
            "margin": margin,
        },
    )


async def ui_set_text(
    runtime: DirectRuntime,
    path: str,
    text: str,
) -> dict:
    await require_writable_async(runtime)
    return await runtime.send_command(
        "set_text",
        {"path": path, "text": text},
    )


async def ui_build_layout(
    runtime: DirectRuntime,
    tree: dict[str, Any],
    parent_path: str = "",
) -> dict:
    await require_writable_async(runtime)
    return await runtime.send_command(
        "build_layout",
        {"tree": tree, "parent_path": parent_path},
    )

"""Shared handlers for UI (Control layout) tools."""

from __future__ import annotations

from typing import Any

from godot_ai.handlers._readiness import require_writable
from godot_ai.runtime.interface import Runtime


async def ui_set_anchor_preset(
    runtime: Runtime,
    path: str,
    preset: str,
    resize_mode: str = "minsize",
    margin: int = 0,
) -> dict:
    require_writable(runtime)
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
    runtime: Runtime,
    path: str,
    text: str,
) -> dict:
    require_writable(runtime)
    return await runtime.send_command(
        "set_text",
        {"path": path, "text": text},
    )


async def ui_build_layout(
    runtime: Runtime,
    tree: dict[str, Any],
    parent_path: str = "",
) -> dict:
    require_writable(runtime)
    return await runtime.send_command(
        "build_layout",
        {"tree": tree, "parent_path": parent_path},
    )

"""Shared handlers for Theme authoring (colors, stylebox, apply)."""

from __future__ import annotations

from typing import Any

from godot_ai.handlers._readiness import require_writable
from godot_ai.runtime.interface import Runtime


async def theme_create(
    runtime: Runtime,
    path: str,
    overwrite: bool = False,
) -> dict:
    require_writable(runtime)
    return await runtime.send_command(
        "create_theme",
        {"path": path, "overwrite": overwrite},
    )


async def theme_set_color(
    runtime: Runtime,
    theme_path: str,
    class_name: str,
    name: str,
    value: Any,
) -> dict:
    require_writable(runtime)
    return await runtime.send_command(
        "theme_set_color",
        {
            "theme_path": theme_path,
            "class_name": class_name,
            "name": name,
            "value": value,
        },
    )


async def theme_set_constant(
    runtime: Runtime,
    theme_path: str,
    class_name: str,
    name: str,
    value: int,
) -> dict:
    require_writable(runtime)
    return await runtime.send_command(
        "theme_set_constant",
        {
            "theme_path": theme_path,
            "class_name": class_name,
            "name": name,
            "value": value,
        },
    )


async def theme_set_font_size(
    runtime: Runtime,
    theme_path: str,
    class_name: str,
    name: str,
    value: int,
) -> dict:
    require_writable(runtime)
    return await runtime.send_command(
        "theme_set_font_size",
        {
            "theme_path": theme_path,
            "class_name": class_name,
            "name": name,
            "value": value,
        },
    )


async def theme_set_stylebox_flat(
    runtime: Runtime,
    theme_path: str,
    class_name: str,
    name: str,
    bg_color: Any = None,
    border_color: Any = None,
    border_width: int | None = None,
    corner_radius: int | None = None,
    content_margin: float | None = None,
    shadow_color: Any = None,
    shadow_size: int | None = None,
    shadow_offset_x: float | None = None,
    shadow_offset_y: float | None = None,
    anti_aliasing: bool | None = None,
) -> dict:
    require_writable(runtime)
    params: dict[str, Any] = {
        "theme_path": theme_path,
        "class_name": class_name,
        "name": name,
    }
    if bg_color is not None:
        params["bg_color"] = bg_color
    if border_color is not None:
        params["border_color"] = border_color
    if border_width is not None:
        params["border_width"] = border_width
    if corner_radius is not None:
        params["corner_radius"] = corner_radius
    if content_margin is not None:
        params["content_margin"] = content_margin
    if shadow_color is not None:
        params["shadow_color"] = shadow_color
    if shadow_size is not None:
        params["shadow_size"] = shadow_size
    if shadow_offset_x is not None:
        params["shadow_offset_x"] = shadow_offset_x
    if shadow_offset_y is not None:
        params["shadow_offset_y"] = shadow_offset_y
    if anti_aliasing is not None:
        params["anti_aliasing"] = anti_aliasing
    return await runtime.send_command("theme_set_stylebox_flat", params)


async def theme_apply(
    runtime: Runtime,
    node_path: str,
    theme_path: str = "",
) -> dict:
    require_writable(runtime)
    return await runtime.send_command(
        "apply_theme",
        {"node_path": node_path, "theme_path": theme_path},
    )

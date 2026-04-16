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
    # Per-side border width overrides
    border_width_top: int | None = None,
    border_width_bottom: int | None = None,
    border_width_left: int | None = None,
    border_width_right: int | None = None,
    # Per-corner radius overrides
    corner_radius_top_left: int | None = None,
    corner_radius_top_right: int | None = None,
    corner_radius_bottom_left: int | None = None,
    corner_radius_bottom_right: int | None = None,
    # Per-side content margin overrides
    content_margin_top: float | None = None,
    content_margin_bottom: float | None = None,
    content_margin_left: float | None = None,
    content_margin_right: float | None = None,
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
    # Per-side overrides
    for key, val in [
        ("border_width_top", border_width_top),
        ("border_width_bottom", border_width_bottom),
        ("border_width_left", border_width_left),
        ("border_width_right", border_width_right),
        ("corner_radius_top_left", corner_radius_top_left),
        ("corner_radius_top_right", corner_radius_top_right),
        ("corner_radius_bottom_left", corner_radius_bottom_left),
        ("corner_radius_bottom_right", corner_radius_bottom_right),
        ("content_margin_top", content_margin_top),
        ("content_margin_bottom", content_margin_bottom),
        ("content_margin_left", content_margin_left),
        ("content_margin_right", content_margin_right),
    ]:
        if val is not None:
            params[key] = val
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

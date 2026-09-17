"""Shared handlers for Theme authoring (colors, stylebox, apply)."""

from __future__ import annotations

from typing import Any

from godot_ai.handlers._readiness import require_writable_async
from godot_ai.runtime.direct import DirectRuntime


async def theme_create(
    runtime: DirectRuntime,
    path: str,
    overwrite: bool = False,
) -> dict:
    await require_writable_async(runtime)
    return await runtime.send_command(
        "create_theme",
        {"path": path, "overwrite": overwrite},
    )


async def theme_set_color(
    runtime: DirectRuntime,
    theme_path: str,
    class_name: str,
    name: str,
    value: Any,
) -> dict:
    await require_writable_async(runtime)
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
    runtime: DirectRuntime,
    theme_path: str,
    class_name: str,
    name: str,
    value: int,
) -> dict:
    await require_writable_async(runtime)
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
    runtime: DirectRuntime,
    theme_path: str,
    class_name: str,
    name: str,
    value: int,
) -> dict:
    await require_writable_async(runtime)
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
    runtime: DirectRuntime,
    theme_path: str,
    class_name: str,
    name: str,
    bg_color: Any = None,
    border_color: Any = None,
    border: dict[str, Any] | None = None,
    corners: dict[str, Any] | None = None,
    margins: dict[str, Any] | None = None,
    shadow: dict[str, Any] | None = None,
    anti_aliasing: bool | None = None,
) -> dict:
    await require_writable_async(runtime)
    params: dict[str, Any] = {
        "theme_path": theme_path,
        "class_name": class_name,
        "name": name,
    }
    if bg_color is not None:
        params["bg_color"] = bg_color
    if border_color is not None:
        params["border_color"] = border_color
    if border is not None:
        params["border"] = border
    if corners is not None:
        params["corners"] = corners
    if margins is not None:
        params["margins"] = margins
    if shadow is not None:
        params["shadow"] = shadow
    if anti_aliasing is not None:
        params["anti_aliasing"] = anti_aliasing
    return await runtime.send_command("theme_set_stylebox_flat", params)


async def theme_apply(
    runtime: DirectRuntime,
    node_path: str,
    theme_path: str = "",
) -> dict:
    await require_writable_async(runtime)
    return await runtime.send_command(
        "apply_theme",
        {"node_path": node_path, "theme_path": theme_path},
    )


async def theme_set_stylebox_texture(
    runtime: DirectRuntime,
    theme_path: str,
    class_name: str,
    name: str,
    texture_path: str,
    region: Any = None,
    margins: dict[str, Any] | None = None,
    axis_stretch_horizontal: str | None = None,
    axis_stretch_vertical: str | None = None,
    modulate_color: Any = None,
    draw_center: bool | None = None,
) -> dict:
    await require_writable_async(runtime)
    params: dict[str, Any] = {
        "theme_path": theme_path,
        "class_name": class_name,
        "name": name,
        "texture_path": texture_path,
    }
    if region is not None:
        params["region"] = region
    if margins is not None:
        params["margins"] = margins
    if axis_stretch_horizontal is not None:
        params["axis_stretch_horizontal"] = axis_stretch_horizontal
    if axis_stretch_vertical is not None:
        params["axis_stretch_vertical"] = axis_stretch_vertical
    if modulate_color is not None:
        params["modulate_color"] = modulate_color
    if draw_center is not None:
        params["draw_center"] = draw_center
    return await runtime.send_command("theme_set_stylebox_texture", params)


async def theme_set_font(
    runtime: DirectRuntime,
    theme_path: str,
    class_name: str,
    name: str,
    font_path: str,
) -> dict:
    await require_writable_async(runtime)
    return await runtime.send_command(
        "theme_set_font",
        {
            "theme_path": theme_path,
            "class_name": class_name,
            "name": name,
            "font_path": font_path,
        },
    )


async def theme_set_icon(
    runtime: DirectRuntime,
    theme_path: str,
    class_name: str,
    name: str,
    texture_path: str,
) -> dict:
    await require_writable_async(runtime)
    return await runtime.send_command(
        "theme_set_icon",
        {
            "theme_path": theme_path,
            "class_name": class_name,
            "name": name,
            "texture_path": texture_path,
        },
    )


async def theme_stylebox_override(
    runtime: DirectRuntime,
    path: str,
    slot: str,
    patch: dict[str, Any],
) -> dict:
    await require_writable_async(runtime)
    return await runtime.send_command(
        "theme_stylebox_override",
        {"path": path, "slot": slot, "patch": patch},
    )

"""Shared handlers for GridMap authoring tools."""

from __future__ import annotations

from godot_ai.handlers._readiness import require_writable_async
from godot_ai.runtime.direct import DirectRuntime


async def gridmap_set_item(
    runtime: DirectRuntime,
    path: str,
    item: int,
    map_x: int,
    map_y: int,
    map_z: int,
    orientation: int = 0,
) -> dict:
    """Set a single cell item at (map_x, map_y, map_z) on a GridMap node.

    ``item=-1`` erases the cell.
    """
    await require_writable_async(runtime)
    return await runtime.send_command(
        "gridmap_set_item",
        {
            "path": path,
            "item": item,
            "map_x": map_x,
            "map_y": map_y,
            "map_z": map_z,
            "orientation": orientation,
        },
    )


async def gridmap_fill(
    runtime: DirectRuntime,
    path: str,
    item: int,
    rect_x: int,
    rect_y: int,
    rect_z: int,
    rect_w: int,
    rect_h: int,
    rect_d: int,
    orientation: int = 0,
) -> dict:
    """Fill a rect_w × rect_h × rect_d region with one item in a single undo
    action.
    """
    await require_writable_async(runtime)
    return await runtime.send_command(
        "gridmap_fill",
        {
            "path": path,
            "item": item,
            "rect_x": rect_x,
            "rect_y": rect_y,
            "rect_z": rect_z,
            "rect_w": rect_w,
            "rect_h": rect_h,
            "rect_d": rect_d,
            "orientation": orientation,
        },
    )


async def gridmap_clear(
    runtime: DirectRuntime,
    path: str,
) -> dict:
    """Remove all cells from a GridMap node."""
    await require_writable_async(runtime)
    return await runtime.send_command("gridmap_clear", {"path": path})


async def gridmap_get_used_cells(
    runtime: DirectRuntime,
    path: str,
) -> dict:
    """Return all used cell coordinates of a GridMap node.

    Returns ``{cells: [{x, y, z}, ...], count: int}``.
    """
    return await runtime.send_command("gridmap_get_used_cells", {"path": path})


async def gridmap_list_library_items(
    runtime: DirectRuntime,
    path: str,
) -> dict:
    """List the MeshLibrary items available to a GridMap node.

    Returns ``{library: res:// path or "", items: [{item, name, mesh}...],
    count: int}`` so agents can discover item ids before placing cells.
    """
    return await runtime.send_command("gridmap_list_library_items", {"path": path})

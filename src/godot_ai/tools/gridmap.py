"""MCP tool for GridMap authoring."""

from __future__ import annotations

from fastmcp import FastMCP

from godot_ai.handlers import gridmap as gridmap_handlers
from godot_ai.tools._meta_tool import register_manage_tool

_DESCRIPTION = """\
GridMap authoring (set items, fill 3D regions, clear, read cells + library items).

All operations target GridMap nodes in the currently edited scene by
scene-relative path (e.g. "/Main/Terrain"). All write ops are undoable via
EditorUndoRedoManager.

item is the item id from the GridMap's MeshLibrary. Use
gridmap_list_library_items to discover valid ids and names before placing
cells (the 3D analogue of tileset atlas inspection). orientation is the
GridMap baked rotation index (0..24).

Ops:
  • gridmap_set_item(path, item, map_x, map_y, map_z, orientation=0)
        Set a single cell item at (map_x, map_y, map_z). item=-1 erases.
        Returns: {map_x, map_y, map_z, item, orientation}

  • gridmap_fill(path, item, rect_x, rect_y, rect_z, rect_w, rect_h, rect_d,
                  orientation=0)
        Fill a rect_w × rect_h × rect_d region starting at (rect_x, rect_y,
        rect_z) with one item in a single undo action.
        Returns: {cells_filled, rect: {x, y, z, w, h, d}}

  • gridmap_clear(path)
        Remove all cells from the GridMap.
        Returns: {cleared: true}

  • gridmap_get_used_cells(path)
        Return all used cell coordinates.
        Returns: {cells: [{x, y, z}, ...], count: int}

  • gridmap_list_library_items(path)
        List the MeshLibrary items available to the GridMap.
        Returns: {library, items: [{item, name, mesh}...], count: int}
"""


def register_gridmap_tools(mcp: FastMCP) -> None:
    register_manage_tool(
        mcp,
        tool_name="gridmap_manage",
        description=_DESCRIPTION,
        ops={
            "gridmap_set_item":           gridmap_handlers.gridmap_set_item,
            "gridmap_fill":               gridmap_handlers.gridmap_fill,
            "gridmap_clear":              gridmap_handlers.gridmap_clear,
            "gridmap_get_used_cells":     gridmap_handlers.gridmap_get_used_cells,
            "gridmap_list_library_items": gridmap_handlers.gridmap_list_library_items,
        },
        read_resource_forms={
            "gridmap_get_used_cells":     None,
            "gridmap_list_library_items": None,
        },
    )

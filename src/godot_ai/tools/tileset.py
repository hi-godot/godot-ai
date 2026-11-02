"""MCP tool for TileSet management."""

from __future__ import annotations

from fastmcp import FastMCP

from godot_ai.handlers import tileset as tileset_handlers
from godot_ai.tools._meta_tool import register_manage_tool

_DESCRIPTION = """\
TileSet management — atlas inspection tools.

Ops:
  • tileset_create_atlas(resource_path, texture_path, tile_size, tiles,
                         source_id=0, margins=None, separation=None, overwrite=False)
        Build a saved TileSet with one native atlas source. tile_size is {x,y}
        in pixels and sets both TileSet tile size and atlas cell size. tiles is
        [{"coords":{"x":0,"y":0},"size":{"x":1,"y":1}}]; size defaults to
        one cell. margins/separation are {x,y} pixel offsets, default zero.
        At most 4096 nonoverlapping tiles, all within the texture. No terrain,
        collision, animation or alternative-tile configuration is performed.
        Persistent, not scene-undoable. overwrite replaces the whole TileSet
        while retaining UID. Use existing atlas read ops to inspect the result.

  • tileset_get_atlas_tiles(tileset_path, source_id)
        Return all occupied atlas tile positions for one source in a TileSet.
        Read-only — does not modify any resource or project file.

        tileset_path: res:// path to the .tres TileSet resource (required)
        source_id:    raw TileSet source id of the TileSetAtlasSource to query (required, ≥ 0)

        Returns:
          {"tiles": [{"col": int, "row": int}, ...], "count": int}

        Error codes (passed through from GDScript handler):
          MISSING_REQUIRED_PARAM  — tileset_path empty or source_id absent
          RESOURCE_NOT_FOUND      — tileset_path does not exist on disk
          WRONG_TYPE              — not a TileSet, or source is not a TileSetAtlasSource
          VALUE_OUT_OF_RANGE      — source_id does not exist in this TileSet

  • tileset_get_atlas_image(tileset_path, source_id, max_size=0)
        Return the atlas sprite-sheet texture of a TileSetAtlasSource as a
        Base64-encoded PNG image.  Read-only — reads the texture directly
        from the resource without any UI interaction.

        tileset_path: res:// path to the .tres TileSet resource (required)
        source_id:    raw TileSet source id of the TileSetAtlasSource to query (required, ≥ 0)
        max_size:     optional int; if > 0, scale the image so its longest
                      edge is at most max_size pixels (default 0 = full res)

        Returns:
          {"image_base64": str, "width": int, "height": int,
           "original_width": int, "original_height": int, "format": "png"}

        Error codes (passed through from GDScript handler):
          MISSING_REQUIRED_PARAM  — tileset_path empty or source_id absent
          RESOURCE_NOT_FOUND      — tileset_path does not exist on disk
          WRONG_TYPE              — not a TileSet, source not a TileSetAtlasSource,
                                    or source has no texture assigned
          VALUE_OUT_OF_RANGE      — source_id does not exist in this TileSet

  • Atlas image workflow:
        To visually inspect what tiles look like, use tileset_get_atlas_image
        instead of editor screenshots. It reads the texture directly from the
        resource — no UI interaction or editor state required.
"""


def register_tileset_tools(mcp: FastMCP) -> None:
    register_manage_tool(
        mcp,
        tool_name="tileset_manage",
        description=_DESCRIPTION,
        ops={
            "tileset_create_atlas": tileset_handlers.tileset_create_atlas,
            "tileset_get_atlas_tiles": tileset_handlers.tileset_get_atlas_tiles,
            "tileset_get_atlas_image": tileset_handlers.tileset_get_atlas_image,
        },
        read_resource_forms={
            "tileset_get_atlas_tiles": None,
            "tileset_get_atlas_image": None,
        },
    )

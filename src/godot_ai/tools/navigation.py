"""MCP tool for navigation authoring — regions, baking, and path queries.

All operations collapse into ``navigation_manage`` — no new named tool. Both
2D (NavigationRegion2D / NavigationPolygon) and 3D counterparts share the same
ops, selected by ``dimension`` or inferred from the node class.
"""

from __future__ import annotations

from fastmcp import FastMCP

from godot_ai.handlers import navigation as navigation_handlers
from godot_ai.tools._meta_tool import register_manage_tool

_DESCRIPTION = """\
Navigation authoring for 2D and 3D: baking a region's navmesh/polygon and
path queries on an explicitly selected map.

Ops:
  • bake(path, scene_file="", force_sync=True)
        Bake the region's navmesh/polygon from its source geometry (children,
        per the mesh's source settings). The bake runs on the region's own
        background thread and the reply is deferred until it settles. Godot
        parses the source geometry synchronously inside the bake call (engine
        requirement) and cannot be preempted; the measured duration is reported
        as `parse_ms`, and the request is bounded by a 30 s deadline with
        per-frame cancellation checks. force_sync=True (default) pushes the
        baked resource to the server and force-syncs the map (temporarily
        disabling async map iterations, then restoring them); pass False to
        let the next physics frame pick it up instead. Undo restores the exact
        pre-bake resource; redo restores the exact baked resource without
        re-baking. Only one bake may be in flight per region. Not available
        inside batch_execute (it cannot await a deferred reply). Resource form:
        none — per-region write.
  • path_get(from_point, to_point, dimension="3d", optimize=True,
              navigation_layers=1, region_path="", force_sync=False)
        Query a path between two world points ({x,y[,z]} or [x,y[,z]}).
        region_path selects the NavigationRegion3D/2D whose map to query;
        when omitted the edited scene root's world map is used — the op never
        guesses a scene's "first" region. Read-only: force_sync=False
        (default) never touches the map's shared async-iteration policy;
        force_sync=True opts in to the same toggle + map_force_update that
        bake uses when the query must see a just-baked region immediately.
        Returns points, point_count. Resource form: none — per-query read.
"""


def register_navigation_tools(mcp: FastMCP) -> None:
    """Register the navigation_manage rollup and its ops."""
    register_manage_tool(
        mcp,
        tool_name="navigation_manage",
        description=_DESCRIPTION,
        ops={
            "bake": navigation_handlers.navigation_bake,
            "path_get": navigation_handlers.navigation_path_get,
        },
        read_resource_forms={
            ## Per-region and per-query reads with no aggregate URI shape.
            "path_get": None,
        },
    )

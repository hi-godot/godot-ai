"""MCP tool for navigation authoring — regions, baking, and path queries.

All operations collapse into ``navigation_manage`` — no new named tool. Both
2D/3D path queries select ``dimension`` or infer it from a region. Baking is
restricted to bounded 3D mesh-only source geometry.
"""

from __future__ import annotations

from fastmcp import FastMCP

from godot_ai.handlers import navigation as navigation_handlers
from godot_ai.tools._meta_tool import register_manage_tool

_DESCRIPTION = """\
Bounded 3D mesh-only navigation baking and 2D/3D
path queries on an explicitly selected map.

Ops:
  • bake(path, scene_file="", force_sync=True)
        Bake a 3D region from bounded mesh-only children. Requires NavigationMesh
        root-children source mode and mesh-instance or both geometry settings.
        Supports unscripted Node / Node3D containers and MeshInstance3D using plain
        ArrayMesh, BoxMesh, PlaneMesh, SphereMesh, CylinderMesh or CapsuleMesh. Rejects other source
        nodes/settings (groups, colliders, CSG, GridMap, obstacles); custom source
        parser callbacks are never invoked. 2D baking is unsupported.
        Limits: 256 source nodes, 2048 triangles, 6144 vertices in total,
        32 surfaces per ArrayMesh, and 1000000 estimated voxel cells. Source
        collection advances one bounded node per editor frame, then the engine
        bakes the collected snapshot asynchronously. These input limits are not
        a hardware-independent per-frame timing guarantee. Replies are deferred
        with a 30 s deadline; source edits abort the operation. Cancellation
        restores the old region resource; an already-started engine task may
        finish into its detached working copy. parse_ms reports collection time.
        force_sync=True pushes the result and synchronizes the map; False leaves
        map synchronization to the engine. Undo/redo restore exact retained
        resources. Only one bake per region; call directly, not in batch_execute.
        Resource form: none - per-region write.
  • path_get(from_point, to_point, dimension="3d", optimize=True,
              navigation_layers=1, region_path="", force_sync=False)
        Query a path between two world points ({x,y[,z]} or [x,y[,z]]).
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

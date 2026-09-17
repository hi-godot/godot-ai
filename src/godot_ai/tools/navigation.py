"""MCP tool for navigation authoring — regions, baking, agents, obstacles, paths.

All operations collapse into ``navigation_manage`` — no new named tool. Both
2D (NavigationRegion2D / NavigationAgent2D / NavigationObstacle2D /
NavigationPolygon) and 3D counterparts share the same ops, selected by
``dimension`` or inferred from the node class.
"""

from __future__ import annotations

from fastmcp import FastMCP

from godot_ai.handlers import navigation as navigation_handlers
from godot_ai.tools._meta_tool import register_manage_tool

_DESCRIPTION = """\
Navigation authoring for 2D and 3D: navigation regions with baked navmeshes,
agents, obstacles, and path queries.

Ops:
  • region_create(parent_path="", dimension="3d", name="", scene_file="")
        Create a NavigationRegion3D (NavigationMesh) or NavigationRegion2D
        (NavigationPolygon) with a fresh resource attached. Undoable.
  • mesh_configure(path, <property>=<value>, ..., scene_file="")
        Set navigation mesh / polygon parameters in one undo action.
        Properties are flat params (e.g. agent_radius=0.75, cell_size=0.5).
        3D: agent_radius, agent_height, agent_max_climb, agent_max_slope,
        cell_size, cell_height, border_size, region_min_size,
        region_merge_size, edge_max_length, edge_max_error,
        detail_sample_distance, detail_sample_max_error,
        geometry_collision_mask, vertices_per_polygon,
        geometry_parsed_geometry_type, geometry_source_geometry_mode,
        geometry_source_group_name.
        2D: agent_radius, cell_size, border_size, parsed_collision_mask,
        parsed_geometry_type, source_geometry_mode, source_geometry_group_name.
        Source-geometry selectors accept names: parsed geometry is
        mesh_instances | static_colliders | both; source mode is
        root_children | groups_with_children | groups_explicit.
        Resource form: none — per-region write.
  • bake(path, scene_file="")
        Bake the region's navmesh/polygon synchronously from its source
        geometry (children, per the mesh's source settings). The baked
        resource is pushed to the navigation server and the map is force-
        synced, but Godot 4.7's navigation server iterates maps on physics
        frames — in a running game a path_get right after bake sees the new
        geometry; in the editor an immediate query can still observe the
        pre-sync map. Undo restores the pre-bake mesh resource.
        Resource form: none — per-region write.
  • agent_create(parent_path="", dimension="3d", name="", scene_file="")
        Create a NavigationAgent3D/2D. Undoable.
  • agent_configure(path, <property>=<value>, ..., scene_file="")
        Set agent parameters in one undo action (flat params). 3D: radius,
        height, max_speed, path_desired_distance, target_desired_distance,
        path_max_distance, avoidance_enabled, navigation_layers,
        simplify_path, debug_enabled. 2D: same minus height.
  • obstacle_create(parent_path="", dimension="3d", name="", scene_file="")
        Create a NavigationObstacle3D/2D. Undoable.
  • obstacle_configure(path, <property>=<value>, ..., scene_file="")
        Set obstacle parameters in one undo action (flat params): radius,
        height (3D), avoidance_enabled.
  • path_get(from_point, to_point, dimension="3d", optimize=True,
              navigation_layers=1)
        Query a path on the edited scene's navigation map between two world
        points ({x,y[,z]} or [x,y[,z]]). Read-only; the map is force-synced
        first, but the server only rebuilds map geometry on physics frames —
        in a running game paths are current; in the editor a query issued
        before the first post-bake frame can return an empty path. Returns
        points, point_count. Resource form: none — per-query read.
"""


def register_navigation_tools(mcp: FastMCP) -> None:
    register_manage_tool(
        mcp,
        tool_name="navigation_manage",
        description=_DESCRIPTION,
        ops={
            "region_create": navigation_handlers.navigation_region_create,
            "mesh_configure": navigation_handlers.navigation_mesh_configure,
            "bake": navigation_handlers.navigation_bake,
            "agent_create": navigation_handlers.navigation_agent_create,
            "agent_configure": navigation_handlers.navigation_agent_configure,
            "obstacle_create": navigation_handlers.navigation_obstacle_create,
            "obstacle_configure": navigation_handlers.navigation_obstacle_configure,
            "path_get": navigation_handlers.navigation_path_get,
        },
        read_resource_forms={
            ## Per-region and per-query reads with no aggregate URI shape;
            ## agents fetch via the rollup ops.
            "path_get": None,
        },
    )

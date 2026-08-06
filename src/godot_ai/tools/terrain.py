"""MCP tool for terrain authoring."""

from __future__ import annotations

from fastmcp import FastMCP

from godot_ai.handlers import terrain as terrain_handlers
from godot_ai.tools._meta_tool import register_manage_tool

_DESCRIPTION = """\
Terrain authoring (deterministic heightmap meshes with optional collision).

Create and regenerate FastNoiseLite heightmap terrain in the currently
edited scene. The same seed + params always produce the same mesh, so
agents can iterate on seeds and compare screenshots honestly. Holes and
carved detail are CSG territory (csg_manage) — compose, don't duplicate.

Created containers are Node3D nodes holding a "TerrainMesh" MeshInstance3D
(ArrayMesh, height-tinted vertex colors) and, when generate_collision is
true, a "TerrainCollision" StaticBody3D with a ConcavePolygonShape3D built
from the same triangles. All write ops are undoable via
EditorUndoRedoManager.

Ops:
  • terrain_create(parent_path, name="", size=48, cell_size=2.0, seed=1337,
                    noise_type="simplex", frequency=0.05, octaves=3,
                    height_scale=8.0, base_height=0.0, generate_collision=true)
        Create a heightmap terrain under a Node3D parent (empty
        parent_path = scene root). noise_type: simplex | simplex_smooth |
        perlin | ridged | value. size: 4..128.
        Returns: {path, name, size, vertices, triangles, generate_collision}

  • terrain_regenerate(path, size=48, cell_size=2.0, seed=1337,
                        noise_type="simplex", frequency=0.05, octaves=3,
                        height_scale=8.0, base_height=0.0,
                        generate_collision=true)
        Rebuild an existing terrain container in place with new params;
        one undo action restores the previous mesh/collision state.
        Returns: {path, vertices, triangles, generate_collision}
"""


def register_terrain_tools(mcp: FastMCP) -> None:
    register_manage_tool(
        mcp,
        tool_name="terrain_manage",
        description=_DESCRIPTION,
        ops={
            "terrain_create":      terrain_handlers.terrain_create,
            "terrain_regenerate":  terrain_handlers.terrain_regenerate,
        },
    )

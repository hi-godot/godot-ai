"""MCP tool for CSG authoring."""

from __future__ import annotations

from fastmcp import FastMCP

from godot_ai.handlers import csg as csg_handlers
from godot_ai.tools._meta_tool import register_manage_tool

_DESCRIPTION = """\
CSG authoring (create boolean shapes, set their operation, bake a static mesh).

Create CSG shapes (box, sphere, cylinder, torus, polygon) under a Node3D
parent in the currently edited scene and set their boolean operation
(union / intersection / subtraction) so geometry like holes, caves and
tunnels can be carved directly in the editor. Creating shapes and changing
operations are undoable. Use a CSGCombiner3D parent to combine sibling shapes. Size,
position and material live on the created node — set them with
node_set_property / material_manage after creation.

Ops:
  • csg_create(parent_path, name="", shape="box", operation="union")
        Create a CSG shape under a Node3D parent (empty parent_path = scene
        root). shape: box | sphere | cylinder | torus | polygon.
        operation: union | intersection | subtraction.
        Returns: {path, name, shape, operation}

  • csg_set_operation(path, operation)
        Set the boolean operation of a CSG shape.
        operation: union | intersection | subtraction.
        Returns: {operation}

  • bake_mesh(path, resource_path, scene_file="", apply_material_override=False)
        Save a CSG root's evaluated geometry in local coordinates to a fresh
        res:// .res or .tres ArrayMesh. Includes pending edits and surface
        materials. Set apply_material_override=True to use the root's material
        override on every surface when present. The source stays editable.
        Call directly. File creation is persistent and returns undoable=false.
        Returns: {path, resource_path, surface_count, material_override_applied,
                  undoable, reason}
"""


def register_csg_tools(mcp: FastMCP) -> None:
    register_manage_tool(
        mcp,
        tool_name="csg_manage",
        description=_DESCRIPTION,
        ops={
            "bake_mesh":         csg_handlers.csg_bake_mesh,
            "csg_create":        csg_handlers.csg_create,
            "csg_set_operation": csg_handlers.csg_set_operation,
        },
    )

"""MCP tool for CSG authoring."""

from __future__ import annotations

from fastmcp import FastMCP

from godot_ai.handlers import csg as csg_handlers
from godot_ai.tools._meta_tool import register_manage_tool

_DESCRIPTION = """\
CSG authoring (create boolean shapes, set their operation).

Create CSG shapes (box, sphere, cylinder, torus, prism) under a Node3D
parent in the currently edited scene and set their boolean operation
(union / intersection / subtraction) so geometry like holes, caves and
tunnels can be carved directly in the editor. All write ops are undoable
via EditorUndoRedoManager. Sibling CSG shapes under the same parent combine
automatically; use a CSGCombiner3D parent for explicit grouping. Size,
position and material live on the created node — set them with
node_set_property / material_manage after creation.

Ops:
  • csg_create(parent_path, name="", shape="box", operation="union")
        Create a CSG shape under a Node3D parent (empty parent_path = scene
        root). shape: box | sphere | cylinder | torus | prism.
        operation: union | intersection | subtraction.
        Returns: {path, name, shape, operation}

  • csg_set_operation(path, operation)
        Set the boolean operation of a CSG shape.
        operation: union | intersection | subtraction.
        Returns: {operation}
"""


def register_csg_tools(mcp: FastMCP) -> None:
    register_manage_tool(
        mcp,
        tool_name="csg_manage",
        description=_DESCRIPTION,
        ops={
            "csg_create":        csg_handlers.csg_create,
            "csg_set_operation": csg_handlers.csg_set_operation,
        },
    )

"""MCP tool for Material authoring — paint meshes (PBR, emission, glass, shaders)."""

from __future__ import annotations

from fastmcp import FastMCP

from godot_ai.handlers import material as material_handlers
from godot_ai.tools._meta_tool import register_manage_tool

_DESCRIPTION = """\
Material authoring (StandardMaterial3D, ORMMaterial3D, ShaderMaterial,
CanvasItemMaterial). Albedo, metallic/roughness, emission, transparency,
shader uniforms.

Resource form: ``godot://materials`` — prefer for active-session reads.

Ops:
  • create(path, type="standard", shader_path="", overwrite=False)
        Create + save a material .tres at a res:// path. type:
        "standard" | "orm" | "canvas_item" | "shader". For "shader",
        shader_path points to the .gdshader.
  • set_param(path, param, value)
        Set a built-in property on a .tres material. Enum-valued params
        accept names ("alpha" -> TRANSPARENCY_ALPHA). Color/Vector dicts.
        Texture properties accept res:// paths.
  • set_shader_param(path, param, value)
        Set a shader uniform on a ShaderMaterial.
  • get(path)
        Inspect a material (type, params, uniforms, current values).
  • list(root="res://", type="")
        List materials under root, optional type filter.
  • assign(node_path, resource_path="", slot="override", create_if_missing=False,
            type="standard")
        Assign a material to a node slot. Slots: "override" |
        "surface_<N>" | "canvas" | "process". When create_if_missing=True
        and no resource_path, makes an inline material of `type`.
  • apply_to_node(node_path, type="standard", params=None, slot="override",
                   save_to="")
        High-level: build + set params + assign in one undo.
        save_to optionally persists to disk.
  • apply_preset(preset, path="", node_path="", overrides=None)
        Curated looks: metal, glass, emissive, unlit, matte, ceramic.
        path saves to disk; node_path assigns to a node; overrides merge.
"""


def register_material_tools(mcp: FastMCP) -> None:
    register_manage_tool(
        mcp,
        tool_name="material_manage",
        description=_DESCRIPTION,
        ops={
            "create": material_handlers.material_create,
            "set_param": material_handlers.material_set_param,
            "set_shader_param": material_handlers.material_set_shader_param,
            "get": material_handlers.material_get,
            "list": material_handlers.material_list,
            "assign": material_handlers.material_assign,
            "apply_to_node": material_handlers.material_apply_to_node,
            "apply_preset": material_handlers.material_apply_preset,
        },
    )

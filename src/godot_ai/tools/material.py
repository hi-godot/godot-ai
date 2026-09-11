"""MCP tool for Material authoring — paint meshes (PBR, emission, glass, shaders)."""

from __future__ import annotations

from fastmcp import FastMCP

from godot_ai.handlers import material as material_handlers
from godot_ai.handlers import shader as shader_handlers
from godot_ai.tools._meta_tool import register_manage_tool

_DESCRIPTION = """\
Material authoring (StandardMaterial3D, ORMMaterial3D, ShaderMaterial,
CanvasItemMaterial) and raw shader source (.gdshader / .gdshaderinc).
Albedo, metallic/roughness, emission, transparency, shader uniforms,
render modes.

Resource forms: ``godot://materials`` (all materials),
``godot://shader/{path}`` (one raw shader's source + parsed metadata).

Ops:
  • create(path, type="standard", shader_path="", code="", overwrite=False)
        Create + save a material .tres at a res:// path. type:
        "standard" | "orm" | "canvas_item" | "shader". For "shader", pass
        either shader_path (a .gdshader or VisualShader .tres) or code
        (inline .gdshader source, compiled before the material is saved).
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
                   save_to="", overwrite=False)
        High-level: build + set params + assign in one undo.
        save_to optionally persists to disk; errors if the file already
        exists unless overwrite=True.
  • apply_preset(preset, path="", node_path="", overrides=None)
        Curated looks: metal, glass, emissive, unlit, matte, ceramic.
        path saves to disk; node_path assigns to a node; overrides merge.
  • shader_create(resource_path, code, overwrite=False, shader_type="spatial")
        Create/replace a raw .gdshader (or .gdshaderinc include) from source
        text. The code is compiled through Godot before anything is written:
        parse errors reject the write with line-tagged diagnostics and leave
        any existing file untouched. Returns shader_type, uniforms (type,
        hint, hint_string, default), and cleanup hints. Not undoable.
  • shader_get(path)
        Read a .gdshader/.gdshaderinc: full source, shader_type, uniforms,
        render modes, and #include list.
  • shader_validate(code, kind="shader", shader_type="spatial")
        Compile shader source without writing a file. Returns valid plus
        errors/warnings with line numbers — use it to iterate on shader code
        before shader_create or shader_patch.
  • shader_list(root="res://")
        List .gdshader and .gdshaderinc files under a project directory.
  • shader_patch(path, old_text, new_text, replace_all=False)
        Anchor-based edit of a shader file: exact substring match, result
        revalidated before the file is replaced. Not undoable.
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
            "shader_create": shader_handlers.shader_create,
            "shader_get": shader_handlers.shader_get,
            "shader_validate": shader_handlers.shader_validate,
            "shader_list": shader_handlers.shader_list,
            "shader_patch": shader_handlers.shader_patch,
        },
        read_resource_forms={
            "get": None,  ## Per-material read; no per-resource URI shape.
            "list": "godot://materials",
            "shader_get": "godot://shader/{path*}",
            "shader_validate": None,  ## Takes source text, not a path.
            "shader_list": None,  ## Root-filtered scan; no per-resource URI.
        },
    )

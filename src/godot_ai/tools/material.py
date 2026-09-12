"""MCP tool for Material authoring — paint meshes (PBR, emission, glass, shaders)."""

from __future__ import annotations

from fastmcp import FastMCP

from godot_ai.handlers import material as material_handlers
from godot_ai.handlers import visual_shader as visual_shader_handlers
from godot_ai.tools._meta_tool import register_manage_tool

_DESCRIPTION = """\
Material authoring (StandardMaterial3D, ORMMaterial3D, ShaderMaterial,
CanvasItemMaterial) and VisualShader graph authoring/editing. Albedo,
metallic/roughness, emission, transparency, shader uniforms.

Resource forms: ``godot://materials`` (all materials),
``godot://visual_shader/{path}`` (one VisualShader graph).

Ops:
  • visual_shader_create_graph(resource_path, stages, shader_type="spatial",
                               overwrite=False, varyings=None)
        Create/save a VisualShader .tres only (not undoable). Each stages entry is
        {stage, nodes: [{id, type, position?, params?}], connections:
        [{from_node, from_port, to_node, to_port}]}. Explicit stages must match
        spatial/canvas_item (vertex/fragment/light), particles
        (start/process/collide/start_custom/process_custom), sky (sky), or fog (fog).
        IDs are stage-local integers >=2 or nonempty strings; output is "output"/0.
        Limits: 256 nodes, 1024 connections total. Existing destination directory
        required. Returns id_map by stage as [{id, node_id}] in request order.
        varyings: [{name, mode: "vertex_to_frag_light"|"frag_to_light",
        type: "float"|"int"|"uint"|"vector2"|"vector3"|"vector4"|"boolean"|"transform"}]
        (spatial/canvas_item only).
        Use create(type="shader", shader_path=<saved .tres>) then assign separately.
  • visual_shader_get(path)
        Inspect a VisualShader .tres: shader_type, per-stage nodes (id, type,
        position, params), connections, and varyings. Use before visual_shader_edit.
  • visual_shader_node_catalog(filter="", offset=0, limit=100)
        List instantiable VisualShaderNode classes with the properties this tool
        accepts, plus legacy aliases. Discover valid node types and params before
        authoring a graph.
  • visual_shader_edit(resource_path, operations)
        Apply a validated operation list to an existing VisualShader .tres:
        add_node / remove_node / replace_node / set_node_params /
        set_node_position / connect / disconnect / add_varying / remove_varying.
        Operations run in order; string node ids added by the call are returned
        in `added` and can be referenced by later operations. The whole result
        is validated in memory, then saved atomically; not undoable.
  • create(path, type="standard", shader_path="", overwrite=False)
        Create + save a material .tres at a res:// path. type:
        "standard" | "orm" | "canvas_item" | "shader". For "shader",
        shader_path points to a .gdshader or VisualShader .tres.
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
"""


def register_material_tools(mcp: FastMCP) -> None:
    register_manage_tool(
        mcp,
        tool_name="material_manage",
        description=_DESCRIPTION,
        ops={
            "visual_shader_create_graph": visual_shader_handlers.create_graph,
            "visual_shader_get": visual_shader_handlers.get_graph,
            "visual_shader_node_catalog": visual_shader_handlers.node_catalog,
            "visual_shader_edit": visual_shader_handlers.edit_graph,
            "create": material_handlers.material_create,
            "set_param": material_handlers.material_set_param,
            "set_shader_param": material_handlers.material_set_shader_param,
            "get": material_handlers.material_get,
            "list": material_handlers.material_list,
            "assign": material_handlers.material_assign,
            "apply_to_node": material_handlers.material_apply_to_node,
            "apply_preset": material_handlers.material_apply_preset,
        },
        read_resource_forms={
            "get": None,  ## Per-material read; no per-resource URI shape.
            "list": "godot://materials",
            "visual_shader_get": "godot://visual_shader/{path*}",
            "visual_shader_node_catalog": None,  ## Class catalog, not a resource.
        },
    )

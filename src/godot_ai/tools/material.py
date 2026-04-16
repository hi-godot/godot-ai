"""MCP tools for Material authoring — paint meshes and surfaces with PBR, emission, glass, shaders.

Materials are Godot's shader-backed visual description of a surface: albedo
(base color), metallic/roughness (PBR), emission (glow), normal maps,
transparency, and more. A material lives either as a ``.tres`` resource on
disk (reusable across scenes) or inline on a node (local-to-scene).

Godot material types:

- ``StandardMaterial3D`` — the workhorse. Covers 95% of PBR needs with a
  fixed property set (no shader editing required). Good for "paint this
  mesh red and shiny".
- ``ORMMaterial3D`` — same as StandardMaterial3D but expects a packed
  occlusion/roughness/metallic texture. Slightly cheaper at runtime.
- ``CanvasItemMaterial`` — 2D material (blend mode, light mode). For
  Sprites, Labels, Control nodes.
- ``ShaderMaterial`` — custom ``.gdshader`` behind the scenes. Use when
  StandardMaterial3D isn't enough (dissolve effects, hologram, toon
  shading, water, etc.). Exposes ``shader_parameter/<name>`` uniforms.

Assignment happens per-node:

- ``MeshInstance3D.material_override`` — overrides every surface on the mesh.
- ``MeshInstance3D.surface_material_override_N`` — override surface N only.
- ``CanvasItem.material`` — 2D.
- ``GPUParticles3D.process_material`` / ``draw_pass_N`` — particle emitters.

High-level helpers:

- ``material_apply_to_node`` builds an inline material, sets params, and
  assigns it in one undo action (no ``.tres`` on disk unless ``save_to``).
- ``material_apply_preset`` gives you curated looks: metal, glass,
  emissive, unlit, matte, ceramic. All accept overrides.
"""

from __future__ import annotations

from typing import Annotated, Any

from fastmcp import Context, FastMCP

from godot_ai.handlers import material as material_handlers
from godot_ai.runtime.direct import DirectRuntime
from godot_ai.tools import DEFER_META, JsonCoerced


def register_material_tools(mcp: FastMCP) -> None:
    @mcp.tool(meta=DEFER_META)
    async def material_create(
        ctx: Context,
        path: str,
        type: str = "standard",
        shader_path: str = "",
        overwrite: bool = False,
        session_id: str = "",
    ) -> dict:
        """Create and save a material resource (.tres) at a res:// path.

        Use this when you want a reusable material that other scenes can
        reference. For one-off "paint this one node" changes, prefer
        ``material_apply_to_node`` with ``save_to=""``.

        Args:
            path: Destination res:// path ending in .tres
                (e.g. "res://materials/red_metal.tres").
            type: One of "standard" (StandardMaterial3D), "orm" (ORMMaterial3D),
                "canvas_item" (2D), or "shader" (ShaderMaterial).
            shader_path: For type="shader", res:// path to a .gdshader file.
                Ignored for other types.
            overwrite: If true, overwrite any existing file at that path.
            session_id: Optional Godot session to target. Empty = active session.
        """
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await material_handlers.material_create(
            runtime,
            path=path,
            type=type,
            shader_path=shader_path,
            overwrite=overwrite,
        )

    @mcp.tool(meta=DEFER_META)
    async def material_set_param(
        ctx: Context,
        path: str,
        property: str,
        value: Any,
        session_id: str = "",
    ) -> dict:
        """Set a built-in property on a material .tres file.

        Works for StandardMaterial3D / ORMMaterial3D / CanvasItemMaterial.
        Property names match the Godot class reference (e.g. "albedo_color",
        "metallic", "roughness", "emission_enabled", "emission",
        "emission_energy_multiplier", "normal_enabled", "normal_texture",
        "albedo_texture", "transparency").

        Enum-valued properties accept either an int or a string name:
        ``transparency="alpha"`` → ``TRANSPARENCY_ALPHA``;
        ``shading_mode="unshaded"`` → ``SHADING_MODE_UNSHADED``.

        For ShaderMaterial uniforms, use ``material_set_shader_param``.

        Args:
            path: res:// path to the material .tres file.
            property: Property name (e.g. "albedo_color", "metallic",
                "emission_enabled", "transparency").
            value: Value to set. Colors accept hex strings, named colors,
                or {r, g, b, a} dicts. Vectors accept {x, y, z} dicts.
                Texture properties accept res:// paths to images.
            session_id: Optional Godot session to target. Empty = active session.
        """
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await material_handlers.material_set_param(
            runtime, path=path, property=property, value=value
        )

    @mcp.tool(meta=DEFER_META)
    async def material_set_shader_param(
        ctx: Context,
        path: str,
        param: str,
        value: Any,
        session_id: str = "",
    ) -> dict:
        """Set a shader uniform on a ShaderMaterial.

        Shader uniforms are the ``uniform`` declarations in the .gdshader —
        whatever the shader exposes (float, vec3, sampler2D, etc.). This is
        the uniform knob, not a built-in BaseMaterial3D property.

        Args:
            path: res:// path to the ShaderMaterial .tres file.
            param: Uniform name as declared in the shader
                (e.g. "pulse_strength", "base_color", "noise_texture").
            value: float, int, bool, Color-as-dict, Vector2/3/4-as-dict, or
                a res:// path string for Texture2D uniforms.
            session_id: Optional Godot session to target. Empty = active session.
        """
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await material_handlers.material_set_shader_param(
            runtime, path=path, param=param, value=value
        )

    @mcp.tool(meta=DEFER_META)
    async def material_get(
        ctx: Context,
        path: str,
        session_id: str = "",
    ) -> dict:
        """Inspect a material: type, parameters, shader uniforms, current values.

        Args:
            path: res:// path to the material .tres file.
            session_id: Optional Godot session to target. Empty = active session.
        """
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await material_handlers.material_get(runtime, path=path)

    @mcp.tool(meta=DEFER_META)
    async def material_list(
        ctx: Context,
        root: str = "res://",
        type: str = "",
        session_id: str = "",
    ) -> dict:
        """List material resources under a res:// root, optionally filtered by type.

        Args:
            root: res:// directory to search (e.g. "res://materials").
                Default is the project root.
            type: Optional Godot class name filter ("StandardMaterial3D",
                "ORMMaterial3D", "ShaderMaterial", "CanvasItemMaterial").
                Empty = all material subclasses.
            session_id: Optional Godot session to target. Empty = active session.
        """
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await material_handlers.material_list(runtime, root=root, type=type)

    @mcp.tool(meta=DEFER_META)
    async def material_assign(
        ctx: Context,
        node_path: str,
        resource_path: str = "",
        slot: str = "override",
        create_if_missing: bool = False,
        type: str = "standard",
        session_id: str = "",
    ) -> dict:
        """Assign a material resource to a node property — with auto-slot resolution.

        Slot names map to the right property for the node type:

        - ``"override"`` → ``MeshInstance3D.material_override``
        - ``"surface_0"``, ``"surface_1"``, ... → ``surface_material_override_N``
        - ``"canvas"`` → ``CanvasItem.material`` (2D)
        - ``"process"`` → ``GPUParticles*.process_material``

        If ``create_if_missing`` is true and ``resource_path`` is empty (or
        points nowhere), a new material of ``type`` is created in-memory and
        assigned (not saved to disk). The whole operation is one undo step.

        Args:
            node_path: Scene path to the target node.
            resource_path: res:// path to the material .tres. Optional if
                ``create_if_missing`` is true.
            slot: Which slot to assign to. Default "override" (works on 3D meshes).
            create_if_missing: If true, create a new material when none is
                provided or when the path doesn't exist.
            type: Material type to create if ``create_if_missing`` is true.
            session_id: Optional Godot session to target. Empty = active session.
        """
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await material_handlers.material_assign(
            runtime,
            node_path=node_path,
            resource_path=resource_path,
            slot=slot,
            create_if_missing=create_if_missing,
            type=type,
        )

    @mcp.tool(meta=DEFER_META)
    async def material_apply_to_node(
        ctx: Context,
        node_path: str,
        type: str = "standard",
        params: Annotated[dict[str, Any], JsonCoerced] | None = None,
        slot: str = "override",
        save_to: str = "",
        session_id: str = "",
    ) -> dict:
        """Build a material inline, set properties, assign to a node — one undo action.

        The high-level "paint this node" tool. Skips the create/set/assign
        three-step dance. By default the material is local-to-scene (no .tres
        on disk); pass ``save_to`` to persist it.

        Args:
            node_path: Scene path to the target node.
            type: "standard" | "orm" | "canvas_item" | "shader".
            params: Dict of material properties to set
                (e.g. {"albedo_color": "#ff0000", "metallic": 0.9}).
            slot: Which material slot to assign to (see ``material_assign``).
            save_to: Optional res:// path; if provided the material is also
                saved to disk for reuse.
            session_id: Optional Godot session to target. Empty = active session.
        """
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await material_handlers.material_apply_to_node(
            runtime,
            node_path=node_path,
            type=type,
            params=params or {},
            slot=slot,
            save_to=save_to,
        )

    @mcp.tool(meta=DEFER_META)
    async def material_apply_preset(
        ctx: Context,
        preset: str,
        path: str = "",
        node_path: str = "",
        overrides: Annotated[dict[str, Any], JsonCoerced] | None = None,
        session_id: str = "",
    ) -> dict:
        """Apply a curated material preset — metal, glass, emissive, unlit, matte, ceramic.

        Presets are opinionated starting points for common looks:

        - ``metal`` — ORM material, metallic=1.0, roughness=0.25
        - ``glass`` — Standard, transparency=alpha, low roughness, refraction
        - ``emissive`` — Standard with emission on, energy=3
        - ``unlit`` — Standard with shading_mode=unshaded
        - ``matte`` — Standard, roughness=1.0, metallic=0.0
        - ``ceramic`` — Standard, low metallic, clearcoat on

        Provide ``node_path`` to also assign the preset material to the node;
        provide ``path`` to save it to disk. ``overrides`` merges on top of the
        preset defaults (e.g. a red glass: preset=glass, overrides={albedo_color:"#ff0000"}).

        Args:
            preset: Preset name.
            path: Optional res:// path to save the material to.
            node_path: Optional scene path to assign the material to.
            overrides: Optional dict merged on top of preset defaults.
            session_id: Optional Godot session to target. Empty = active session.
        """
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await material_handlers.material_apply_preset(
            runtime,
            preset=preset,
            path=path,
            node_path=node_path,
            overrides=overrides or {},
        )

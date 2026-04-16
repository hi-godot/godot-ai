"""MCP tools for particle systems — fire, smoke, sparks, magic swirls, rain, explosions.

Godot ships four particle node types, all covered here:

- ``GPUParticles3D`` / ``GPUParticles2D`` — GPU-accelerated emitters. Their
  behavior is driven by a ``ParticleProcessMaterial`` (emission shape,
  initial velocity, gravity, color ramp, scale curve, turbulence, …). 3D
  emitters also need a mesh in ``draw_pass_1..4``; 2D emitters use a
  texture.
- ``CPUParticles3D`` / ``CPUParticles2D`` — no ProcessMaterial; all the
  same properties (emission_shape, initial_velocity_min, gravity,
  color_ramp) live directly on the node. Slightly slower but simpler.

All write tools wrap node creation and sub-resource creation (the
ProcessMaterial, a default QuadMesh draw pass) in a **single undo
action** — Ctrl-Z rolls back the entire spawn atomically.

High-level helpers:

- ``particle_apply_preset`` — fire, smoke, spark_burst, magic_swirl, rain,
  explosion. Opinionated defaults for common effects; accepts overrides.
- ``particle_create`` — bare emitter with sensible defaults. Use when you
  want to configure manually.

JSON coercion — ``color_ramp``, ``scale_curve``, ``emission_shape`` all
accept agent-friendly shapes (see tool docstrings) that are converted to
the real Godot types server-side.
"""

from __future__ import annotations

from typing import Annotated, Any

from fastmcp import Context, FastMCP

from godot_ai.handlers import particle as particle_handlers
from godot_ai.runtime.direct import DirectRuntime
from godot_ai.tools import DEFER_META, JsonCoerced


def register_particle_tools(mcp: FastMCP) -> None:
    @mcp.tool(meta=DEFER_META)
    async def particle_create(
        ctx: Context,
        parent_path: str,
        name: str = "Particles",
        type: str = "gpu_3d",
        session_id: str = "",
    ) -> dict:
        """Create a particle emitter node — GPU or CPU, 2D or 3D.

        For ``gpu_3d`` / ``gpu_2d``, a blank ``ParticleProcessMaterial`` is
        auto-created and assigned to ``process_material``. For ``gpu_3d``,
        a default ``QuadMesh`` is also auto-created for ``draw_pass_1``.
        Response surfaces ``process_material_created`` and
        ``draw_pass_mesh_created`` flags.

        Args:
            parent_path: Scene path of the parent node.
            name: Name for the new particle node.
            type: One of "gpu_3d", "gpu_2d", "cpu_3d", "cpu_2d".
            session_id: Optional Godot session to target. Empty = active session.
        """
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await particle_handlers.particle_create(
            runtime, parent_path=parent_path, name=name, type=type
        )

    @mcp.tool(meta=DEFER_META)
    async def particle_set_main(
        ctx: Context,
        node_path: str,
        properties: Annotated[dict[str, Any], JsonCoerced],
        session_id: str = "",
    ) -> dict:
        """Set node-level particle properties in one batch.

        Supported properties (names match the Godot class reference):
        ``amount``, ``lifetime``, ``one_shot``, ``explosiveness``,
        ``preprocess``, ``speed_scale``, ``randomness``, ``fixed_fps``,
        ``emitting``, ``local_coords``, ``interp_to_end``.

        Args:
            node_path: Scene path to the particle node.
            properties: Dict of property name to value.
            session_id: Optional Godot session to target. Empty = active session.
        """
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await particle_handlers.particle_set_main(
            runtime, node_path=node_path, properties=properties
        )

    @mcp.tool(meta=DEFER_META)
    async def particle_set_process(
        ctx: Context,
        node_path: str,
        properties: Annotated[dict[str, Any], JsonCoerced],
        session_id: str = "",
    ) -> dict:
        """Set the particle behavior — emission shape, velocity, gravity, color ramp.

        For GPU particles, this targets the ``ParticleProcessMaterial``
        (auto-creates one if the node doesn't have one yet; flagged in the
        response as ``process_material_created=true``). For CPU particles,
        the same vocabulary maps to direct node properties.

        Supported properties (union of GPU + CPU vocabulary):

        - Emission: ``emission_shape`` ("point", "sphere", "sphere_surface",
          "box", "ring"), ``emission_sphere_radius``, ``emission_box_extents``,
          ``emission_ring_radius``, ``emission_ring_inner_radius``,
          ``emission_ring_height``.
        - Velocity: ``direction`` (Vector3-as-dict), ``spread``,
          ``initial_velocity_min``, ``initial_velocity_max``,
          ``gravity`` (Vector3-as-dict).
        - Scale: ``scale_min``, ``scale_max``, ``scale_curve``
          ([{time, value}, ...]).
        - Color: ``color`` (base color), ``color_ramp``
          ({stops: [{time, color}, ...]}) — wrapped in a GradientTexture1D
          automatically.
        - Rotation: ``angle_min``, ``angle_max``, ``angular_velocity_min``,
          ``angular_velocity_max``.
        - Damping: ``damping_min``, ``damping_max``.
        - Turbulence: ``turbulence_enabled``, ``turbulence_noise_strength``,
          ``turbulence_noise_scale``, ``turbulence_noise_speed``
          (Vector3-as-dict).

        Args:
            node_path: Scene path to the particle node.
            properties: Dict of property name to value.
            session_id: Optional Godot session to target. Empty = active session.
        """
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await particle_handlers.particle_set_process(
            runtime, node_path=node_path, properties=properties
        )

    @mcp.tool(meta=DEFER_META)
    async def particle_set_draw_pass(
        ctx: Context,
        node_path: str,
        pass_: Annotated[int, "Draw-pass slot 1..4 (GPU 3D); ignored for 2D/CPU"] = 1,
        mesh: str = "",
        texture: str = "",
        material: str = "",
        session_id: str = "",
    ) -> dict:
        """Set what gets drawn per particle: mesh (3D), texture (2D), or material.

        Behavior by node type:

        - GPU 3D: ``draw_pass_N`` slot holds a Mesh; optionally a material is
          assigned as the mesh's ``surface_material_override_0``. If neither
          ``mesh`` nor ``texture`` is provided and the slot is empty, a
          default ``QuadMesh`` is auto-created (flagged in response).
        - GPU 2D: ``texture`` property on the node.
        - CPU 3D: ``mesh`` property on the node.
        - CPU 2D: ``texture`` property on the node.

        Args:
            node_path: Scene path to the particle node.
            pass_: GPU 3D draw-pass slot number (1-4). Ignored for 2D/CPU.
            mesh: Optional res:// path to a Mesh (.tres, .obj, .mesh).
            texture: Optional res:// path to a Texture2D (for 2D variants).
            material: Optional res:// path to a Material applied to the mesh.
            session_id: Optional Godot session to target. Empty = active session.
        """
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await particle_handlers.particle_set_draw_pass(
            runtime,
            node_path=node_path,
            pass_=pass_,
            mesh=mesh,
            texture=texture,
            material=material,
        )

    @mcp.tool(meta=DEFER_META)
    async def particle_restart(
        ctx: Context,
        node_path: str,
        session_id: str = "",
    ) -> dict:
        """Restart emission on a particle node. Runtime-only, not undoable.

        Useful for one-shot emitters (burst effects) or to re-trigger a
        preview in the editor.

        Args:
            node_path: Scene path to the particle node.
            session_id: Optional Godot session to target. Empty = active session.
        """
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await particle_handlers.particle_restart(runtime, node_path=node_path)

    @mcp.tool(meta=DEFER_META)
    async def particle_get(
        ctx: Context,
        node_path: str,
        session_id: str = "",
    ) -> dict:
        """Inspect a particle node — main props, process material, draw passes.

        Args:
            node_path: Scene path to the particle node.
            session_id: Optional Godot session to target. Empty = active session.
        """
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await particle_handlers.particle_get(runtime, node_path=node_path)

    @mcp.tool(meta=DEFER_META)
    async def particle_apply_preset(
        ctx: Context,
        parent_path: str,
        name: str,
        preset: str,
        type: str = "gpu_3d",
        overrides: Annotated[dict[str, Any], JsonCoerced] | None = None,
        session_id: str = "",
    ) -> dict:
        """Spawn a curated particle effect — fire, smoke, spark_burst, magic_swirl, rain, explosion.

        All presets create the node, configure the process behavior, and set
        up a draw pass — all in one undo action. Presets can target any
        supported ``type``; ``fire`` as ``gpu_2d`` works, though the presets
        are tuned for 3D.

        Preset details:

        - ``fire`` — upward buoyancy, white→orange→red→transparent gradient,
          sphere emission. Looping.
        - ``smoke`` — slow rising gray gradient, sphere emission, long lifetime.
        - ``spark_burst`` — one-shot, high-velocity point emission, gravity-affected.
        - ``magic_swirl`` — ring emission, tangential velocity, cyan→magenta.
        - ``rain`` — box emission from above, fast downward velocity.
        - ``explosion`` — one-shot radial spark + smoke, strong explosiveness.

        Args:
            parent_path: Scene path of the parent node.
            name: Name for the new particle node.
            preset: One of the names above.
            type: "gpu_3d" | "gpu_2d" | "cpu_3d" | "cpu_2d".
            overrides: Dict merged on top of preset defaults — you can override
                both main props and process-material props in one go.
            session_id: Optional Godot session to target. Empty = active session.
        """
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await particle_handlers.particle_apply_preset(
            runtime,
            parent_path=parent_path,
            name=name,
            preset=preset,
            type=type,
            overrides=overrides or {},
        )

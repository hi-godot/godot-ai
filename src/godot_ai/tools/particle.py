"""MCP tool for particle systems — fire, smoke, sparks, rain, explosions."""

from __future__ import annotations

from fastmcp import FastMCP

from godot_ai.handlers import particle as particle_handlers
from godot_ai.tools._meta_tool import register_manage_tool

_DESCRIPTION = """\
Particle systems (GPUParticles2D/3D, CPUParticles2D/3D). All write ops
create the node + sub-resources (ProcessMaterial, default QuadMesh draw
pass) in a single undo action.

Ops:
  • create(parent_path, name="Particles", type="gpu_3d")
        Create an emitter. type: "gpu_3d" | "gpu_2d" | "cpu_3d" | "cpu_2d".
        For GPU emitters, auto-creates ProcessMaterial; for gpu_3d, also
        a default QuadMesh draw pass.
  • set_main(node_path, properties)
        Node-level props: amount, lifetime, one_shot, explosiveness,
        preprocess, speed_scale, randomness, fixed_fps, emitting,
        local_coords, interp_to_end.
  • set_process(node_path, properties)
        Behavior props (auto-creates ProcessMaterial for GPU). Emission shape,
        velocity, gravity, color_ramp, scale_curve, turbulence. See full
        property list in the Godot reference.
  • set_draw_pass(node_path, pass_=1, mesh="", texture="", material="")
        What gets drawn per particle. GPU 3D: mesh in draw_pass_N + optional
        material override. GPU 2D / CPU 2D: texture. CPU 3D: mesh.
  • restart(node_path)
        Restart emission. Runtime-only, not undoable.
  • get(node_path)
        Inspect main props, process material, draw passes.
  • apply_preset(parent_path, name, preset, type="gpu_3d", overrides=None)
        Curated effects: fire, smoke, spark_burst, magic_swirl, rain,
        explosion, lightning. One-shot presets re-trigger via restart.
"""


def register_particle_tools(mcp: FastMCP) -> None:
    register_manage_tool(
        mcp,
        tool_name="particle_manage",
        description=_DESCRIPTION,
        ops={
            "create": particle_handlers.particle_create,
            "set_main": particle_handlers.particle_set_main,
            "set_process": particle_handlers.particle_set_process,
            "set_draw_pass": particle_handlers.particle_set_draw_pass,
            "restart": particle_handlers.particle_restart,
            "get": particle_handlers.particle_get,
            "apply_preset": particle_handlers.particle_apply_preset,
        },
    )

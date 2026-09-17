"""MCP tool for physics body configuration and collision layer helpers.

All operations collapse into ``physics_manage`` — no new named tool. The
``resource_manage`` physics_shape ops stay where they are (published
surface); this domain configures existing bodies and areas.
"""

from __future__ import annotations

from fastmcp import FastMCP

from godot_ai.handlers import physics as physics_handlers
from godot_ai.tools._meta_tool import register_manage_tool

_DESCRIPTION = """\
Physics body configuration and collision layer/mask helpers for 2D and 3D
bodies and areas (RigidBody, StaticBody, CharacterBody, Area).

Ops:
  • body_get(path, scene_file="")
        Read a body's or area's physics configuration: collision_layer and
        collision_mask (bitmask plus resolved layer names), gravity,
        gravity_scale, mass, linear_damp, angular_damp, continuous_cd,
        freeze, area priority / monitoring / monitorable,
        physics_material_override. Resource form: none — per-body read.
  • body_configure(path, collision_layer=None, collision_mask=None,
                    gravity=None, gravity_scale=None, mass=None,
                    linear_damp=None, angular_damp=None, continuous_cd=None,
                    freeze=None, priority=None, monitoring=None,
                    monitorable=None, physics_material_override=None,
                    scene_file="")
        Set any subset in one undo action. collision_layer / collision_mask
        accept a bitmask int or an array of layer names defined with
        layers_set (e.g. ["player", "enemy"]). Class-inapplicable
        properties are refused: a StaticBody has no mass and reports
        PROPERTY_NOT_ON_CLASS. physics_material_override takes a res://
        PhysicsMaterial path or "" to clear. Returns applied + previous.
        Resource form: none — per-body write.
  • layers_get(dimension="3d")
        List the named physics layers as [{index, bit, name}, ...].
        Resource form: none — project-global read.
  • layers_set(dimension, layers)
        Name project physics layers. layers is {layer_index: name} with
        indexes 1-32 ("" clears a name). Saved to project.godot, so not
        undoable. Returns the updated layers with their bit values.
"""


def register_physics_tools(mcp: FastMCP) -> None:
    register_manage_tool(
        mcp,
        tool_name="physics_manage",
        description=_DESCRIPTION,
        ops={
            "body_get": physics_handlers.physics_body_get,
            "body_configure": physics_handlers.physics_body_configure,
            "layers_get": physics_handlers.physics_layers_get,
            "layers_set": physics_handlers.physics_layers_set,
        },
        read_resource_forms={
            ## Per-body and project-global reads with no aggregate URI shape;
            ## agents fetch via the rollup ops.
            "body_get": None,
            "layers_get": None,
        },
    )

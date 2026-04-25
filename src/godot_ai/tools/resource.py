"""MCP tool for resource search, inspection, assignment, and creation.

Absorbs single-verb domains: ``curve``, ``environment``, ``physics_shape``,
and ``texture`` (gradient/noise procedural textures). All Resource-class
operations live here.
"""

from __future__ import annotations

from fastmcp import FastMCP

from godot_ai.handlers import curve as curve_handlers
from godot_ai.handlers import environment as environment_handlers
from godot_ai.handlers import physics_shape as physics_shape_handlers
from godot_ai.handlers import resource as resource_handlers
from godot_ai.handlers import texture as texture_handlers
from godot_ai.tools._meta_tool import register_manage_tool

_DESCRIPTION = """\
Resource (asset) search, inspection, assignment, and creation. Covers
generic Resource subclasses plus specialized authoring (Curve, Environment,
physics shapes, gradient/noise textures).

Ops:
  • search(type="", path="", offset=0, limit=100)
        Search for resources by type or path. Type matching includes
        subclasses. At least one filter required. Paginated.
  • load(path)
        Inspect a .tres / .res — returns type and editor-visible properties.
  • assign(path, property, resource_path)
        Load and assign a resource to a node property. Undoable.
  • get_info(type)
        Introspect a Resource class — properties, parent, abstract flag,
        concrete_subclasses (for abstract bases). Read-only.
  • create(type, properties=None, path="", property="", resource_path="",
            overwrite=False)
        Instantiate a Resource subclass. Either path+property (assign to a
        node, undoable) or resource_path (save to .tres). For specific
        families (Curve, Environment, etc.) prefer the dedicated ops.
  • curve_set_points(points, path="", property="", resource_path="")
        Replace all points on a Curve / Curve2D / Curve3D. Auto-creates
        the curve resource if the slot is empty (curve_created flag).
  • environment_create(path="", preset="default", properties=None,
                        sky=None, resource_path="", overwrite=False)
        Build Environment + Sky chain. Presets: default | clear | sunset
        | night | fog. Either assign to a WorldEnvironment node or save .tres.
  • physics_shape_autofit(path, source_path="", shape_type="")
        Size a CollisionShape2D/3D to a sibling visual's bounds. Auto-creates
        the concrete Shape subclass if needed.
  • gradient_texture_create(stops, width=256, height=1, fill="linear",
                              path="", property="", resource_path="",
                              overwrite=False)
        Build GradientTexture2D from color stops. fill: linear | radial | square.
  • noise_texture_create(noise_type="simplex_smooth", width=512, height=512,
                          frequency=0.01, seed=0, fractal_octaves=0,
                          path="", property="", resource_path="",
                          overwrite=False)
        Build NoiseTexture2D wrapping FastNoiseLite. Noise types: simplex |
        simplex_smooth | perlin | cellular | value | value_cubic.
"""


def register_resource_tools(mcp: FastMCP) -> None:
    register_manage_tool(
        mcp,
        tool_name="resource_manage",
        description=_DESCRIPTION,
        ops={
            "search": lambda rt, p: resource_handlers.resource_search(rt, **p),
            "load": lambda rt, p: resource_handlers.resource_load(rt, **p),
            "assign": lambda rt, p: resource_handlers.resource_assign(rt, **p),
            "get_info": lambda rt, p: resource_handlers.resource_get_info(rt, **p),
            "create": lambda rt, p: resource_handlers.resource_create(rt, **p),
            "curve_set_points": lambda rt, p: curve_handlers.curve_set_points(rt, **p),
            "environment_create": lambda rt, p: environment_handlers.environment_create(rt, **p),
            "physics_shape_autofit": lambda rt, p: physics_shape_handlers.physics_shape_autofit(
                rt, **p
            ),
            "gradient_texture_create": lambda rt, p: texture_handlers.gradient_texture_create(
                rt, **p
            ),
            "noise_texture_create": lambda rt, p: texture_handlers.noise_texture_create(rt, **p),
        },
    )

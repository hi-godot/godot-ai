"""MCP tool for Camera2D / Camera3D authoring.

- ``Camera2D`` — zoom, offset, drag margins, limits, smoothing, anchor mode.
- ``Camera3D`` — FOV, near/far planes, projection (perspective / orthogonal /
  frustum), keep-aspect, doppler tracking.

Setting ``current=true`` auto-unmarks previously current cameras of the same
class in the same undo action — single Ctrl-Z reverts a camera switch.
"""

from __future__ import annotations

from fastmcp import FastMCP

from godot_ai.handlers import camera as camera_handlers
from godot_ai.tools._meta_tool import register_manage_tool

_DESCRIPTION = """\
Camera2D / Camera3D authoring (zoom, FOV, projection, smoothing, follow).

Ops:
  • create(parent_path, name="Camera", type="2d", make_current=False)
        Create a Camera2D ("2d") or Camera3D ("3d"). When make_current=True,
        unmarks previously current cameras of the same class in one undo.
  • configure(camera_path, properties)
        Batch-set properties. Class-aware. Enum-by-name (projection,
        keep_aspect, anchor_mode, doppler_tracking, process_callback).
        Vector2 dict coercion for zoom/offset.
  • set_limits_2d(camera_path, left?, right?, top?, bottom?, smoothed?)
        Set Camera2D bounds. Pass only the edges to change.
  • set_damping_2d(camera_path, position_speed?, rotation_speed?,
                    drag_margins?, drag_horizontal_enabled?,
                    drag_vertical_enabled?)
        Smooth Camera2D motion (position/rotation smoothing speeds + drag
        deadzone). drag_margins: {left,top,right,bottom} fractions [0,1].
  • follow_2d(camera_path, target_path, smoothing_speed=5.0, zero_transform=True)
        Reparent camera under target with smoothing — Godot-native follow.
  • get(camera_path="")
        Inspect a camera (class, current flag, all properties). Empty path
        resolves to the currently-active camera, falling back to the first.
  • list()
        List every Camera2D/Camera3D in the scene.
  • apply_preset(parent_path, name, preset, type=None, make_current=True,
                  overrides=None)
        Spawn with opinionated defaults. Presets: topdown_2d, platformer_2d,
        cinematic_3d, action_3d. overrides merge over preset values.
"""


def register_camera_tools(mcp: FastMCP) -> None:
    register_manage_tool(
        mcp,
        tool_name="camera_manage",
        description=_DESCRIPTION,
        ops={
            "create": camera_handlers.camera_create,
            "configure": camera_handlers.camera_configure,
            "set_limits_2d": camera_handlers.camera_set_limits_2d,
            "set_damping_2d": camera_handlers.camera_set_damping_2d,
            "follow_2d": camera_handlers.camera_follow_2d,
            "get": camera_handlers.camera_get,
            "list": camera_handlers.camera_list,
            "apply_preset": camera_handlers.camera_apply_preset,
        },
    )

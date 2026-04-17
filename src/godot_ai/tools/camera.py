"""MCP tools for Camera2D / Camera3D authoring.

Godot ships two camera node types, both covered here:

- ``Camera2D`` — zoom, offset, drag margins (deadzone), limits (room bounds),
  position and rotation smoothing (damping), anchor mode.
- ``Camera3D`` — FOV, near/far planes, projection (perspective / orthogonal /
  frustum), keep-aspect, doppler tracking.

Design goals:

- **Godot-native.** Follow = "reparent the camera under the target." No
  Cinemachine-style virtual-camera abstractions.
- **Damping/smoothing is first-class.** ``camera_set_damping_2d`` exposes
  position speed, rotation speed, and drag-margin deadzones in one call —
  the knobs that stop camera motion feeling jerky.
- **Sibling-unmark.** Setting ``current=true`` auto-unmarks previously
  current cameras of the same class in the same undo action — a single
  Ctrl-Z reverts a camera switch.
- **Enum-by-name.** ``keep_aspect="keep_height"``, ``projection="orthogonal"``,
  ``anchor_mode="drag_center"`` — no looking up int constants.

Screen shake is deliberately not in this surface: it's an animation, not a
camera property. Compose via ``animation_create_simple`` targeting the
camera's ``position`` / ``offset`` for now.
"""

from __future__ import annotations

from typing import Annotated, Any

from fastmcp import Context, FastMCP

from godot_ai.handlers import camera as camera_handlers
from godot_ai.runtime.direct import DirectRuntime
from godot_ai.tools import DEFER_META, JsonCoerced


def register_camera_tools(mcp: FastMCP) -> None:
    @mcp.tool(meta=DEFER_META)
    async def camera_create(
        ctx: Context,
        parent_path: str,
        name: str = "Camera",
        type: str = "2d",
        make_current: bool = False,
        session_id: str = "",
    ) -> dict:
        """Create a Camera2D or Camera3D under a parent node.

        When ``make_current=true``, sets ``current=true`` and unmarks any
        previously-current camera of the matching class — all in the same
        undo action so one Ctrl-Z reverts the switch.

        Args:
            parent_path: Scene path of the parent node.
            name: Name for the new camera node.
            type: "2d" for Camera2D, "3d" for Camera3D.
            make_current: If true, make this the active camera on spawn.
            session_id: Optional Godot session to target. Empty = active session.
        """
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await camera_handlers.camera_create(
            runtime,
            parent_path=parent_path,
            name=name,
            type=type,
            make_current=make_current,
        )

    @mcp.tool(meta=DEFER_META)
    async def camera_configure(
        ctx: Context,
        camera_path: str,
        properties: Annotated[dict[str, Any], JsonCoerced],
        session_id: str = "",
    ) -> dict:
        """Batch-set camera properties. Class-aware (Camera2D vs Camera3D).

        Rejects keys not valid for the resolved camera class with a list of
        valid keys. Enum-by-name coercion: ``projection`` ("perspective" /
        "orthogonal" / "frustum"), ``keep_aspect`` ("keep_width" /
        "keep_height"), ``anchor_mode`` ("fixed_top_left" / "drag_center"),
        ``doppler_tracking`` ("disabled" / "idle_step" / "physics_step"),
        ``process_callback`` ("physics" / "idle"). Vector2 dict coercion:
        ``zoom`` and ``offset`` accept ``{x, y}``.

        Setting ``current=true`` unmarks any previously-current camera of
        the same class in the same undo action.

        Camera2D properties (zoom, offset, drag margins, limits, smoothing):
          zoom, offset, anchor_mode, ignore_rotation, enabled, current,
          process_callback, position_smoothing_enabled,
          position_smoothing_speed, rotation_smoothing_enabled,
          rotation_smoothing_speed, drag_horizontal_enabled,
          drag_vertical_enabled, drag_horizontal_offset, drag_vertical_offset,
          drag_left_margin, drag_top_margin, drag_right_margin,
          drag_bottom_margin, limit_left, limit_right, limit_top,
          limit_bottom, limit_smoothed.

        Camera3D properties (FOV, projection, clip planes):
          fov, near, far, size, projection, keep_aspect, cull_mask,
          doppler_tracking, h_offset, v_offset, current.

        Args:
            camera_path: Scene path to the Camera2D or Camera3D.
            properties: Dict of property name to value.
            session_id: Optional Godot session to target. Empty = active session.
        """
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await camera_handlers.camera_configure(
            runtime, camera_path=camera_path, properties=properties
        )

    @mcp.tool(meta=DEFER_META)
    async def camera_set_limits_2d(
        ctx: Context,
        camera_path: str,
        left: int | None = None,
        right: int | None = None,
        top: int | None = None,
        bottom: int | None = None,
        smoothed: bool | None = None,
        session_id: str = "",
    ) -> dict:
        """Set Camera2D bounds (limits). Confine the camera to a room or arena.

        ``null`` / omitted values are not touched — pass only the edges you
        want to change. Errors on Camera3D.

        Args:
            camera_path: Scene path to the Camera2D.
            left: Left limit in world pixels.
            right: Right limit in world pixels.
            top: Top limit in world pixels.
            bottom: Bottom limit in world pixels.
            smoothed: If true, camera eases into the limit instead of clamping.
            session_id: Optional Godot session to target. Empty = active session.
        """
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await camera_handlers.camera_set_limits_2d(
            runtime,
            camera_path=camera_path,
            left=left,
            right=right,
            top=top,
            bottom=bottom,
            smoothed=smoothed,
        )

    @mcp.tool(meta=DEFER_META)
    async def camera_set_damping_2d(
        ctx: Context,
        camera_path: str,
        position_speed: float | None = None,
        rotation_speed: float | None = None,
        drag_margins: Annotated[dict[str, float] | None, JsonCoerced] = None,
        drag_horizontal_enabled: bool | None = None,
        drag_vertical_enabled: bool | None = None,
        session_id: str = "",
    ) -> dict:
        """Smooth out Camera2D motion — eliminates jerkiness when the target moves.

        Three native Camera2D dials, applied together in one undo action:

        - ``position_speed`` — Camera2D.position_smoothing_speed. Higher =
          snappier, lower = more damped. Typical 3-8 (Godot default 5.0).
          Setting to 0 or negative disables position smoothing.
        - ``rotation_speed`` — Camera2D.rotation_smoothing_speed. Same shape.
          Matters when the camera rotates with its target (e.g. top-down
          with a rotating player).
        - ``drag_margins`` — ``{left, top, right, bottom}`` in [0,1]
          (fraction of viewport). The camera doesn't move until the target
          leaves the deadzone. Kills jitter when the target nudges around.
          Missing keys are not touched.

        Errors on Camera3D — 3D cameras have no native smoothing properties.

        Args:
            camera_path: Scene path to the Camera2D.
            position_speed: Position smoothing speed; <= 0 disables smoothing.
            rotation_speed: Rotation smoothing speed; <= 0 disables.
            drag_margins: Dict of edge -> fraction-of-viewport [0,1].
            drag_horizontal_enabled: Enable horizontal drag deadzone.
            drag_vertical_enabled: Enable vertical drag deadzone.
            session_id: Optional Godot session to target. Empty = active session.
        """
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await camera_handlers.camera_set_damping_2d(
            runtime,
            camera_path=camera_path,
            position_speed=position_speed,
            rotation_speed=rotation_speed,
            drag_margins=drag_margins,
            drag_horizontal_enabled=drag_horizontal_enabled,
            drag_vertical_enabled=drag_vertical_enabled,
        )

    @mcp.tool(meta=DEFER_META)
    async def camera_follow_2d(
        ctx: Context,
        camera_path: str,
        target_path: str,
        smoothing_speed: float = 5.0,
        zero_transform: bool = True,
        session_id: str = "",
    ) -> dict:
        """Make a Camera2D follow a Node2D by parenting the camera under it.

        This is the Godot-native follow idiom — no virtual cameras, no
        scripts. The camera is reparented as a child of ``target_path``; its
        local position and rotation are zeroed (when ``zero_transform=true``);
        ``position_smoothing_enabled`` is turned on at ``smoothing_speed``.
        All bundled into one undo action.

        If the camera is already a child of the target, skips the reparent
        and just applies the smoothing properties.

        Pair with ``camera_set_damping_2d`` to tune feel (drag deadzone,
        rotation smoothing) after the initial follow is set up.

        Args:
            camera_path: Scene path to the Camera2D.
            target_path: Scene path to the Node2D to follow (e.g. the player).
            smoothing_speed: position_smoothing_speed. Higher = snappier.
            zero_transform: If true, reset camera's local position/rotation to zero
                after reparent so it sits exactly on the target.
            session_id: Optional Godot session to target. Empty = active session.
        """
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await camera_handlers.camera_follow_2d(
            runtime,
            camera_path=camera_path,
            target_path=target_path,
            smoothing_speed=smoothing_speed,
            zero_transform=zero_transform,
        )

    @mcp.tool(meta=DEFER_META)
    async def camera_get(
        ctx: Context,
        camera_path: str = "",
        session_id: str = "",
    ) -> dict:
        """Inspect a camera — returns class, current flag, and all properties.

        When ``camera_path`` is empty, resolves to the currently-active
        camera in the edited scene (first camera with ``current=true``),
        falling back to the first camera found if none are current.
        ``resolved_via`` in the response indicates which path was taken.

        Args:
            camera_path: Scene path to a camera, or empty for the current/first camera.
            session_id: Optional Godot session to target. Empty = active session.
        """
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await camera_handlers.camera_get(runtime, camera_path=camera_path)

    @mcp.tool(meta=DEFER_META)
    async def camera_list(
        ctx: Context,
        session_id: str = "",
    ) -> dict:
        """List every Camera2D and Camera3D in the edited scene.

        Returns ``{cameras: [{path, class, type, current}, ...]}``. Useful for
        answering "which cameras exist?" before creating new ones or switching.

        Args:
            session_id: Optional Godot session to target. Empty = active session.
        """
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await camera_handlers.camera_list(runtime)

    @mcp.tool(meta=DEFER_META)
    async def camera_apply_preset(
        ctx: Context,
        parent_path: str,
        name: str,
        preset: str,
        type: str | None = None,
        make_current: bool = True,
        overrides: Annotated[dict[str, Any] | None, JsonCoerced] = None,
        session_id: str = "",
    ) -> dict:
        """Spawn a camera with opinionated defaults for a common setup.

        Presets:

        - ``topdown_2d`` — Camera2D for top-down arenas/roguelites. 2x zoom,
          drag_center anchor, 5.0 position smoothing, 20% drag-margin deadzones
          on all edges. Drops right into a follow rig.
        - ``platformer_2d`` — Camera2D for side-scrollers. 1.5x zoom, snappy
          8.0 smoothing, horizontal drag deadzone only (vertical snap).
        - ``cinematic_3d`` — Camera3D with narrow 40° FOV, 500-unit far plane.
          Dramatic wide shots.
        - ``action_3d`` — Camera3D with wide 70° FOV, 200-unit far plane.
          First/third-person action.

        Creates the node, applies properties, optionally sets ``current=true``
        with sibling-unmark — all in one undo action. Pass ``overrides`` to
        change any preset property.

        Args:
            parent_path: Scene path of the parent node.
            name: Name for the new camera.
            preset: One of "topdown_2d", "platformer_2d", "cinematic_3d", "action_3d".
            type: "2d" or "3d". If omitted, uses the preset's natural type.
            make_current: If true, mark as the active camera on spawn.
            overrides: Dict of property -> value merged on top of preset defaults.
            session_id: Optional Godot session to target. Empty = active session.
        """
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await camera_handlers.camera_apply_preset(
            runtime,
            parent_path=parent_path,
            name=name,
            preset=preset,
            type=type,
            make_current=make_current,
            overrides=overrides,
        )

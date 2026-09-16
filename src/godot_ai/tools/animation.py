"""MCP tools for AnimationPlayer authoring.

`animation_create` stays as a top-level named tool (high-traffic verb).
Everything else (player creation, tracks, autoplay, presets, playback,
introspection) collapses into ``animation_manage``.
"""

from __future__ import annotations

from fastmcp import Context, FastMCP

from godot_ai.handlers import animation as animation_handlers
from godot_ai.runtime.direct import DirectRuntime
from godot_ai.tools import DEFER_META
from godot_ai.tools._meta_tool import register_manage_tool

_DESCRIPTION = """\
AnimationPlayer authoring (player, tracks, autoplay, presets, playback).

Ops:
  • player_create(parent_path, name="AnimationPlayer")
        Create an AnimationPlayer with empty default library.
  • delete(player_path, animation_name)
        Delete an animation clip from the default library. Undoable.
  • validate(player_path, animation_name)
        Check all track paths resolve. Returns broken_count + per-track issues.
  • add_property_track(player_path, animation_name, track_path, keyframes,
                        interpolation="linear")
        Add a property track. track_path: "NodeName:property". keyframes:
        [{time, value, transition?}, ...]. interpolation: linear|nearest|cubic.
  • add_method_track(player_path, animation_name, target_node_path, keyframes)
        Add a method track. keyframes: [{time, method, args?}, ...].
  • set_autoplay(player_path, animation_name="")
        Set autoplay. Empty animation_name clears.
  • play(player_path, animation_name="")
        Editor preview. Not saved with scene.
  • stop(player_path)
        Stop editor preview. Not saved with scene.
  • list(player_path)
        List animations with length, loop_mode, track_count.
  • get(player_path, animation_name)
        Inspect a clip's tracks and keyframes in detail.
  • create_simple(player_path, name, tweens, length=None, loop_mode="none",
                   overwrite=False)
        High-level: build a multi-track clip from tween specs in one call.
        tweens: [{target, property, from, to, duration, delay?, transition?}].
  • preset_fade(player_path, target_path, mode="in", duration=0.5,
                 animation_name="", overwrite=False)
        One-call fade-in/out (modulate.a).
  • preset_slide(player_path, target_path, direction="left", mode="in",
                  distance=None, duration=0.4, animation_name="", overwrite=False)
        One-call slide-in/out (position).
  • preset_shake(player_path, target_path, intensity=None, duration=0.3,
                  frequency=30.0, seed=0, animation_name="", overwrite=False)
        One-call shake (jittered position).
  • preset_pulse(player_path, target_path, property="scale", from_scale=1.0,
                  to_scale=1.1, from_value=None, to_value=None, duration=0.4,
                  loop_mode="none", animation_name="", overwrite=False)
        One-call pulse / hover-bounce (3-keyframe ping-pong). Defaults to
        `scale` via the from_scale/to_scale shortcut; any other property
        (e.g. "modulate:a", "modulate", "self_modulate", "position") uses
        from_value/to_value coerced against the property's real type.
        loop_mode="linear" turns it into a breathing loop.
  • preset_bounce(player_path, target_path, intensity=0.15, duration=0.4,
                   animation_name="", overwrite=False)
        One-call press feedback: center-pivot scale overshoot with a
        settle-back. Controls get pivot_offset recentered in the same undo.
  • preset_orbit(player_path, target_path, radius=None, clockwise=True,
                  duration=2.0, loop_mode="none", animation_name="",
                  overwrite=False)
        One-call circular position orbit around the target's current position
        (XZ plane for 3D, screen space for 2D/Control). radius defaults to 1.0
        (3D) / 100.0 (2D). Seamless; loop_mode="linear" keeps it going.
  • preset_sweep(player_path, target_path, turns=1.0, clockwise=True,
                  duration=1.0, loop_mode="none", animation_name="",
                  overwrite=False)
        One-call full-turn rotation sweep (radar / cooldown-ring). 3D rotates
        around local Y; Control/Node2D rotate in-plane. Controls get
        pivot_offset recentered in the same undo.
  • preset_drift(player_path, target_path, axis="x", distance=None,
                  duration=1.0, loop_mode="none", animation_name="",
                  overwrite=False)
        One-call one-axis position offset (scanlines, marquee, conveyor).
        distance defaults to 1.0 (3D) / 100.0 (2D); pair with
        loop_mode="linear" for continuous motion.

Preset target_path: accepts either a scene-absolute path (e.g. "/Main/World/Cube",
matching every other scene tool) or a path relative to the AnimationPlayer's
root_node (e.g. "World/Cube", matching how Animation tracks store node paths).
Scene-absolute targets outside the player's root_node subtree are converted to
a `..`-prefixed track path via root_node.get_path_to(target), the same shape
the relative form already accepts.
"""


def register_animation_tools(mcp: FastMCP) -> None:
    @mcp.tool(meta=DEFER_META)
    async def animation_create(
        ctx: Context,
        player_path: str,
        name: str,
        length: float,
        loop_mode: str = "none",
        overwrite: bool = False,
        session_id: str = "",
    ) -> dict:
        """Create a new Animation clip inside an AnimationPlayer's default library.

        After creating the clip, add tracks via ``animation_manage`` ops
        ``add_property_track`` / ``add_method_track`` / ``create_simple``.
        Track node paths are stored relative to the AnimationPlayer's
        ``root_node`` (default: its parent), not to the scene root — see
        ``animation_manage`` preset ops for a forgiving target_path that
        accepts either form.
        If ``player_path`` doesn't resolve, an AnimationPlayer is auto-created
        at that path (parent must exist).

        Args:
            player_path: Scene path to the AnimationPlayer node.
            name: Animation clip name (e.g. "idle", "pulse").
            length: Duration in seconds.
            loop_mode: "none" (default) | "linear" | "pingpong".
            overwrite: Replace an existing animation with the same name.
            session_id: Optional Godot session to target. Empty = active session.
        """
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await animation_handlers.animation_create(
            runtime,
            player_path=player_path,
            name=name,
            length=length,
            loop_mode=loop_mode,
            overwrite=overwrite,
        )

    register_manage_tool(
        mcp,
        tool_name="animation_manage",
        description=_DESCRIPTION,
        ops={
            "player_create": animation_handlers.animation_player_create,
            "delete": animation_handlers.animation_delete,
            "validate": animation_handlers.animation_validate,
            "add_property_track": animation_handlers.animation_add_property_track,
            "add_method_track": animation_handlers.animation_add_method_track,
            "set_autoplay": animation_handlers.animation_set_autoplay,
            "play": animation_handlers.animation_play,
            "stop": animation_handlers.animation_stop,
            "list": animation_handlers.animation_list,
            "get": animation_handlers.animation_get,
            "create_simple": animation_handlers.animation_create_simple,
            "preset_fade": animation_handlers.animation_preset_fade,
            "preset_slide": animation_handlers.animation_preset_slide,
            "preset_shake": animation_handlers.animation_preset_shake,
            "preset_pulse": animation_handlers.animation_preset_pulse,
            "preset_bounce": animation_handlers.animation_preset_bounce,
            "preset_orbit": animation_handlers.animation_preset_orbit,
            "preset_sweep": animation_handlers.animation_preset_sweep,
            "preset_drift": animation_handlers.animation_preset_drift,
        },
        read_resource_forms={
            ## No `godot://animations` resource exists. Animation reads are
            ## stateful (per-player, per-clip) and don't fit the single-URL
            ## resource shape; agents fetch via the rollup ops.
            "validate": None,
            "play": None,
            "stop": None,
            "list": None,
            "get": None,
        },
    )

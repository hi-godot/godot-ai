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

Resource form: ``godot://animations`` — prefer for active-session reads.

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
  • preset_pulse(player_path, target_path, from_scale=1.0, to_scale=1.1,
                  duration=0.4, animation_name="", overwrite=False)
        One-call pulse / hover-bounce (3-keyframe scale ping-pong).
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
        },
    )

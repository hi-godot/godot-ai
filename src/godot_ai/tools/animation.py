"""MCP tools for AnimationPlayer authoring — keyframes, tracks, autoplay, playback.

Use these tools to animate anything in a Godot scene — 2D, 3D, or UI:

- 2D (Node2D / Sprite2D / etc.): move sprites along paths, spin a coin, flash
  a damage frame via modulate, scale an explosion, fade a bullet trail.
- 3D (Node3D / MeshInstance3D / Camera3D / etc.): swing a door via rotation,
  dolly or shake a camera, bob a collectible on the Y axis, drive a light's
  energy for flicker, fade an object (requires a material override since
  modulate is CanvasItem-only in 3D).
- UI (Control / Panel / Label / etc.): fade HUD overlays, pulse buttons on
  hover, slide menus in from offscreen, shake a health bar on damage.

AnimationPlayer + Animation + AnimationLibrary form Godot's built-in animation
system. An AnimationPlayer node holds one or more AnimationLibraries, each
containing named Animation clips. Each clip has tracks — property tracks that
tween node properties (position, modulate, scale, rotation, fov, …) and method
tracks that fire callbacks at specific times. All authoring here targets the
default library ("") which saves automatically with the scene; the tools will
create an empty default library automatically if the AnimationPlayer doesn't
have one yet.
"""

from __future__ import annotations

from typing import Annotated, Any

from fastmcp import Context, FastMCP

from godot_ai.handlers import animation as animation_handlers
from godot_ai.runtime.direct import DirectRuntime
from godot_ai.tools import DEFER_META, JsonCoerced


def register_animation_tools(mcp: FastMCP) -> None:
    @mcp.tool(meta=DEFER_META)
    async def animation_player_create(
        ctx: Context,
        parent_path: str,
        name: str = "AnimationPlayer",
        session_id: str = "",
    ) -> dict:
        """Create an AnimationPlayer node under a parent with an empty default library.

        The AnimationPlayer is the root of Godot's animation system. After
        creating one, use animation_create or animation_create_simple to add
        clips, then animation_set_autoplay to play on scene load.

        Creates an empty default AnimationLibrary (key "") automatically.
        All subsequent animation_create / animation_add_*_track calls target
        this default library unless otherwise specified.

        Args:
            parent_path: Scene path of the node to parent under
                (e.g. "/Main", "/Main/HUD"). The player is added as a child.
            name: Name for the AnimationPlayer node. Default "AnimationPlayer".
            session_id: Optional Godot session to target. Empty = active session.
        """
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await animation_handlers.animation_player_create(
            runtime, parent_path=parent_path, name=name
        )

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

        After creating the clip, add tracks with animation_add_property_track
        (for tweening properties like modulate, position, scale) or
        animation_add_method_track (for calling methods / emitting signals at
        specific times). Or use animation_create_simple for a one-call approach.

        Args:
            player_path: Scene path to the AnimationPlayer node.
            name: Name for the new animation clip (e.g. "idle", "pulse", "fade_in").
            length: Duration in seconds.
            loop_mode: Playback loop behaviour:
                "none" — play once and stop (default),
                "linear" — loop from beginning,
                "pingpong" — reverse and repeat.
            overwrite: If true, replace an existing animation with the same name
                instead of erroring. The old animation is captured for undo.
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

    @mcp.tool(meta=DEFER_META)
    async def animation_delete(
        ctx: Context,
        player_path: str,
        animation_name: str,
        session_id: str = "",
    ) -> dict:
        """Delete an Animation clip from an AnimationPlayer's library.

        Removes the named animation. Undoable — Ctrl+Z in Godot restores it.

        Args:
            player_path: Scene path to the AnimationPlayer.
            animation_name: Name of the animation to delete.
            session_id: Optional Godot session to target. Empty = active session.
        """
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await animation_handlers.animation_delete(
            runtime,
            player_path=player_path,
            animation_name=animation_name,
        )

    @mcp.tool(meta=DEFER_META)
    async def animation_validate(
        ctx: Context,
        player_path: str,
        animation_name: str,
        session_id: str = "",
    ) -> dict:
        """Check all track paths in an animation resolve to actual nodes.

        Returns a validation report with valid_count, broken_count, and a list
        of broken tracks with their index, path, and issue description. Use this
        after restructuring a node tree to find animations targeting stale paths.

        Args:
            player_path: Scene path to the AnimationPlayer.
            animation_name: Name of the animation to validate.
            session_id: Optional Godot session to target. Empty = active session.
        """
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await animation_handlers.animation_validate(
            runtime,
            player_path=player_path,
            animation_name=animation_name,
        )

    @mcp.tool(meta=DEFER_META)
    async def animation_add_property_track(
        ctx: Context,
        player_path: str,
        animation_name: str,
        track_path: str,
        keyframes: Annotated[list[dict], JsonCoerced],
        interpolation: str = "linear",
        session_id: str = "",
    ) -> dict:
        """Add a property track to an animation — tween node properties over time.

        A property track animates one property on one node. Add multiple tracks
        to animate several properties simultaneously (e.g. fade + slide together).

        track_path format: "NodeName:property" — the node path relative to the
        AnimationPlayer's root (its parent by default), followed by a colon and
        the property name. Examples:
            "Panel:modulate"         — fade a Panel's colour
            ".:position"             — move the player's own parent
            "HUD/HealthBar:value"    — drive a ProgressBar value
            "Button:scale"           — scale a button for a pulse effect

        Keyframe format — each item in the list:
            time        (float, required) — time in seconds
            value       (required)        — property value at this keyframe.
                                           Colors accept "#rrggbb", named names,
                                           or {"r":…,"g":…,"b":…,"a":…}.
                                           Vector2 accepts {"x":…,"y":…} or [x,y].
            transition  (optional)        — per-keyframe easing:
                                           "linear" (default), "ease_in",
                                           "ease_out", "ease_in_out",
                                           or a raw float exponent.

        Args:
            player_path: Scene path to the AnimationPlayer.
            animation_name: Name of the animation to add the track to.
            track_path: "NodePath:property" (e.g. "Panel:modulate").
            keyframes: List of {time, value, transition?} dicts.
            interpolation: Track interpolation mode: "linear" (default),
                "nearest" (step/discrete), "cubic" (smooth).
            session_id: Optional Godot session to target. Empty = active session.
        """
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await animation_handlers.animation_add_property_track(
            runtime,
            player_path=player_path,
            animation_name=animation_name,
            track_path=track_path,
            keyframes=keyframes,
            interpolation=interpolation,
        )

    @mcp.tool(meta=DEFER_META)
    async def animation_add_method_track(
        ctx: Context,
        player_path: str,
        animation_name: str,
        target_node_path: str,
        keyframes: Annotated[list[dict], JsonCoerced],
        session_id: str = "",
    ) -> dict:
        """Add a method track to an animation — call methods or emit signals at set times.

        Method tracks fire a named method on a target node at specific timestamps.
        Useful for: playing a sound at 0.3s into an animation, emitting a signal
        at the end of a slide-in, calling queue_free after a death animation, or
        triggering game logic at precise moments in a cutscene.

        Keyframe format — each item in the list:
            time    (float, required) — time in seconds
            method  (str, required)   — method name to call on the target node
            args    (list, optional)  — positional arguments to pass (default [])

        Note: method-track keyframes do NOT accept a "transition" field — Godot
        fires method tracks as discrete events, not interpolated values. If
        you pass transition it will be silently ignored.

        Note: target_node_path is a bare NodePath ("." / "HUD" / "Enemy/Sprite2D"),
        NOT a "NodePath:property" composite like property tracks take. The method
        name goes in each keyframe's "method" field, not in the path.

        Example — play a sound at 0.2s then emit "animation_finished" at 1.0s:
            target_node_path: "."
            keyframes: [
              {"time": 0.2, "method": "play_sound", "args": ["res://sfx/click.wav"]},
              {"time": 1.0, "method": "emit_signal", "args": ["animation_finished"]}
            ]

        Args:
            player_path: Scene path to the AnimationPlayer.
            animation_name: Name of the animation to add the track to.
            target_node_path: Node path relative to AnimationPlayer's root
                (e.g. ".", "HUD", "Player/AudioStreamPlayer").
            keyframes: List of {time, method, args?} dicts.
            session_id: Optional Godot session to target. Empty = active session.
        """
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await animation_handlers.animation_add_method_track(
            runtime,
            player_path=player_path,
            animation_name=animation_name,
            target_node_path=target_node_path,
            keyframes=keyframes,
        )

    @mcp.tool(meta=DEFER_META)
    async def animation_set_autoplay(
        ctx: Context,
        player_path: str,
        animation_name: str = "",
        session_id: str = "",
    ) -> dict:
        """Set the autoplay animation on an AnimationPlayer.

        The autoplay animation starts playing automatically when the scene loads
        (on node _ready). Use this to make idle loops, ambient UI animations,
        and looping background effects start without any script code.

        Pass an empty animation_name to clear autoplay (no animation on load).

        Args:
            player_path: Scene path to the AnimationPlayer.
            animation_name: Animation to play on load. Empty string clears autoplay.
            session_id: Optional Godot session to target. Empty = active session.
        """
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await animation_handlers.animation_set_autoplay(
            runtime, player_path=player_path, animation_name=animation_name
        )

    @mcp.tool(meta=DEFER_META)
    async def animation_play(
        ctx: Context,
        player_path: str,
        animation_name: str = "",
        session_id: str = "",
    ) -> dict:
        """[Dev ergonomics — not saved with scene] Preview an animation in the editor.

        Triggers immediate playback of a named animation on an AnimationPlayer
        so you can visually inspect keyframes and timing without running the game.
        This is a dev-time tool only — the playback state is not saved with the
        scene. Use animation_set_autoplay to configure what plays at runtime.

        Args:
            player_path: Scene path to the AnimationPlayer.
            animation_name: Animation to play. Empty string delegates to
                AnimationPlayer.play("") — resumes whatever was playing, or
                falls back to Godot's default selection (typically the first
                animation if none is current). Prefer passing an explicit
                name for reproducible behaviour.
            session_id: Optional Godot session to target. Empty = active session.
        """
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await animation_handlers.animation_play(
            runtime, player_path=player_path, animation_name=animation_name
        )

    @mcp.tool(meta=DEFER_META)
    async def animation_stop(
        ctx: Context,
        player_path: str,
        session_id: str = "",
    ) -> dict:
        """[Dev ergonomics — not saved with scene] Stop animation playback in the editor.

        Halts any currently playing animation on the AnimationPlayer. Use after
        animation_play to reset the scene to its saved state.

        Args:
            player_path: Scene path to the AnimationPlayer.
            session_id: Optional Godot session to target. Empty = active session.
        """
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await animation_handlers.animation_stop(runtime, player_path=player_path)

    @mcp.tool(meta=DEFER_META)
    async def animation_list(
        ctx: Context,
        player_path: str,
        session_id: str = "",
    ) -> dict:
        """List all animations on an AnimationPlayer with length, loop mode, and track count.

        Returns a summary of every animation clip across all libraries. Use this
        to discover what animations already exist before adding tracks or setting
        autoplay.

        Args:
            player_path: Scene path to the AnimationPlayer.
            session_id: Optional Godot session to target. Empty = active session.
        """
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await animation_handlers.animation_list(runtime, player_path=player_path)

    @mcp.tool(meta=DEFER_META)
    async def animation_get(
        ctx: Context,
        player_path: str,
        animation_name: str,
        session_id: str = "",
    ) -> dict:
        """Inspect a single animation's tracks and keyframes in detail.

        Returns length, loop mode, and a full breakdown of every track: type
        (property or method), path, interpolation, and each keyframe's time,
        value, and transition. Use this to audit an animation before editing
        or to verify keyframe values after authoring.

        Args:
            player_path: Scene path to the AnimationPlayer.
            animation_name: Name of the animation to inspect.
            session_id: Optional Godot session to target. Empty = active session.
        """
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await animation_handlers.animation_get(
            runtime, player_path=player_path, animation_name=animation_name
        )

    @mcp.tool(meta=DEFER_META)
    async def animation_create_simple(
        ctx: Context,
        player_path: str,
        name: str,
        tweens: Annotated[list[dict[str, Any]], JsonCoerced],
        length: float | None = None,
        loop_mode: str = "none",
        overwrite: bool = False,
        session_id: str = "",
    ) -> dict:
        """Create a complete animation from a list of tween specs in one call.

        This is the high-level composer for animation authoring — like
        ui_build_layout for UI trees. Provide a list of property tweens and get
        back a fully-constructed Animation clip with one track per tween, two
        keyframes each (from→to), and the correct interpolation. All tracks
        commit as one undoable action.

        Tween spec keys (per item in tweens list):
            target      (str, required)   — node path relative to AnimationPlayer's
                                           root, e.g. "Panel", ".", "HUD/Label"
            property    (str, required)   — property to animate, e.g. "modulate",
                                           "position", "scale", "offset_left"
            from        (required)        — starting value (same formats as
                                           animation_add_property_track keyframes)
            to          (required)        — ending value
            duration    (float, required) — seconds for this tween
            delay       (float, optional) — start offset in seconds (default 0)
            transition  (optional)        — easing: "linear" (default), "ease_in",
                                           "ease_out", "ease_in_out", or float

        If length is omitted, it is computed as max(delay + duration) across all
        tweens — the minimum length to contain them all.

        Examples:
            # Fade in a Panel over 0.5s
            tweens=[{"target": "Panel", "property": "modulate",
                     "from": {"r":1,"g":1,"b":1,"a":0},
                     "to": {"r":1,"g":1,"b":1,"a":1}, "duration": 0.5}]

            # Slide a menu in from the left
            tweens=[{"target": "PauseMenu", "property": "position",
                     "from": {"x": -400, "y": 0}, "to": {"x": 0, "y": 0},
                     "duration": 0.3, "transition": "ease_out"}]

            # Pulse a button (use loop_mode="pingpong")
            tweens=[{"target": "Button", "property": "scale",
                     "from": {"x": 1, "y": 1}, "to": {"x": 1.1, "y": 1.1},
                     "duration": 0.4, "transition": "ease_in_out"}]

        Args:
            player_path: Scene path to the AnimationPlayer.
            name: Name for the new animation clip.
            tweens: List of tween spec dicts (see above).
            length: Total duration in seconds. Auto-computed if omitted.
            loop_mode: "none" (default), "linear", or "pingpong".
            overwrite: If true, replace an existing animation with the same name.
            session_id: Optional Godot session to target. Empty = active session.
        """
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await animation_handlers.animation_create_simple(
            runtime,
            player_path=player_path,
            name=name,
            tweens=tweens,
            length=length,
            loop_mode=loop_mode,
            overwrite=overwrite,
        )

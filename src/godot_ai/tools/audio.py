"""MCP tools for AudioStreamPlayer — sound effects, music, ambience.

Godot ships three AudioStreamPlayer flavors, all covered here:

- ``AudioStreamPlayer`` (``type="1d"``) — non-spatial (UI clicks, music, 2D
  ambient). Plays at a fixed volume regardless of listener position.
- ``AudioStreamPlayer2D`` (``type="2d"``) — 2D spatial attenuation from a
  node position in a 2D scene.
- ``AudioStreamPlayer3D`` (``type="3d"``) — 3D spatial with attenuation,
  doppler, area reverb. Requires a Camera3D/AudioListener3D in the scene
  for fully realistic preview at runtime; in the editor a basic preview
  still plays through the system speakers.

Streams are loaded from already-imported ``res://`` paths. Drop a
``.ogg`` / ``.wav`` / ``.mp3`` into the project and the editor's import
step will produce the real ``AudioStream`` subclass (``AudioStreamOggVorbis``
/ ``AudioStreamMP3`` / ``AudioStreamWAV``) before these tools ever see it.

``audio_play`` / ``audio_stop`` are runtime-only (``undoable: false``) —
they call the live node method directly and produce real audible sound
through the editor's audio output.
"""

from __future__ import annotations

from fastmcp import Context, FastMCP

from godot_ai.handlers import audio as audio_handlers
from godot_ai.runtime.direct import DirectRuntime
from godot_ai.tools import DEFER_META


def register_audio_tools(mcp: FastMCP) -> None:
    @mcp.tool(meta=DEFER_META)
    async def audio_player_create(
        ctx: Context,
        parent_path: str,
        name: str = "AudioStreamPlayer",
        type: str = "1d",
        session_id: str = "",
    ) -> dict:
        """Create an AudioStreamPlayer / 2D / 3D node for sound playback.

        Args:
            parent_path: Scene path of the parent node (e.g. "/Main", "/Main/HUD").
            name: Name for the new player node.
            type: "1d" (non-spatial), "2d" (2D spatial), or "3d" (3D spatial).
            session_id: Optional Godot session to target. Empty = active session.
        """
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await audio_handlers.audio_player_create(
            runtime, parent_path=parent_path, name=name, type=type
        )

    @mcp.tool(meta=DEFER_META)
    async def audio_player_set_stream(
        ctx: Context,
        player_path: str,
        stream_path: str,
        session_id: str = "",
    ) -> dict:
        """Assign an AudioStream resource to an AudioStreamPlayer's ``stream`` property.

        The path must be a ``res://`` URL to an already-imported audio file
        (``.ogg`` / ``.wav`` / ``.mp3``) or a ``.tres`` / ``.res`` saved
        AudioStream resource. Returns ``duration_seconds`` from the loaded
        stream (0.0 for generators without a known length).

        Args:
            player_path: Scene path to the AudioStreamPlayer / 2D / 3D node.
            stream_path: Resource path to the audio file or AudioStream resource.
            session_id: Optional Godot session to target. Empty = active session.
        """
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await audio_handlers.audio_player_set_stream(
            runtime, player_path=player_path, stream_path=stream_path
        )

    @mcp.tool(meta=DEFER_META)
    async def audio_player_set_playback(
        ctx: Context,
        player_path: str,
        volume_db: float | None = None,
        pitch_scale: float | None = None,
        autoplay: bool | None = None,
        bus: str | None = None,
        session_id: str = "",
    ) -> dict:
        """Update common playback properties in a single atomic undo action.

        Only fields you pass are applied — omitted fields are left unchanged.
        At least one of ``volume_db`` / ``pitch_scale`` / ``autoplay`` / ``bus``
        must be provided.

        Args:
            player_path: Scene path to the AudioStreamPlayer / 2D / 3D node.
            volume_db: Volume in decibels. Omit (``None``) to leave unchanged;
                0 = full volume, negative = quieter, positive = louder.
            pitch_scale: Playback-rate multiplier (1.0 = normal, 2.0 = octave up).
                Omit to leave unchanged.
            autoplay: Start on scene load. Omit to leave unchanged.
            bus: Audio bus name (e.g. "Master"). Must match a bus in the project.
                Omit to leave unchanged.
            session_id: Optional Godot session to target. Empty = active session.
        """
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await audio_handlers.audio_player_set_playback(
            runtime,
            player_path=player_path,
            volume_db=volume_db,
            pitch_scale=pitch_scale,
            autoplay=autoplay,
            bus=bus,
        )

    @mcp.tool(meta=DEFER_META)
    async def audio_play(
        ctx: Context,
        player_path: str,
        from_position: float = 0.0,
        session_id: str = "",
    ) -> dict:
        """Start real editor preview playback — produces audible sound.

        Calls the live ``AudioStreamPlayer.play()`` method directly. This is
        the same path the inspector's play button uses. 3D spatialization
        may be subtle in the editor without a running Camera3D/AudioListener3D.
        Errors if no stream is assigned — call ``audio_player_set_stream``
        first. Not undoable (runtime playback state, not saved with scene).

        Args:
            player_path: Scene path to the AudioStreamPlayer / 2D / 3D node.
            from_position: Playback position in seconds (default 0 = start).
            session_id: Optional Godot session to target. Empty = active session.
        """
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await audio_handlers.audio_play(
            runtime, player_path=player_path, from_position=from_position
        )

    @mcp.tool(meta=DEFER_META)
    async def audio_stop(
        ctx: Context,
        player_path: str,
        session_id: str = "",
    ) -> dict:
        """Stop editor preview playback. Not undoable (runtime state).

        Args:
            player_path: Scene path to the AudioStreamPlayer / 2D / 3D node.
            session_id: Optional Godot session to target. Empty = active session.
        """
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await audio_handlers.audio_stop(runtime, player_path=player_path)

    @mcp.tool(meta=DEFER_META)
    async def audio_list(
        ctx: Context,
        root: str = "res://",
        include_duration: bool = True,
        session_id: str = "",
    ) -> dict:
        """Scan the project for AudioStream resources — audio files + .tres/.res.

        Catches every AudioStream subclass: AudioStreamOggVorbis,
        AudioStreamMP3, AudioStreamWAV, AudioStreamPlaylist,
        AudioStreamRandomizer, plus bespoke ``.tres`` / ``.res`` resources.

        Args:
            root: Directory to restrict the scan to (default ``"res://"``).
            include_duration: Load each stream to report ``duration_seconds``.
                Disable for very large libraries if scans feel slow.
            session_id: Optional Godot session to target. Empty = active session.
        """
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await audio_handlers.audio_list(
            runtime, root=root, include_duration=include_duration
        )

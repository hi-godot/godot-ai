"""MCP tool for AudioStreamPlayer — sound effects, music, ambience.

Godot ships three AudioStreamPlayer flavors, all covered here:

- ``AudioStreamPlayer`` (``type="1d"``) — non-spatial (UI clicks, music, 2D
  ambient). Plays at a fixed volume regardless of listener position.
- ``AudioStreamPlayer2D`` (``type="2d"``) — 2D spatial attenuation from a
  node position in a 2D scene.
- ``AudioStreamPlayer3D`` (``type="3d"``) — 3D spatial with attenuation,
  doppler, area reverb.

Streams are loaded from already-imported ``res://`` paths.
"""

from __future__ import annotations

from fastmcp import FastMCP

from godot_ai.handlers import audio as audio_handlers
from godot_ai.tools._meta_tool import register_manage_tool

_DESCRIPTION = """\
Sound effects, music, ambience (AudioStreamPlayer / 2D / 3D).

Ops:
  • player_create(parent_path, name="AudioStreamPlayer", type="1d")
        Create an AudioStreamPlayer / 2D / 3D node. type: "1d" | "2d" | "3d".
  • player_set_stream(player_path, stream_path)
        Assign an AudioStream resource (.ogg/.wav/.mp3 or .tres). Returns
        duration_seconds.
  • player_set_playback(player_path, volume_db?, pitch_scale?, autoplay?, bus?)
        Update common playback properties atomically. Pass only fields to
        change; at least one of volume_db/pitch_scale/autoplay/bus required.
  • play(player_path, from_position=0.0)
        Start real editor preview playback. Not undoable.
  • stop(player_path)
        Stop editor preview playback. Not undoable.
  • list(root="res://", include_duration=True)
        Scan project for AudioStream resources (every subclass + .tres/.res).
"""


def register_audio_tools(mcp: FastMCP) -> None:
    register_manage_tool(
        mcp,
        tool_name="audio_manage",
        description=_DESCRIPTION,
        ops={
            "player_create": audio_handlers.audio_player_create,
            "player_set_stream": audio_handlers.audio_player_set_stream,
            "player_set_playback": audio_handlers.audio_player_set_playback,
            "play": audio_handlers.audio_play,
            "stop": audio_handlers.audio_stop,
            "list": audio_handlers.audio_list,
        },
    )

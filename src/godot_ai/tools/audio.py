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

Bus/effect edits use global editor undo. Godot may autosave them to its active
layout. bus_layout_save only exports a snapshot and does not switch that target.

Ops:
  • bus_list()
        List buses, sends, volume, mute, solo, bypass, and effect properties/enabled state.
  • bus_add(name, at_position=-1, send="Master")
        Add a uniquely named bus. -1 appends; index 0 is reserved for Master.
  • bus_remove(name)
        Remove a non-Master bus. Reroute incoming bus sends and compressor sidechains first.
  • bus_set(name, volume_db?, send?, mute?, solo?, bypass_effects?)
        Set bus properties atomically. Sends must target an earlier existing bus.
  • bus_effect_add(bus, effect_class, properties={}, at_position=-1, enabled=True)
        Insert a concrete native AudioEffect, such as AudioEffectCompressor.
  • bus_effect_set(bus, index, properties={}, enabled?)
        Edit an unscripted native effect and/or enabled state. Effect identity is preserved.
  • bus_effect_remove(bus, index)
        Remove an effect with undo of its position, properties and enabled state.
  • bus_layout_save(path="res://default_bus_layout.tres", overwrite=False)
        Export the current layout to .tres/.res. File writes are not undoable.
        Does not change the project default or the editor's active autosave layout.
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
            "bus_list": audio_handlers.audio_bus_list,
            "bus_add": audio_handlers.audio_bus_add,
            "bus_remove": audio_handlers.audio_bus_remove,
            "bus_set": audio_handlers.audio_bus_set,
            "bus_effect_add": audio_handlers.audio_bus_effect_add,
            "bus_effect_set": audio_handlers.audio_bus_effect_set,
            "bus_effect_remove": audio_handlers.audio_bus_effect_remove,
            "bus_layout_save": audio_handlers.audio_bus_layout_save,
            "player_create": audio_handlers.audio_player_create,
            "player_set_stream": audio_handlers.audio_player_set_stream,
            "player_set_playback": audio_handlers.audio_player_set_playback,
            "play": audio_handlers.audio_play,
            "stop": audio_handlers.audio_stop,
            "list": audio_handlers.audio_list,
        },
        read_resource_forms={
            ## Audio reads are stateful and per-player; no aggregate resource.
            "bus_list": None,
            "play": None,
            "stop": None,
            "list": None,
        },
    )

"""Adaptive music commands traverse the public MCP surface and its session gate."""

import asyncio

import pytest
import websockets

from tests.conftest import MockGodotPlugin, perform_v4_handshake

PATH = "res://music/adaptive.tres"
CLIPS = [
    {"name": "exploration", "stream_path": "res://music/exploration.ogg"},
    {"name": "combat", "stream_path": "res://music/combat.ogg"},
]
TRANSITION = {
    "from": "exploration",
    "to": "combat",
    "when": "next_bar",
    "start_at": "start",
    "fade": "cross",
    "fade_beats": 2.0,
}
CREATION = {"path": PATH, "clips": CLIPS, "transitions": [TRANSITION], "initial_clip": "combat"}
RESOURCE = {
    "path": PATH,
    "type": "AudioStreamInteractive",
    "initial_clip": "combat",
    "clips": [{**clip, "bpm": 120.0, "beats_per_bar": 4} for clip in CLIPS],
    "transitions": [TRANSITION],
}
FILLER = {"name": "combat_stinger", "stream_path": "res://music/combat_stinger.wav"}
TRANSITION_WITH_FILLER = {**TRANSITION, "fade_beats": 0.25, "filler_clip": FILLER["name"]}
CREATION_WITH_FILLER = {
    **CREATION,
    "clips": [*CLIPS, FILLER],
    "transitions": [TRANSITION_WITH_FILLER],
}
RESOURCE_WITH_FILLER = {
    **RESOURCE,
    "clips": [*RESOURCE["clips"], {**FILLER, "bpm": 0.0, "beats_per_bar": 0}],
    "transitions": [TRANSITION_WITH_FILLER],
}
SWITCH = {"player_path": "/Main/Music", "clip": "exploration"}


@pytest.mark.parametrize(
    ("op", "params", "payload", "readiness"),
    [
        (
            "interactive_create",
            CREATION,
            {**RESOURCE, "undoable": False, "reason": "resource saved to disk"},
            "no_scene",
        ),
        ("interactive_get", {"path": PATH}, RESOURCE, "playing"),
        pytest.param(
            "interactive_create",
            CREATION_WITH_FILLER,
            {**RESOURCE_WITH_FILLER, "undoable": False, "reason": "resource saved to disk"},
            "no_scene",
            id="create-with-filler",
        ),
        pytest.param(
            "interactive_get", {"path": PATH}, RESOURCE_WITH_FILLER, "playing", id="get-with-filler"
        ),
        (
            "interactive_switch",
            SWITCH,
            {
                "player_path": SWITCH["player_path"],
                "previous_clip": "combat",
                "requested_clip": SWITCH["clip"],
                "undoable": False,
                "reason": "runtime playback state",
            },
            "playing",
        ),
    ],
)
async def test_audio_interactive_routes_to_pinned_editor(
    mcp_stack, mcp_ws_port, op, params, payload, readiness
):
    client, active = mcp_stack
    async with websockets.connect(f"ws://127.0.0.1:{mcp_ws_port}") as ws:
        selected = MockGodotPlugin(ws=ws, session_id="music-project")
        await perform_v4_handshake(
            ws,
            session_id=selected.session_id,
            project_path="/tmp/music-project",
            readiness=readiness,
        )
        await client.call_tool("session_activate", {"session_id": active.session_id})

        async def respond():
            command = await selected.recv_command()
            assert command["command"] == f"audio_{op}"
            assert command["params"] == params
            await selected.send_response(command["request_id"], payload, readiness=readiness)

        result, _ = await asyncio.gather(
            client.call_tool(
                "audio_manage", {"op": op, "params": params, "session_id": selected.session_id}
            ),
            respond(),
        )
        assert result.data == payload
        state = await client.call_tool("session_manage", {"op": "list"})
        assert [
            session["session_id"] for session in state.data["sessions"] if session["is_active"]
        ] == [active.session_id]


async def test_audio_interactive_create_obeys_pinned_readiness(mcp_stack, mcp_ws_port):
    client, active = mcp_stack
    async with websockets.connect(f"ws://127.0.0.1:{mcp_ws_port}") as ws:
        selected = MockGodotPlugin(ws=ws, session_id="music-project")
        await perform_v4_handshake(
            ws,
            session_id=selected.session_id,
            project_path="/tmp/music-project",
            readiness="playing",
        )
        await client.call_tool("session_activate", {"session_id": active.session_id})

        async def confirm_playing():
            command = await selected.recv_command()
            assert command["command"] == "get_editor_state"
            await selected.send_response(
                command["request_id"],
                {"readiness": "playing", "is_playing": True},
                readiness="playing",
            )

        result, _ = await asyncio.gather(
            client.call_tool(
                "audio_manage",
                {"op": "interactive_create", "params": CREATION, "session_id": selected.session_id},
                raise_on_error=False,
            ),
            confirm_playing(),
        )
        assert result.is_error
        assert "EDITOR_NOT_READY" in str(result.content)
        with pytest.raises(TimeoutError):
            await selected.recv_command(timeout=0.1)

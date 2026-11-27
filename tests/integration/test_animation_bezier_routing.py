"""Bézier animation commands route through the pinned MCP session and write gate."""

import asyncio

import pytest
import websockets

from tests.conftest import MockGodotPlugin, perform_v4_handshake

CLIP = {"player_path": "/Main/AnimationPlayer", "animation_name": "slide"}
KEYFRAMES = [
    {"time": 0.0, "value": 0, "out_handle": [0.25, 10]},
    {"time": 1.0, "value": 120, "in_handle": [-0.25, -10]},
]
TRACK_PATH = "Icon:position:x"
CREATE = {**CLIP, "track_path": TRACK_PATH, "keyframes": KEYFRAMES}
CREATED = {
    **CLIP,
    "track_path": TRACK_PATH,
    "track_type": "bezier",
    "keyframe_count": 2,
    "undoable": True,
}
CURVE = {
    "player_path": CLIP["player_path"],
    "name": CLIP["animation_name"],
    "tracks": [
        {
            "type": "bezier",
            "path": TRACK_PATH,
            "keys": [
                {
                    "time": 0.0,
                    "value": [0.0, 0.0, 0.0, 0.25, 10.0],
                    "transition": 1.0,
                    "scalar_value": 0.0,
                    "in_handle": [0.0, 0.0],
                    "out_handle": [0.25, 10.0],
                },
                {
                    "time": 1.0,
                    "value": [120.0, -0.25, -10.0, 0.0, 0.0],
                    "transition": 1.0,
                    "scalar_value": 120.0,
                    "in_handle": [-0.25, -10.0],
                    "out_handle": [0.0, 0.0],
                },
            ],
        }
    ],
}


@pytest.mark.parametrize(
    ("op", "params", "readiness", "payload"),
    [
        pytest.param("add_bezier_track", CREATE, "ready", CREATED, id="create"),
        pytest.param("get", CLIP, "playing", CURVE, id="readback"),
        pytest.param("add_bezier_track", CREATE, "playing", None, id="write-refusal"),
    ],
)
async def test_bezier_animation_commands_pin_the_selected_editor(
    mcp_stack, mcp_ws_port, op, params, readiness, payload
):
    client, active = mcp_stack
    async with websockets.connect(f"ws://127.0.0.1:{mcp_ws_port}") as ws:
        selected = MockGodotPlugin(ws=ws, session_id="bezier-editor")
        await perform_v4_handshake(
            ws,
            session_id=selected.session_id,
            project_path="/tmp/bezier-project",
            readiness=readiness,
        )
        await client.call_tool("session_activate", {"session_id": active.session_id})

        async def respond():
            command = await selected.recv_command()
            if payload is None:
                assert command["command"] == "get_editor_state"
                response = {"readiness": "playing", "is_playing": True}
            else:
                assert command["command"] == f"animation_{op}"
                assert command["params"] == params
                response = payload
            await selected.send_response(command["request_id"], response, readiness=readiness)

        result, _ = await asyncio.gather(
            client.call_tool(
                "animation_manage",
                {"op": op, "params": params, "session_id": selected.session_id},
                raise_on_error=False,
            ),
            respond(),
        )
        if payload is None:
            assert result.is_error
            assert result.structured_content["error"]["code"] == "EDITOR_NOT_READY"
            with pytest.raises(TimeoutError):
                await selected.recv_command(timeout=0.1)
        else:
            assert result.data == payload
        state = await client.call_tool("session_manage", {"op": "list"})
        assert [
            session["session_id"] for session in state.data["sessions"] if session["is_active"]
        ] == [active.session_id]

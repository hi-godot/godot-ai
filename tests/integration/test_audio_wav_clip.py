"""Exercise WAV editing through the public MCP tool and an authenticated editor."""

import asyncio
import struct
import wave

import websockets

from tests.conftest import MockGodotPlugin, perform_v4_handshake


async def test_wav_clip_uses_the_selected_editors_project(mcp_stack, mcp_ws_port, tmp_path):
    client, active_plugin = mcp_stack
    project = tmp_path / "sound-project"
    project.mkdir()
    (project / "project.godot").write_text("config_version=5\n", encoding="utf-8")
    source = project / "take.wav"
    samples = [(100 * frame, -200 * frame) for frame in range(1, 9)]
    with wave.open(str(source), "wb") as writer:
        writer.setparams((2, 2, 8, 0, "NONE", "not compressed"))
        writer.writeframes(b"".join(struct.pack("<hh", *pair) for pair in samples))
    original = source.read_bytes()
    args = {
        "op": "wav_clip",
        "session_id": "wav-editor",
        "params": {
            "source_path": "res://take.wav",
            "path": "res://latch.wav",
            "start_seconds": 0.125,
            "end_seconds": 0.875,
            "fade_in_seconds": 0.375,
            "fade_out_seconds": 0.375,
        },
    }

    async with websockets.connect(f"ws://127.0.0.1:{mcp_ws_port}") as peer:
        await perform_v4_handshake(peer, session_id="wav-editor", project_path=str(project))
        await client.call_tool("session_activate", {"session_id": active_plugin.session_id})
        attempts = await asyncio.gather(
            client.call_tool("audio_manage", args, raise_on_error=False),
            client.call_tool("audio_manage", args, raise_on_error=False),
        )
        (result,) = [attempt for attempt in attempts if not attempt.is_error]
        (conflict,) = [attempt for attempt in attempts if attempt.is_error]
        assert conflict.structured_content["error"]["data"]["reason"] == "destination_exists"
        assert result.data["path"] == "res://latch.wav"
        assert result.data["source_path"] == "res://take.wav"
        assert result.data["undoable"] is False
        assert (result.data["start_frame"], result.data["end_frame"]) == (1, 7)
        assert (
            result.data["frame_count"],
            result.data["channels"],
            result.data["sample_rate"],
        ) == (6, 2, 8)
        assert (result.data["fade_in_frames"], result.data["fade_out_frames"]) == (3, 3)
        destination = project / "latch.wav"
        exported = destination.read_bytes()
        with wave.open(str(destination), "rb") as reader:
            assert (reader.getnchannels(), reader.getsampwidth(), reader.getframerate()) == (
                2,
                2,
                8,
            )
            assert list(struct.iter_unpack("<hh", reader.readframes(6))) == [
                (0, 0),
                (150, -300),
                (400, -800),
                (500, -1000),
                (300, -600),
                (0, 0),
            ]
        again = await client.call_tool("audio_manage", args, raise_on_error=False)
        assert again.structured_content["error"]["data"]["reason"] == "destination_exists"
        assert destination.read_bytes() == exported
        assert source.read_bytes() == original


async def test_wav_clip_refuses_a_playing_editor_before_writing(mcp_stack, mcp_ws_port, tmp_path):
    client, _ = mcp_stack
    async with websockets.connect(f"ws://127.0.0.1:{mcp_ws_port}") as peer:
        await perform_v4_handshake(
            peer, session_id="playing-editor", project_path=str(tmp_path), readiness="playing"
        )
        plugin = MockGodotPlugin(ws=peer, session_id="playing-editor")

        async def respond():
            command = await plugin.recv_command()
            assert command["command"] == "get_editor_state"
            await plugin.send_response(
                command["request_id"],
                {"readiness": "playing", "is_playing": True},
                readiness="playing",
            )

        request, _ = await asyncio.gather(
            client.call_tool(
                "audio_manage",
                {
                    "op": "wav_clip",
                    "session_id": plugin.session_id,
                    "params": {
                        "source_path": "res://take.wav",
                        "path": "res://latch.wav",
                        "start_seconds": 0,
                        "end_seconds": 1,
                    },
                },
                raise_on_error=False,
            ),
            respond(),
        )
        assert request.structured_content["error"]["code"] == "EDITOR_NOT_READY"
        assert not (tmp_path / "latch.wav").exists()

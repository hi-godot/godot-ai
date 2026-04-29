"""Integration tests: mock Godot plugin ↔ WebSocket server ↔ GodotClient."""

from __future__ import annotations

import asyncio
import json

import pytest
import websockets

from godot_ai import __version__ as _SERVER_VERSION
from godot_ai.godot_client.client import GodotClient, GodotCommandError
from godot_ai.handlers import editor as editor_handlers
from godot_ai.handlers import scene as scene_handlers
from godot_ai.runtime.direct import DirectRuntime

# ---------------------------------------------------------------------------
# Handshake
# ---------------------------------------------------------------------------


class TestHandshake:
    async def test_handshake_registers_session(self, harness):
        plugin = await harness.connect_plugin(session_id="sess-1")
        assert harness.registry.get("sess-1") is not None
        assert harness.registry.get_active().session_id == "sess-1"
        await plugin.close()

    async def test_handshake_populates_session_fields(self, harness):
        plugin = await harness.connect_plugin(
            session_id="sess-2",
            godot_version="4.5.0",
            project_path="/home/user/my_game",
        )
        session = harness.registry.get("sess-2")
        assert session.godot_version == "4.5.0"
        assert session.project_path == "/home/user/my_game"
        await plugin.close()

    async def test_handshake_sets_readiness_from_plugin(self, harness):
        plugin = await harness.connect_plugin(
            session_id="sess-importing",
            readiness="importing",
        )
        session = harness.registry.get("sess-importing")
        assert session.readiness == "importing"
        await plugin.close()

    async def test_disconnect_unregisters_session(self, harness):
        plugin = await harness.connect_plugin(session_id="sess-dc")
        await plugin.close()
        await asyncio.sleep(0.1)  # let server process disconnect
        assert harness.registry.get("sess-dc") is None

    async def test_handshake_captures_editor_pid(self, harness):
        plugin = await harness.connect_plugin(session_id="sess-pid", editor_pid=4242)
        session = harness.registry.get("sess-pid")
        assert session.editor_pid == 4242
        await plugin.close()

    async def test_handshake_missing_editor_pid_defaults_to_zero(self, harness):
        ## Default path — plugin omits the field (older plugin versions).
        plugin = await harness.connect_plugin(session_id="sess-no-pid")
        session = harness.registry.get("sess-no-pid")
        assert session.editor_pid == 0
        await plugin.close()

    async def test_server_sends_handshake_ack_with_version(self, harness):
        ## The dock's Server-row reads `McpConnection.server_version` to render
        ## the TRUE running server version instead of the plugin's expected
        ## version. Without the ack, the plugin falls back to "expected" and
        ## can't surface the self-update-leaves-stale-server drift case
        ## (plugin updated but foreign-adopted server still running).
        ## Bypass the `connect_plugin` helper so we can observe the ack on
        ## the wire directly — the helper drains it.
        ws = await websockets.connect(f"ws://127.0.0.1:{harness.port}")
        handshake = {
            "type": "handshake",
            "session_id": "ack-probe",
            "godot_version": "4.4.1",
            "project_path": "/tmp",
            "plugin_version": "9.9.9",
            "protocol_version": 1,
            "readiness": "ready",
            "editor_pid": 0,
        }
        await ws.send(json.dumps(handshake))

        ack_raw = await asyncio.wait_for(ws.recv(), timeout=2.0)
        ack = json.loads(ack_raw)
        assert ack["type"] == "handshake_ack"
        assert ack["server_version"] == _SERVER_VERSION, (
            "ack must quote the server's own package version (from "
            "godot_ai.__version__), not echo the handshake's plugin_version"
        )
        await ws.close()

    async def test_inbound_message_updates_last_seen(self, harness):
        plugin = await harness.connect_plugin(session_id="sess-heartbeat")
        session = harness.registry.get("sess-heartbeat")
        baseline = session.last_seen

        await asyncio.sleep(0.01)
        await plugin.send_event("readiness_changed", {"readiness": "ready"})
        await asyncio.sleep(0.05)

        assert session.last_seen > baseline
        await plugin.close()


# ---------------------------------------------------------------------------
# Command round-trip
# ---------------------------------------------------------------------------


class TestCommandRoundTrip:
    async def test_send_command_and_receive_response(self, harness):
        plugin = await harness.connect_plugin()
        client = GodotClient(harness.server, harness.registry)

        async def mock_handler():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "get_editor_state"
            await plugin.send_response(cmd["request_id"], {"version": "4.4.1"})

        handler_task = asyncio.create_task(mock_handler())
        result = await client.send("get_editor_state")
        await handler_task

        assert result == {"version": "4.4.1"}
        await plugin.close()

    async def test_command_with_params(self, harness):
        plugin = await harness.connect_plugin()
        client = GodotClient(harness.server, harness.registry)

        async def mock_handler():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "get_scene_tree"
            assert cmd["params"] == {"depth": 3}
            await plugin.send_response(cmd["request_id"], {"nodes": ["root"]})

        handler_task = asyncio.create_task(mock_handler())
        result = await client.send("get_scene_tree", params={"depth": 3})
        await handler_task

        assert result == {"nodes": ["root"]}
        await plugin.close()

    async def test_request_id_correlation(self, harness):
        """Two concurrent commands get routed to the correct callers."""
        plugin = await harness.connect_plugin()
        client = GodotClient(harness.server, harness.registry)

        async def mock_handler():
            cmd1 = await plugin.recv_command()
            cmd2 = await plugin.recv_command()
            # Reply in reverse order to prove correlation works
            await plugin.send_response(cmd2["request_id"], {"cmd": "second"})
            await plugin.send_response(cmd1["request_id"], {"cmd": "first"})

        handler_task = asyncio.create_task(mock_handler())
        r1, r2 = await asyncio.gather(
            client.send("cmd_a"),
            client.send("cmd_b"),
        )
        await handler_task

        assert r1 == {"cmd": "first"}
        assert r2 == {"cmd": "second"}
        await plugin.close()


# ---------------------------------------------------------------------------
# Error handling
# ---------------------------------------------------------------------------


class TestErrors:
    async def test_plugin_error_raises_godot_command_error(self, harness):
        plugin = await harness.connect_plugin()
        client = GodotClient(harness.server, harness.registry)

        async def mock_handler():
            cmd = await plugin.recv_command()
            await plugin.send_error(cmd["request_id"], "NODE_NOT_FOUND", "/Missing/Node")

        handler_task = asyncio.create_task(mock_handler())
        with pytest.raises(GodotCommandError) as exc_info:
            await client.send("get_node")
        await handler_task

        assert exc_info.value.code == "NODE_NOT_FOUND"
        assert "/Missing/Node" in exc_info.value.message
        await plugin.close()

    async def test_send_to_no_active_session_raises(self, harness):
        client = GodotClient(harness.server, harness.registry)
        with pytest.raises(ConnectionError, match="No active Godot session"):
            await client.send("anything")

    async def test_send_to_unknown_session_raises(self, harness):
        client = GodotClient(harness.server, harness.registry)
        with pytest.raises(ConnectionError, match="not found"):
            await client.send("anything", session_id="nonexistent")

    async def test_timeout_raises(self, harness):
        plugin = await harness.connect_plugin()
        client = GodotClient(harness.server, harness.registry)

        # Don't respond — let it time out
        with pytest.raises(TimeoutError):
            await client.send("slow_command", timeout=0.2)

        await plugin.close()


# ---------------------------------------------------------------------------
# Events
# ---------------------------------------------------------------------------


class TestEvents:
    async def test_scene_changed_event(self, harness):
        plugin = await harness.connect_plugin(session_id="evt-1")
        await plugin.send_event("scene_changed", {"current_scene": "res://levels/main.tscn"})
        await asyncio.sleep(0.05)

        session = harness.registry.get("evt-1")
        assert session.current_scene == "res://levels/main.tscn"
        await plugin.close()

    async def test_play_state_changed_event(self, harness):
        plugin = await harness.connect_plugin(session_id="evt-2")
        await plugin.send_event("play_state_changed", {"play_state": "playing"})
        await asyncio.sleep(0.05)

        session = harness.registry.get("evt-2")
        assert session.play_state == "playing"
        await plugin.close()

    async def test_readiness_changed_event(self, harness):
        plugin = await harness.connect_plugin(session_id="evt-3")
        session = harness.registry.get("evt-3")
        assert session.readiness == "ready"

        await plugin.send_event("readiness_changed", {"readiness": "importing"})
        await asyncio.sleep(0.05)
        assert session.readiness == "importing"

        await plugin.send_event("readiness_changed", {"readiness": "ready"})
        await asyncio.sleep(0.05)
        assert session.readiness == "ready"
        await plugin.close()


# ---------------------------------------------------------------------------
# Multiple sessions
# ---------------------------------------------------------------------------


class TestMultipleSessions:
    async def test_two_sessions_independent(self, harness):
        plugin_a = await harness.connect_plugin(session_id="multi-a")
        plugin_b = await harness.connect_plugin(session_id="multi-b")
        client = GodotClient(harness.server, harness.registry)

        assert len(harness.registry) == 2

        # Send to session B explicitly
        async def mock_b():
            cmd = await plugin_b.recv_command()
            await plugin_b.send_response(cmd["request_id"], {"from": "b"})

        handler_task = asyncio.create_task(mock_b())
        result = await client.send("ping", session_id="multi-b")
        await handler_task

        assert result == {"from": "b"}
        await plugin_a.close()
        await plugin_b.close()

    async def test_disconnect_one_keeps_other(self, harness):
        plugin_a = await harness.connect_plugin(session_id="keep-a")
        plugin_b = await harness.connect_plugin(session_id="keep-b")

        await plugin_a.close()
        await asyncio.sleep(0.1)

        assert harness.registry.get("keep-a") is None
        assert harness.registry.get("keep-b") is not None
        await plugin_b.close()


# --- Issue #262: editor_state self-heals a stale "playing" cache ---


class TestEditorStateSelfHeal:
    async def test_editor_state_then_scene_save_no_stale_playing_block(self, harness):
        plugin = await harness.connect_plugin(session_id="sh-1", readiness="playing")
        client = GodotClient(harness.server, harness.registry)
        runtime = DirectRuntime(registry=harness.registry, client=client)
        session = harness.registry.get("sh-1")
        assert session.readiness == "playing"

        async def mock_plugin_loop():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "get_editor_state"
            await plugin.send_response(
                cmd["request_id"],
                {
                    "godot_version": "4.4.1",
                    "project_name": "p",
                    "current_scene": "res://main.tscn",
                    "is_playing": False,
                    "readiness": "ready",
                },
            )
            # Without the self-heal the runtime never reaches save_scene —
            # require_writable raises EDITOR_NOT_READY against the stale
            # "playing" cache before send_command runs. Receiving the
            # save_scene command is the test.
            cmd = await plugin.recv_command()
            assert cmd["command"] == "save_scene"
            await plugin.send_response(
                cmd["request_id"],
                {"path": "res://main.tscn", "undoable": False},
            )

        task = asyncio.create_task(mock_plugin_loop())
        try:
            state = await editor_handlers.editor_state(runtime)
            assert state["readiness"] == "ready"
            assert session.readiness == "ready"
            saved = await scene_handlers.scene_save(runtime)
            assert saved["path"] == "res://main.tscn"
        finally:
            await asyncio.wait_for(task, timeout=2.0)
            await plugin.close()

    async def test_editor_state_promotes_cache_to_playing_when_truly_playing(self, harness):
        """Self-heal is bidirectional — a stale 'ready' cache also reconciles
        so the next write correctly blocks instead of slipping through."""
        plugin = await harness.connect_plugin(session_id="sh-2", readiness="ready")
        client = GodotClient(harness.server, harness.registry)
        runtime = DirectRuntime(registry=harness.registry, client=client)
        session = harness.registry.get("sh-2")
        assert session.readiness == "ready"

        async def mock_plugin():
            cmd = await plugin.recv_command()
            await plugin.send_response(
                cmd["request_id"],
                {
                    "godot_version": "4.4.1",
                    "project_name": "p",
                    "current_scene": "res://main.tscn",
                    "is_playing": True,
                    "readiness": "playing",
                },
            )

        task = asyncio.create_task(mock_plugin())
        try:
            await editor_handlers.editor_state(runtime)
            assert session.readiness == "playing"
            with pytest.raises(GodotCommandError) as exc_info:
                await scene_handlers.scene_save(runtime)
            assert exc_info.value.code == "EDITOR_NOT_READY"
        finally:
            await asyncio.wait_for(task, timeout=2.0)
            await plugin.close()

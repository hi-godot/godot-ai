"""Integration tests: mock Godot plugin ↔ WebSocket server ↔ GodotClient."""

from __future__ import annotations

import asyncio

import pytest

from godot_ai.godot_client.client import GodotClient, GodotCommandError

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

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

    async def test_concurrent_commands_route_to_explicit_sessions(self, harness):
        """A read and a write in flight at the same time stay on their target sessions."""
        plugin_a = await harness.connect_plugin(session_id="route-a")
        plugin_b = await harness.connect_plugin(session_id="route-b")
        client = GodotClient(harness.server, harness.registry)

        async def respond_a():
            cmd = await plugin_a.recv_command()
            assert cmd["command"] == "get_open_scenes"
            await plugin_a.send_response(
                cmd["request_id"],
                {"scenes": ["res://from_a.tscn"], "current": "res://from_a.tscn"},
            )

        async def respond_b():
            cmd = await plugin_b.recv_command()
            assert cmd["command"] == "create_node"
            assert cmd["params"] == {"type": "Node3D", "name": "FromB"}
            await plugin_b.send_response(
                cmd["request_id"],
                {"path": "/Main/FromB", "type": "Node3D", "undoable": True},
            )

        handler_tasks = [asyncio.create_task(respond_a()), asyncio.create_task(respond_b())]
        read_result, write_result = await asyncio.gather(
            client.send("get_open_scenes", session_id="route-a"),
            client.send(
                "create_node",
                params={"type": "Node3D", "name": "FromB"},
                session_id="route-b",
            ),
        )
        await asyncio.gather(*handler_tasks)

        assert read_result["current"] == "res://from_a.tscn"
        assert write_result["path"] == "/Main/FromB"
        await plugin_a.close()
        await plugin_b.close()


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

    async def test_plugin_error_preserves_structured_data(self, harness):
        plugin = await harness.connect_plugin()
        client = GodotClient(harness.server, harness.registry)
        candidates = ["/Main/VisualA", "/Main/VisualB"]

        async def mock_handler():
            cmd = await plugin.recv_command()
            await plugin.send_error(
                cmd["request_id"],
                "INVALID_PARAMS",
                "Multiple visual candidates near /Main/Body/Collision",
                data={"candidates": candidates},
            )

        handler_task = asyncio.create_task(mock_handler())
        with pytest.raises(GodotCommandError) as exc_info:
            await client.send("physics_shape_autofit")
        await handler_task

        assert exc_info.value.code == "INVALID_PARAMS"
        assert exc_info.value.data["candidates"] == candidates
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

    async def test_deferred_timeout_error_reaches_client(self, harness):
        plugin = await harness.connect_plugin()
        client = GodotClient(harness.server, harness.registry)

        async def mock_handler():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "deferred_never_replies"
            await asyncio.sleep(0.05)
            await plugin.send_error(
                cmd["request_id"],
                "DEFERRED_TIMEOUT",
                "Deferred response for 'deferred_never_replies' timed out after 50ms",
                data={
                    "command": "deferred_never_replies",
                    "timeout_ms": 50,
                },
            )

        handler_task = asyncio.create_task(mock_handler())
        with pytest.raises(GodotCommandError) as exc_info:
            await client.send("deferred_never_replies", timeout=1.0)
        await handler_task

        assert exc_info.value.code == "DEFERRED_TIMEOUT"
        assert exc_info.value.data["command"] == "deferred_never_replies"
        await plugin.close()

    async def test_timeout_removes_pending_request_and_ignores_late_reply(self, harness):
        plugin = await harness.connect_plugin()
        client = GodotClient(harness.server, harness.registry)

        with pytest.raises(TimeoutError):
            await client.send("slow_command", timeout=0.05)

        assert harness.server._pending == {}

        cmd = await plugin.recv_command()
        await plugin.send_response(cmd["request_id"], {"arrived": "late"})
        await asyncio.sleep(0.05)

        assert harness.server._pending == {}
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
# Event payload validation (audit-v2 #7 / issue #351)
# ---------------------------------------------------------------------------


class TestEventValidation:
    ## Pre-fix, _handle_event blindly assigned event_data.get(...) to typed
    ## Session fields, so a malformed plugin event (or hijacked WS) shipped
    ## non-string values verbatim to MCP clients via Session.to_dict(). Now
    ## the payloads are Pydantic-validated and dropped on ValidationError.

    async def test_scene_changed_with_non_string_payload_is_dropped(self, harness, caplog):
        plugin = await harness.connect_plugin(session_id="evt-bad-scene")
        session = harness.registry.get("evt-bad-scene")
        baseline_scene = session.current_scene

        with caplog.at_level("WARNING", logger="godot_ai.transport.websocket"):
            await plugin.send_event("scene_changed", {"current_scene": 12345})
            await asyncio.sleep(0.05)

        assert session.current_scene == baseline_scene, (
            "current_scene must not be overwritten with a non-string"
        )
        assert any("Dropping malformed scene_changed" in m for m in caplog.messages), (
            "expected warning log naming the dropped event"
        )
        await plugin.close()

    async def test_play_state_changed_with_non_string_payload_is_dropped(self, harness, caplog):
        plugin = await harness.connect_plugin(session_id="evt-bad-play")
        session = harness.registry.get("evt-bad-play")
        baseline_play = session.play_state

        with caplog.at_level("WARNING", logger="godot_ai.transport.websocket"):
            await plugin.send_event("play_state_changed", {"play_state": ["running"]})
            await asyncio.sleep(0.05)

        assert session.play_state == baseline_play
        assert any("Dropping malformed play_state_changed" in m for m in caplog.messages)
        await plugin.close()

    async def test_readiness_changed_with_non_string_payload_is_dropped(self, harness, caplog):
        plugin = await harness.connect_plugin(session_id="evt-bad-ready")
        session = harness.registry.get("evt-bad-ready")
        baseline_ready = session.readiness

        with caplog.at_level("WARNING", logger="godot_ai.transport.websocket"):
            await plugin.send_event("readiness_changed", {"readiness": {"nested": "obj"}})
            await asyncio.sleep(0.05)

        assert session.readiness == baseline_ready
        assert any("Dropping malformed readiness_changed" in m for m in caplog.messages)
        await plugin.close()

    async def test_unknown_event_type_is_silently_ignored(self, harness):
        ## Forward-compat: a future plugin might emit an event type the
        ## current server doesn't know yet. The handler should ignore it
        ## without raising or mutating session state.
        plugin = await harness.connect_plugin(session_id="evt-unknown")
        session = harness.registry.get("evt-unknown")
        before = (session.current_scene, session.play_state, session.readiness)

        await plugin.send_event("future_event", {"foo": "bar"})
        await asyncio.sleep(0.05)

        assert (session.current_scene, session.play_state, session.readiness) == before
        await plugin.close()

    async def test_valid_event_after_malformed_one_still_applies(self, harness, caplog):
        ## Regression guard: dropping a malformed payload must not poison
        ## the connection — the next valid event for the same session
        ## should still update the typed field.
        plugin = await harness.connect_plugin(session_id="evt-recover")
        session = harness.registry.get("evt-recover")

        with caplog.at_level("WARNING", logger="godot_ai.transport.websocket"):
            await plugin.send_event("readiness_changed", {"readiness": 42})
            await asyncio.sleep(0.05)

        await plugin.send_event("readiness_changed", {"readiness": "importing"})
        await asyncio.sleep(0.05)
        assert session.readiness == "importing"
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

    async def test_active_disconnect_with_one_survivor_auto_promotes(self, harness):
        ## audit-v2 #8: solo-user case. Two editors connect; the user runs
        ## session_activate on B; A's editor crashes. Pre-fix, every
        ## subsequent tool call would fail with "no active session" until
        ## the agent guessed to call session_activate. Now B is auto-
        ## promoted on A's disconnect.
        plugin_a = await harness.connect_plugin(session_id="failover-a")
        plugin_b = await harness.connect_plugin(session_id="failover-b")
        ## A connected first → A is active. Make A explicitly active so
        ## the test's preconditions don't depend on registration order
        ## (registration-order semantics are tested elsewhere).
        harness.registry.set_active("failover-a")
        assert harness.registry.active_session_id == "failover-a"

        await plugin_a.close()
        for _ in range(20):
            if harness.registry.get("failover-a") is None:
                break
            await asyncio.sleep(0.05)
        assert harness.registry.get("failover-a") is None

        ## B is the only survivor — must be auto-promoted.
        assert harness.registry.active_session_id == "failover-b"
        assert harness.registry.get_active().session_id == "failover-b"
        await plugin_b.close()

    async def test_disconnect_reconnect_handshake_then_first_command(self, harness):
        plugin_old = await harness.connect_plugin(session_id="reconnect-old")
        assert harness.registry.active_session_id == "reconnect-old"

        await plugin_old.close()
        for _ in range(20):
            if harness.registry.get("reconnect-old") is None:
                break
            await asyncio.sleep(0.05)
        assert harness.registry.get("reconnect-old") is None
        assert harness.registry.active_session_id is None

        plugin_new = await harness.connect_plugin(session_id="reconnect-new")
        assert harness.registry.active_session_id == "reconnect-new"
        client = GodotClient(harness.server, harness.registry)

        async def respond_new():
            cmd = await plugin_new.recv_command()
            assert cmd["command"] == "get_editor_state"
            await plugin_new.send_response(
                cmd["request_id"],
                {"project_name": "AfterReconnect", "godot_version": "4.4.1"},
            )

        handler_task = asyncio.create_task(respond_new())
        result = await client.send("get_editor_state")
        await handler_task

        assert result["project_name"] == "AfterReconnect"
        await plugin_new.close()


# ---------------------------------------------------------------------------
# DNS-rebinding guard — audit-v2 #1 (#345)
# ---------------------------------------------------------------------------


class TestDnsRebindingGuard:
    """The WS server's loopback Host/Origin guard runs before the upgrade.

    Browsers attacking via DNS rebinding send a non-loopback Host (the
    rebound name they typed in the URL bar) and a non-loopback Origin
    (the attacker's page). Native plugin clients send a loopback Host
    and no Origin, so they pass through.
    """

    async def test_loopback_host_no_origin_succeeds(self, harness):
        # The default native shape: ``websockets`` client sends
        # ``Host: 127.0.0.1:<port>`` and no ``Origin``.
        plugin = await harness.connect_plugin(session_id="loopback-default")
        assert harness.registry.get("loopback-default") is not None
        await plugin.close()

    async def test_non_loopback_host_rejected_at_upgrade(self, harness):
        ## A DNS-rebinding browser request lands on 127.0.0.1 but carries
        ## ``Host: attacker.example.com:<port>``. The guard fires before
        ## the upgrade — InvalidStatus surfaces the synthesized 403.
        with pytest.raises(websockets.exceptions.InvalidStatus) as exc_info:
            await websockets.connect(
                f"ws://127.0.0.1:{harness.port}",
                additional_headers={"Host": "attacker.example.com"},
            )
        assert exc_info.value.response.status_code == 403

    async def test_browser_origin_rejected_at_upgrade(self, harness):
        ## A loopback Host is not enough — a browser-driven Origin gives
        ## the rebinding away even when the Host header looks fine.
        with pytest.raises(websockets.exceptions.InvalidStatus) as exc_info:
            await websockets.connect(
                f"ws://127.0.0.1:{harness.port}",
                origin="https://attacker.example.com",
            )
        assert exc_info.value.response.status_code == 403

    async def test_loopback_origin_accepted(self, harness):
        ## A localhost-shaped explicit Origin is permitted (use case:
        ## an MCP-aware tool fronting our server from a loopback browser
        ## context, e.g. a local docs viewer).
        ws = await websockets.connect(
            f"ws://127.0.0.1:{harness.port}",
            origin="http://localhost:9500",
        )
        handshake = {
            "type": "handshake",
            "session_id": "origin-loopback",
            "godot_version": "4.4.1",
            "project_path": "/tmp",
            "plugin_version": "0.0.1",
            "protocol_version": 1,
            "readiness": "ready",
            "editor_pid": 0,
        }
        await ws.send(json.dumps(handshake))
        await asyncio.sleep(0.05)
        ## Drain the ack so it doesn't pollute later asserts.
        try:
            await asyncio.wait_for(ws.recv(), timeout=0.5)
        except asyncio.TimeoutError:
            pass
        assert harness.registry.get("origin-loopback") is not None
        await ws.close()

    async def test_origin_null_rejected_at_upgrade(self, harness):
        ## A sandboxed iframe or downloaded file:// page emits
        ## ``Origin: null`` — same effective bypass as a foreign Origin.
        with pytest.raises(websockets.exceptions.InvalidStatus) as exc_info:
            await websockets.connect(
                f"ws://127.0.0.1:{harness.port}",
                additional_headers={"Origin": "null"},
            )
        assert exc_info.value.response.status_code == 403

    async def test_browser_cross_origin_subresource_rejected(self, harness):
        ## Browsers stamp every HTTP request with Sec-Fetch-Site. A
        ## cross-origin no-cors load (the ``<img>`` liveness-oracle
        ## shape) arrives with a loopback Host and *no* Origin but the
        ## fetch metadata gives the rebinding away.
        with pytest.raises(websockets.exceptions.InvalidStatus) as exc_info:
            await websockets.connect(
                f"ws://127.0.0.1:{harness.port}",
                additional_headers={"Sec-Fetch-Site": "cross-site"},
            )
        assert exc_info.value.response.status_code == 403

    async def test_bracketed_ipv6_loopback_origin_accepted(self, harness):
        ## Symmetry with the unit-level ``http://[::1]`` accept — pin
        ## the WebSocket guard end-to-end against the bracketed-IPv6
        ## spelling so the WS path doesn't drift from the helper.
        ws = await websockets.connect(
            f"ws://127.0.0.1:{harness.port}",
            origin="http://[::1]:9500",
        )
        handshake = {
            "type": "handshake",
            "session_id": "ipv6-loopback",
            "godot_version": "4.4.1",
            "project_path": "/tmp",
            "plugin_version": "0.0.1",
            "protocol_version": 1,
            "readiness": "ready",
            "editor_pid": 0,
        }
        await ws.send(json.dumps(handshake))
        await asyncio.sleep(0.05)
        try:
            await asyncio.wait_for(ws.recv(), timeout=0.5)
        except asyncio.TimeoutError:
            pass
        assert harness.registry.get("ipv6-loopback") is not None
        await ws.close()

    async def test_rejected_request_does_not_register_session(self, harness):
        before = len(harness.registry)
        with pytest.raises(websockets.exceptions.InvalidStatus):
            await websockets.connect(
                f"ws://127.0.0.1:{harness.port}",
                origin="https://attacker.example.com",
            )
        await asyncio.sleep(0.05)
        ## No Session must have been added — the guard refuses before
        ## ``_handle_connection`` runs, so neither the registry nor the
        ## ``_connections`` map sees the rebound peer.
        assert len(harness.registry) == before


# ---------------------------------------------------------------------------
# Duplicate-ID handshake hardening (#343 finding #2)
# ---------------------------------------------------------------------------


class TestDuplicateHandshake:
    async def test_duplicate_session_id_handshake_is_rejected(self, harness):
        ## Without rejection, a second handshake with the same session_id
        ## silently overwrites both `_connections[session_id]` and the
        ## registry entry — routing every subsequent command to the
        ## attacker. session_id is `<slug>@<4hex>` so 16 bits of suffix is
        ## locally guessable. Reject keeps the first peer authoritative.
        first = await harness.connect_plugin(session_id="dup-target")
        original_session = harness.registry.get("dup-target")
        assert original_session is not None
        original_pid = original_session.editor_pid

        ## Hand-roll the second handshake so we observe the close on the
        ## wire — `connect_plugin()` would assert on the missing ack.
        ws2 = await websockets.connect(f"ws://127.0.0.1:{harness.port}")
        await ws2.send(
            json.dumps(
                {
                    "type": "handshake",
                    "session_id": "dup-target",
                    "godot_version": "4.4.1",
                    "project_path": "/tmp/attacker",
                    "plugin_version": "0.0.1",
                    "protocol_version": 1,
                    "readiness": "ready",
                    "editor_pid": 9999,
                }
            )
        )

        ## Server should close us before sending an ack. Drain until the WS
        ## reports closed; recv() will raise ConnectionClosed.
        with pytest.raises(websockets.ConnectionClosed):
            await asyncio.wait_for(ws2.recv(), timeout=2.0)

        ## Original session must still be live and unaffected.
        live = harness.registry.get("dup-target")
        assert live is original_session, "registry entry was overwritten by duplicate"
        assert live.editor_pid == original_pid
        assert live.project_path != "/tmp/attacker"

        ## Round-trip a command through the original to prove its WS is
        ## still wired to the routing map (regression: silent overwrite
        ## also hijacks `_connections[session_id]`).
        client = GodotClient(harness.server, harness.registry)

        async def mock_handler():
            cmd = await first.recv_command()
            await first.send_response(cmd["request_id"], {"alive": True})

        handler = asyncio.create_task(mock_handler())
        result = await client.send("ping", session_id="dup-target")
        await handler
        assert result == {"alive": True}

        await first.close()

    async def test_reconnect_after_clean_disconnect_succeeds(self, harness):
        ## The reject must not break the legitimate plugin reconnect path
        ## (e.g. after `editor_reload_plugin`): close → unregister →
        ## fresh connect with the same session_id should succeed because
        ## the registry entry has already been removed.
        first = await harness.connect_plugin(session_id="reconnect-1")
        await first.close()
        await asyncio.sleep(0.1)  # let server process disconnect
        assert harness.registry.get("reconnect-1") is None

        second = await harness.connect_plugin(session_id="reconnect-1")
        assert harness.registry.get("reconnect-1") is not None
        await second.close()


# ---------------------------------------------------------------------------
# send_command pending-Future leak (#343 finding #5)
# ---------------------------------------------------------------------------


class TestPendingFutureCleanup:
    async def test_timeout_pops_pending_entry(self, harness):
        ## TimeoutError path always cleared the pending dict; this test
        ## pins that behavior so a future refactor doesn't regress it.
        plugin = await harness.connect_plugin(session_id="leak-timeout")
        client = GodotClient(harness.server, harness.registry)

        with pytest.raises(TimeoutError):
            await client.send("never_responded", timeout=0.1)

        assert harness.server._pending == {}, "TimeoutError should not leave entries in _pending"
        await plugin.close()

    async def test_send_failure_pops_pending_entry(self, harness):
        ## If `ws.send` raises (e.g. ConnectionClosed mid-send), the
        ## pending Future was previously leaked into `_pending` forever.
        ## Force the failure by replacing the connection's send with one
        ## that raises after the pending entry has been registered.
        plugin = await harness.connect_plugin(session_id="leak-send")

        ws = harness.server._connections["leak-send"]
        boom = ConnectionError("simulated mid-send transport error")

        async def raising_send(_payload: str) -> None:
            raise boom

        ws.send = raising_send  # type: ignore[assignment]

        with pytest.raises(ConnectionError):
            await harness.server.send_command(
                session_id="leak-send",
                command="will_fail",
                timeout=1.0,
            )

        assert harness.server._pending == {}, "send-time exception must not leak _pending entries"
        await plugin.close()


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

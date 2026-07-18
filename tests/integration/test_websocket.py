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
from tests.conftest import drain_handshake_ack

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

    async def test_error_watermark_first_observation_baselines_silently(self, harness):
        plugin = await harness.connect_plugin(session_id="err-baseline")
        client = GodotClient(harness.server, harness.registry)

        async def mock_handler():
            cmd = await plugin.recv_command()
            await plugin.send_response(
                cmd["request_id"],
                {"ok": 1},
                error_watermark={
                    "run_seq": 1,
                    "editor_ring": 0,
                    "debugger_promoted": 1,
                    "game_error_warn": 0,
                },
            )

        handler_task = asyncio.create_task(mock_handler())
        first = await client.send("get_editor_state")
        await handler_task

        assert "new_errors_since_last_call" not in first
        session = harness.registry.get("err-baseline")
        assert session.error_watermark["debugger_promoted"] == 1
        await plugin.close()

    async def test_error_watermark_advance_injects_hint_once(self, harness):
        plugin = await harness.connect_plugin(session_id="err-watermark")
        client = GodotClient(harness.server, harness.registry)

        async def mock_handler():
            cmd = await plugin.recv_command()
            await plugin.send_response(
                cmd["request_id"],
                {"ok": 1},
                error_watermark={
                    "run_seq": 1,
                    "editor_ring": 0,
                    "debugger_promoted": 1,
                    "game_error_warn": 0,
                },
            )
            cmd = await plugin.recv_command()
            await plugin.send_response(
                cmd["request_id"],
                {"ok": 2},
                error_watermark={
                    "run_seq": 1,
                    "editor_ring": 0,
                    "debugger_promoted": 2,
                    "game_error_warn": 0,
                },
            )
            cmd = await plugin.recv_command()
            await plugin.send_response(
                cmd["request_id"],
                {"ok": 3},
                error_watermark={
                    "run_seq": 1,
                    "editor_ring": 0,
                    "debugger_promoted": 2,
                    "game_error_warn": 0,
                },
            )

        handler_task = asyncio.create_task(mock_handler())
        first = await client.send("get_editor_state")
        second = await client.send("get_editor_state")
        third = await client.send("get_editor_state")
        await handler_task

        assert "new_errors_since_last_call" not in first
        assert second["new_errors_since_last_call"] == 1
        assert "logs_read(source='editor'" in second["new_errors_hint"]
        assert "new_errors_since_last_call" not in third
        assert harness.registry.get("err-watermark").error_watermark["debugger_promoted"] == 2
        await plugin.close()

    async def test_error_watermark_overlapping_game_and_debugger_count_once(self, harness):
        ## A push_error in a helper-live run lands in the game log buffer AND
        ## as a Debugger Errors-tab row. Both components advance by 1; the
        ## agent must be told about 1 new error, not 2 (#642 live smoke).
        plugin = await harness.connect_plugin(session_id="err-overlap")
        client = GodotClient(harness.server, harness.registry)

        async def mock_handler():
            cmd = await plugin.recv_command()
            await plugin.send_response(
                cmd["request_id"],
                {"ok": 1},
                error_watermark={
                    "run_seq": 1,
                    "editor_ring": 0,
                    "debugger_promoted": 0,
                    "game_error_warn": 0,
                },
            )
            cmd = await plugin.recv_command()
            await plugin.send_response(
                cmd["request_id"],
                {"ok": 2},
                error_watermark={
                    "run_seq": 1,
                    "editor_ring": 0,
                    "debugger_promoted": 1,
                    "game_error_warn": 1,
                },
            )
            cmd = await plugin.recv_command()
            await plugin.send_response(
                cmd["request_id"],
                {"ok": 3},
                error_watermark={
                    "run_seq": 1,
                    "editor_ring": 2,
                    "debugger_promoted": 2,
                    "game_error_warn": 1,
                },
            )

        handler_task = asyncio.create_task(mock_handler())
        first = await client.send("get_editor_state")
        second = await client.send("get_editor_state")
        third = await client.send("get_editor_state")
        await handler_task

        assert "new_errors_since_last_call" not in first
        ## One physical error seen through two overlapping views.
        assert second["new_errors_since_last_call"] == 1
        ## Editor-process errors are an independent stream: 2 editor + 1
        ## debugger-only advance = 3.
        assert third["new_errors_since_last_call"] == 3
        await plugin.close()

    async def test_error_watermark_first_game_component_on_new_run_counts_full(self, harness):
        ## A watermark that never carried game_error_warn (older plugin, or a
        ## session that never ran a game) reports it for the first time on an
        ## ADVANCED run: the per-run component has no baseline to diff
        ## against, so it counts in full rather than baselining silently.
        plugin = await harness.connect_plugin(session_id="err-first-game")
        client = GodotClient(harness.server, harness.registry)

        async def mock_handler():
            cmd = await plugin.recv_command()
            await plugin.send_response(
                cmd["request_id"],
                {"ok": 1},
                error_watermark={"run_seq": 1, "editor_ring": 0},
            )
            cmd = await plugin.recv_command()
            await plugin.send_response(
                cmd["request_id"],
                {"ok": 2},
                error_watermark={"run_seq": 2, "editor_ring": 0, "game_error_warn": 2},
            )

        handler_task = asyncio.create_task(mock_handler())
        first = await client.send("get_editor_state")
        second = await client.send("get_editor_state")
        await handler_task

        assert "new_errors_since_last_call" not in first
        assert second["new_errors_since_last_call"] == 2
        await plugin.close()

    async def test_error_watermark_component_reset_counts_current_value(self, harness):
        plugin = await harness.connect_plugin(session_id="err-reset")
        client = GodotClient(harness.server, harness.registry)

        async def mock_handler():
            cmd = await plugin.recv_command()
            await plugin.send_response(
                cmd["request_id"],
                {"ok": 1},
                error_watermark={"run_seq": 1, "game_error_warn": 3},
            )
            cmd = await plugin.recv_command()
            await plugin.send_response(
                cmd["request_id"],
                {"ok": 2},
                error_watermark={"run_seq": 1, "game_error_warn": 3},
            )
            cmd = await plugin.recv_command()
            await plugin.send_response(
                cmd["request_id"],
                {"ok": 3},
                error_watermark={"run_seq": 1, "game_error_warn": 1},
            )

        handler_task = asyncio.create_task(mock_handler())
        first = await client.send("get_editor_state")
        second = await client.send("get_editor_state")
        third = await client.send("get_editor_state")
        await handler_task

        assert "new_errors_since_last_call" not in first
        assert "new_errors_since_last_call" not in second
        assert third["new_errors_since_last_call"] == 1
        await plugin.close()

    async def test_error_watermark_missing_key_retains_prior_baseline(self, harness):
        plugin = await harness.connect_plugin(session_id="err-missing-key")
        client = GodotClient(harness.server, harness.registry)

        async def mock_handler():
            cmd = await plugin.recv_command()
            await plugin.send_response(
                cmd["request_id"],
                {"ok": 1},
                error_watermark={"run_seq": 1, "debugger_promoted": 4, "game_error_warn": 1},
            )
            cmd = await plugin.recv_command()
            await plugin.send_response(
                cmd["request_id"],
                {"ok": 2},
                error_watermark={"run_seq": 1, "game_error_warn": 2},
            )
            cmd = await plugin.recv_command()
            await plugin.send_response(
                cmd["request_id"],
                {"ok": 3},
                error_watermark={"run_seq": 1, "debugger_promoted": 5},
            )

        handler_task = asyncio.create_task(mock_handler())
        first = await client.send("get_editor_state")
        second = await client.send("get_editor_state")
        third = await client.send("get_editor_state")
        await handler_task

        assert "new_errors_since_last_call" not in first
        assert second["new_errors_since_last_call"] == 1
        assert third["new_errors_since_last_call"] == 1
        assert harness.registry.get("err-missing-key").error_watermark == {
            "run_seq": 1,
            "debugger_promoted": 5,
            "game_error_warn": 2,
        }
        await plugin.close()

    async def test_error_watermark_run_boundary_counts_reaccumulated_game_errors(self, harness):
        plugin = await harness.connect_plugin(session_id="err-run-seq")
        client = GodotClient(harness.server, harness.registry)

        async def mock_handler():
            cmd = await plugin.recv_command()
            await plugin.send_response(
                cmd["request_id"],
                {"ok": 1},
                error_watermark={"run_seq": 1, "game_error_warn": 3},
            )
            cmd = await plugin.recv_command()
            await plugin.send_response(
                cmd["request_id"],
                {"ok": 2},
                error_watermark={"run_seq": 2, "game_error_warn": 3},
            )

        handler_task = asyncio.create_task(mock_handler())
        first = await client.send("get_editor_state")
        second = await client.send("get_editor_state")
        await handler_task

        assert "new_errors_since_last_call" not in first
        assert second["new_errors_since_last_call"] == 3
        await plugin.close()

    async def test_error_watermark_error_response_accumulates_until_success(self, harness):
        plugin = await harness.connect_plugin(session_id="err-accumulate")
        client = GodotClient(harness.server, harness.registry)

        async def mock_handler():
            cmd = await plugin.recv_command()
            await plugin.send_response(
                cmd["request_id"],
                {"ok": 1},
                error_watermark={"run_seq": 1, "debugger_promoted": 0},
            )
            cmd = await plugin.recv_command()
            await plugin.send_error(
                cmd["request_id"],
                "BROKEN",
                "broken",
                error_watermark={"run_seq": 1, "debugger_promoted": 2},
            )
            cmd = await plugin.recv_command()
            await plugin.send_response(
                cmd["request_id"],
                {"ok": 3},
                error_watermark={"run_seq": 1, "debugger_promoted": 2},
            )
            cmd = await plugin.recv_command()
            await plugin.send_response(
                cmd["request_id"],
                {"ok": 4},
                error_watermark={"run_seq": 1, "debugger_promoted": 2},
            )

        handler_task = asyncio.create_task(mock_handler())
        first = await client.send("get_editor_state")
        with pytest.raises(GodotCommandError):
            await client.send("get_editor_state", hint_policy="discard")
        third = await client.send("get_editor_state")
        fourth = await client.send("get_editor_state")
        await handler_task

        assert "new_errors_since_last_call" not in first
        assert third["new_errors_since_last_call"] == 2
        assert "new_errors_since_last_call" not in fourth
        await plugin.close()

    async def test_error_watermark_probe_success_does_not_consume_pending_hint(self, harness):
        plugin = await harness.connect_plugin(session_id="err-probe")
        client = GodotClient(harness.server, harness.registry)

        async def mock_handler():
            cmd = await plugin.recv_command()
            await plugin.send_response(
                cmd["request_id"],
                {"ok": 1},
                error_watermark={
                    "run_seq": 1,
                    "debugger_promoted": 0,
                    "editor_ring_warn": 0,
                },
            )
            cmd = await plugin.recv_command()
            await plugin.send_response(
                cmd["request_id"],
                {"ok": 2},
                error_watermark={
                    "run_seq": 1,
                    "debugger_promoted": 2,
                    "editor_ring_warn": 2,
                },
            )
            cmd = await plugin.recv_command()
            await plugin.send_response(
                cmd["request_id"],
                {"ok": 3},
                error_watermark={
                    "run_seq": 1,
                    "debugger_promoted": 2,
                    "editor_ring_warn": 2,
                },
            )

        handler_task = asyncio.create_task(mock_handler())
        first = await client.send("get_editor_state")
        probe = await client.send("get_editor_state", hint_policy="retain")
        third = await client.send("get_editor_state")
        await handler_task

        assert "new_errors_since_last_call" not in first
        assert "new_errors_since_last_call" not in probe
        assert "new_warnings_since_last_call" not in probe
        assert third["new_errors_since_last_call"] == 2
        assert third["new_warnings_since_last_call"] == 2
        await plugin.close()

    async def test_error_watermark_discard_consumes_both_channels_without_backlog(
        self, harness
    ):
        plugin = await harness.connect_plugin(session_id="err-discard")
        client = GodotClient(
            harness.server,
            harness.registry,
            default_hint_policy="discard",
        )

        async def mock_handler():
            cmd = await plugin.recv_command()
            await plugin.send_response(
                cmd["request_id"],
                {"ok": 1},
                error_watermark={
                    "run_seq": 1,
                    "debugger_promoted": 0,
                    "editor_ring_warn": 0,
                },
            )
            cmd = await plugin.recv_command()
            await plugin.send_response(
                cmd["request_id"],
                {"ok": 2},
                error_watermark={
                    "run_seq": 1,
                    "debugger_promoted": 2,
                    "editor_ring_warn": 3,
                },
            )
            cmd = await plugin.recv_command()
            await plugin.send_response(
                cmd["request_id"],
                {"ok": 3},
                error_watermark={
                    "run_seq": 1,
                    "debugger_promoted": 2,
                    "editor_ring_warn": 3,
                },
            )

        handler_task = asyncio.create_task(mock_handler())
        first = await client.send("get_editor_state")
        discarded = await client.send("get_editor_state")
        session = harness.registry.get("err-discard")
        assert session.pending_new_errors == 0
        assert session.pending_new_warnings == 0
        surfaced = await client.send("get_editor_state", hint_policy="surface")
        await handler_task

        for result in (first, discarded, surfaced):
            assert "new_errors_since_last_call" not in result
            assert "new_errors_hint" not in result
            assert "new_warnings_since_last_call" not in result
            assert "new_warnings_hint" not in result
        await plugin.close()

    async def test_warning_watermark_advance_injects_warning_hint_once(self, harness):
        ## A push_warning during a run advances game_warn. It must surface as
        ## new_warnings_since_last_call — the pre-fix watermark dropped every
        ## warning, so a warning-only run read as clean.
        plugin = await harness.connect_plugin(session_id="warn-watermark")
        client = GodotClient(harness.server, harness.registry)

        async def mock_handler():
            cmd = await plugin.recv_command()
            await plugin.send_response(
                cmd["request_id"],
                {"ok": 1},
                error_watermark={"run_seq": 1, "editor_ring": 0, "game_warn": 0},
            )
            cmd = await plugin.recv_command()
            await plugin.send_response(
                cmd["request_id"],
                {"ok": 2},
                error_watermark={"run_seq": 1, "editor_ring": 0, "game_warn": 1},
            )
            cmd = await plugin.recv_command()
            await plugin.send_response(
                cmd["request_id"],
                {"ok": 3},
                error_watermark={"run_seq": 1, "editor_ring": 0, "game_warn": 1},
            )

        handler_task = asyncio.create_task(mock_handler())
        first = await client.send("get_editor_state")
        second = await client.send("get_editor_state")
        third = await client.send("get_editor_state")
        await handler_task

        assert "new_warnings_since_last_call" not in first
        assert second["new_warnings_since_last_call"] == 1
        assert "logs_read(source='editor'" in second["new_warnings_hint"]
        ## Warnings are not errors — the error hint must stay absent.
        assert "new_errors_since_last_call" not in second
        assert "new_warnings_since_last_call" not in third
        await plugin.close()

    async def test_warning_and_error_watermark_surface_independently(self, harness):
        ## Errors and warnings advancing in the same response each get their
        ## own hint and count; neither is folded into the other.
        plugin = await harness.connect_plugin(session_id="warn-and-err")
        client = GodotClient(harness.server, harness.registry)

        async def mock_handler():
            cmd = await plugin.recv_command()
            await plugin.send_response(
                cmd["request_id"],
                {"ok": 1},
                error_watermark={
                    "run_seq": 1,
                    "editor_ring": 0,
                    "editor_ring_warn": 0,
                },
            )
            cmd = await plugin.recv_command()
            await plugin.send_response(
                cmd["request_id"],
                {"ok": 2},
                error_watermark={
                    "run_seq": 1,
                    "editor_ring": 1,
                    "editor_ring_warn": 2,
                },
            )

        handler_task = asyncio.create_task(mock_handler())
        first = await client.send("get_editor_state")
        second = await client.send("get_editor_state")
        await handler_task

        assert "new_errors_since_last_call" not in first
        assert "new_warnings_since_last_call" not in first
        assert second["new_errors_since_last_call"] == 1
        assert second["new_warnings_since_last_call"] == 2
        await plugin.close()

    async def test_warning_watermark_editor_and_game_streams_sum(self, harness):
        ## Editor-process and game-process warnings are independent streams
        ## (no shared view like the error path's game/debugger overlap), so
        ## their deltas sum rather than dedupe with max().
        plugin = await harness.connect_plugin(session_id="warn-sum")
        client = GodotClient(harness.server, harness.registry)

        async def mock_handler():
            cmd = await plugin.recv_command()
            await plugin.send_response(
                cmd["request_id"],
                {"ok": 1},
                error_watermark={"run_seq": 1, "editor_ring_warn": 0, "game_warn": 0},
            )
            cmd = await plugin.recv_command()
            await plugin.send_response(
                cmd["request_id"],
                {"ok": 2},
                error_watermark={"run_seq": 1, "editor_ring_warn": 1, "game_warn": 2},
            )

        handler_task = asyncio.create_task(mock_handler())
        first = await client.send("get_editor_state")
        second = await client.send("get_editor_state")
        await handler_task

        assert "new_warnings_since_last_call" not in first
        assert second["new_warnings_since_last_call"] == 3
        await plugin.close()

    async def test_warning_watermark_first_game_warn_on_new_run_counts_full(self, harness):
        ## game_warn is per-run: first seen on an advanced run has no baseline
        ## to diff, so it counts in full (mirrors game_error_warn).
        plugin = await harness.connect_plugin(session_id="warn-new-run")
        client = GodotClient(harness.server, harness.registry)

        async def mock_handler():
            cmd = await plugin.recv_command()
            await plugin.send_response(
                cmd["request_id"],
                {"ok": 1},
                error_watermark={"run_seq": 1, "editor_ring": 0},
            )
            cmd = await plugin.recv_command()
            await plugin.send_response(
                cmd["request_id"],
                {"ok": 2},
                error_watermark={"run_seq": 2, "editor_ring": 0, "game_warn": 2},
            )

        handler_task = asyncio.create_task(mock_handler())
        first = await client.send("get_editor_state")
        second = await client.send("get_editor_state")
        await handler_task

        assert "new_warnings_since_last_call" not in first
        assert second["new_warnings_since_last_call"] == 2
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
# Pending-future scoping (#690)
# ---------------------------------------------------------------------------


class TestPendingFutureScoping:
    async def test_disconnect_fails_in_flight_command_immediately(self, harness):
        """#690 finding 1: a connection close must fail that session's
        in-flight futures NOW, not leave the caller to wait out its full
        per-command timeout (120s for test_run) — and the failure must be a
        ConnectionError, not a TimeoutError, so the circuit breaker records
        a disconnect."""
        plugin = await harness.connect_plugin(session_id="dc-inflight")
        client = GodotClient(harness.server, harness.registry)

        async def crash_mid_command():
            await plugin.recv_command()
            ## Editor "crashes" without ever replying.
            await plugin.close()

        crash_task = asyncio.create_task(crash_mid_command())
        loop = asyncio.get_running_loop()
        started = loop.time()
        with pytest.raises(ConnectionError):
            await client.send("run_tests", session_id="dc-inflight", timeout=30.0)
        elapsed = loop.time() - started
        await crash_task

        assert elapsed < 5.0, (
            f"disconnect must settle the pending future immediately, not after "
            f"the 30s command timeout (took {elapsed:.1f}s)"
        )
        assert (
            client.circuit_breaker.snapshot("dc-inflight")["last_failure_kind"] == "ConnectionError"
        ), "the breaker must see a disconnect, not a timeout"

    async def test_disconnect_leaves_other_sessions_futures_pending(self, harness):
        """Failing session A's futures on its disconnect must not touch
        session B's in-flight command."""
        plugin_a = await harness.connect_plugin(session_id="dc-a")
        plugin_b = await harness.connect_plugin(session_id="dc-b")
        client = GodotClient(harness.server, harness.registry)

        async def respond_b_after_a_dies():
            cmd = await plugin_b.recv_command()
            ## A dies while B's command is in flight.
            await plugin_a.close()
            await asyncio.sleep(0.2)
            await plugin_b.send_response(cmd["request_id"], {"survived": True})

        handler = asyncio.create_task(respond_b_after_a_dies())
        result = await client.send("get_editor_state", session_id="dc-b")
        await handler

        assert result == {"survived": True}
        await plugin_b.close()

    async def test_cross_session_response_injection_is_dropped(self, harness):
        """#690 finding 3: a response for session A's request_id arriving on
        session B's connection must be dropped — only the connection the
        command was sent to may resolve its future."""
        plugin_a = await harness.connect_plugin(session_id="inj-a")
        plugin_b = await harness.connect_plugin(session_id="inj-b")
        client = GodotClient(harness.server, harness.registry)

        async def inject_then_answer():
            cmd = await plugin_a.recv_command()
            request_id = cmd["request_id"]
            ## Hostile session B forges a reply to A's request.
            await plugin_b.send_response(request_id, {"forged": True})
            await asyncio.sleep(0.2)
            ## The genuine session answers afterwards.
            await plugin_a.send_response(request_id, {"forged": False})

        handler = asyncio.create_task(inject_then_answer())
        result = await client.send("get_editor_state", session_id="inj-a")
        await handler

        assert result == {"forged": False}, (
            "the forged cross-session response must not resolve the future"
        )
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

    async def test_editor_not_ready_sub_code_passes_through_envelope(self, harness):
        """#651 stage 1: a plugin-side EDITOR_NOT_READY carrying the
        attribution payload (data.sub_code + retryable + hint) must reach
        the caller intact — top-level code unchanged for existing
        dashboards, sub-code visible both structurally and in str(exc)
        for clients that only see the serialized error."""
        plugin = await harness.connect_plugin()
        client = GodotClient(harness.server, harness.registry)

        async def mock_handler():
            cmd = await plugin.recv_command()
            await plugin.send_error(
                cmd["request_id"],
                "EDITOR_NOT_READY",
                "Game is not running — start the project first",
                data={
                    "sub_code": "EDITOR_GAME_NOT_RUNNING",
                    "retryable": False,
                    "hint": "Start the game with project_run, then retry.",
                },
            )

        handler_task = asyncio.create_task(mock_handler())
        with pytest.raises(GodotCommandError) as exc_info:
            await client.send("game_eval")
        await handler_task

        assert exc_info.value.code == "EDITOR_NOT_READY"
        assert exc_info.value.data["sub_code"] == "EDITOR_GAME_NOT_RUNNING"
        assert exc_info.value.data["retryable"] is False
        assert exc_info.value.data["hint"] == "Start the game with project_run, then retry."
        assert "sub_code=EDITOR_GAME_NOT_RUNNING" in str(exc_info.value)
        await plugin.close()

    async def test_send_to_no_active_session_raises(self, harness):
        client = GodotClient(harness.server, harness.registry)
        with pytest.raises(GodotCommandError) as exc_info:
            await client.send("anything")
        assert exc_info.value.code == "PLUGIN_DISCONNECTED"
        assert "No active Godot session" in exc_info.value.message
        assert exc_info.value.data["reason"] == "no_active_session"
        assert exc_info.value.data["connected"] is False
        assert "container localhost is not host localhost" in exc_info.value.data["hint"]

    async def test_send_to_unknown_session_raises(self, harness):
        client = GodotClient(harness.server, harness.registry)
        with pytest.raises(GodotCommandError) as exc_info:
            await client.send("anything", session_id="nonexistent")
        assert exc_info.value.code == "PLUGIN_DISCONNECTED"
        assert "nonexistent" in exc_info.value.message
        assert exc_info.value.data["reason"] == "session_not_found"
        assert exc_info.value.data["session_id"] == "nonexistent"
        assert exc_info.value.data["connected"] is False
        assert "session_manage(op='list')" in exc_info.value.data["hint"]

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
        ## audit-v2 #8: solo-user case. Two editors are connected with A
        ## active; A's editor crashes, leaving B as sole survivor. Pre-fix,
        ## every subsequent tool call would fail with "no active session"
        ## until the agent guessed to call session_activate. Now B is
        ## auto-promoted on A's disconnect.
        plugin_a = await harness.connect_plugin(session_id="failover-a")
        plugin_b = await harness.connect_plugin(session_id="failover-b")
        ## A connected first → A is active. Pin A explicitly so the test's
        ## preconditions don't depend on registration order
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
        ## Mandatory (#716) — see conftest's drain_handshake_ack.
        await drain_handshake_ack(ws)
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
        ## Mandatory ack drain (#716) — see conftest's drain_handshake_ack.
        await drain_handshake_ack(ws)
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
# Per-launch handshake auth token (#690 finding 4)
# ---------------------------------------------------------------------------


class TestHandshakeAuthToken:
    async def test_matching_token_is_accepted(self, harness):
        harness.server._auth_token = "launch-secret"
        plugin = await harness.connect_plugin(session_id="tok-ok", auth_token="launch-secret")
        assert harness.registry.get("tok-ok") is not None
        await plugin.close()

    async def test_wrong_token_is_rejected_before_registration(self, harness):
        harness.server._auth_token = "launch-secret"

        ## Hand-roll the handshake — connect_plugin() would assert on the
        ## missing ack; here the server must close us before any ack.
        ws = await websockets.connect(f"ws://127.0.0.1:{harness.port}")
        await ws.send(
            json.dumps(
                {
                    "type": "handshake",
                    "session_id": "tok-bad",
                    "godot_version": "4.4.1",
                    "project_path": "/tmp/attacker",
                    "plugin_version": "0.0.1",
                    "protocol_version": 1,
                    "auth_token": "not-the-secret",
                }
            )
        )
        with pytest.raises(websockets.ConnectionClosed) as exc_info:
            await asyncio.wait_for(ws.recv(), timeout=2.0)
        assert exc_info.value.rcvd.code == 4003
        assert harness.registry.get("tok-bad") is None, "rejected peer must never register"

    async def test_absent_token_is_accepted_for_compat(self, harness):
        ## Older plugins and editors adopting a server they didn't spawn
        ## have no token — the gate only rejects PRESENT-but-wrong tokens.
        harness.server._auth_token = "launch-secret"
        plugin = await harness.connect_plugin(session_id="tok-absent")
        assert harness.registry.get("tok-absent") is not None
        await plugin.close()

    async def test_empty_string_token_is_treated_as_absent(self, harness):
        ## A client that serializes auth_token: "" instead of omitting the
        ## field carries no secret — it must ride the same compat path as
        ## an absent token, not get 4003'd. Rejecting "" buys no security:
        ## omitting the field is always accepted.
        harness.server._auth_token = "launch-secret"
        plugin = await harness.connect_plugin(session_id="tok-empty", auth_token="")
        assert harness.registry.get("tok-empty") is not None
        await plugin.close()

    async def test_token_sent_to_tokenless_server_is_ignored(self, harness):
        ## A plugin can carry a stale token from a previous managed server
        ## while connecting to a manually-started (tokenless) dev server —
        ## that must not lock it out.
        assert harness.server._auth_token is None
        plugin = await harness.connect_plugin(session_id="tok-stale", auth_token="stale-token")
        assert harness.registry.get("tok-stale") is not None
        await plugin.close()

    async def test_env_token_reaches_enforcement_end_to_end(self, monkeypatch):
        ## Pin the GODOT_AI_WS_TOKEN env-var name end to end: create_server
        ## must hand the env token to the WS server, and a wrong-token
        ## handshake against that server must be closed with 4003. A rename
        ## on either side would silently drop enforcement and this test.
        from fastmcp import Client

        from godot_ai.server import create_server

        monkeypatch.setenv("GODOT_AI_WS_TOKEN", "env-secret")
        mcp = create_server(ws_port=19533)
        async with Client(mcp):
            ws = await websockets.connect("ws://127.0.0.1:19533")
            await ws.send(
                json.dumps(
                    {
                        "type": "handshake",
                        "session_id": "env-tok-bad",
                        "godot_version": "4.4.1",
                        "project_path": "/tmp/attacker",
                        "plugin_version": "0.0.1",
                        "protocol_version": 1,
                        "auth_token": "not-the-env-secret",
                    }
                )
            )
            with pytest.raises(websockets.ConnectionClosed) as exc_info:
                await asyncio.wait_for(ws.recv(), timeout=2.0)
            assert exc_info.value.rcvd.code == 4003


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
            # #651 stage 1: the gate attributes the block to its sub-code.
            assert exc_info.value.data["sub_code"] == "EDITOR_PLAYING"
        finally:
            await asyncio.wait_for(task, timeout=2.0)
            await plugin.close()


# --- Per-response envelope self-heal: stale "playing" cache clears on the
# very next tool call without an `editor_state` ceremony, because the
# plugin stamps live readiness onto every response. ---


class TestResponseEnvelopeReadinessSelfHeal:
    async def test_any_response_envelope_heals_stale_playing_cache(self, harness):
        """A stale 'playing' cache is cleared by the next tool call's reply,
        not just by `editor_state`. Reproduces the recurring telemetry signal
        where `EDITOR_NOT_READY` fires long after `project_run` because a
        `readiness_changed -> ready` event was dropped or coalesced.

        The mock plugin replies to a non-`editor_state` read with
        `readiness="ready"` in the envelope; the server must heal the cache
        before exposing the next `require_writable` call to the agent.
        """
        plugin = await harness.connect_plugin(session_id="env-heal-1", readiness="playing")
        client = GodotClient(harness.server, harness.registry)
        runtime = DirectRuntime(registry=harness.registry, client=client)
        session = harness.registry.get("env-heal-1")
        assert session.readiness == "playing"

        async def mock_plugin_loop():
            ## First call is a read that has nothing to do with readiness;
            ## the envelope's `readiness` field alone must heal the cache.
            cmd = await plugin.recv_command()
            assert cmd["command"] == "get_selection"
            await plugin.send_response(
                cmd["request_id"],
                {"selected_paths": [], "count": 0},
                readiness="ready",
            )
            ## Now the agent issues a write. Without the envelope sync,
            ## `require_writable` would still see the stale "playing" cache
            ## and reject before `save_scene` ever leaves the server.
            cmd = await plugin.recv_command()
            assert cmd["command"] == "save_scene"
            await plugin.send_response(
                cmd["request_id"],
                {"path": "res://main.tscn", "undoable": False},
                readiness="ready",
            )

        task = asyncio.create_task(mock_plugin_loop())
        try:
            await editor_handlers.editor_selection_get(runtime)
            assert session.readiness == "ready", (
                "envelope-level readiness on the get_selection reply must "
                "have healed the stale 'playing' cache"
            )
            saved = await scene_handlers.scene_save(runtime)
            assert saved["path"] == "res://main.tscn"
        finally:
            await asyncio.wait_for(task, timeout=2.0)
            await plugin.close()

    async def test_error_response_envelope_also_heals_cache(self, harness):
        """Error replies carry the envelope readiness too. Without this, an
        agent retrying a recoverable error would still see a stale cache."""
        plugin = await harness.connect_plugin(session_id="env-heal-err", readiness="playing")
        client = GodotClient(harness.server, harness.registry)
        runtime = DirectRuntime(registry=harness.registry, client=client)
        session = harness.registry.get("env-heal-err")

        async def mock_plugin_loop():
            cmd = await plugin.recv_command()
            await plugin.send_error(
                cmd["request_id"],
                code="NODE_NOT_FOUND",
                message="no such node",
                readiness="ready",
            )

        task = asyncio.create_task(mock_plugin_loop())
        try:
            with pytest.raises(GodotCommandError):
                await runtime.send_command("get_node", {"path": "/None"})
            assert session.readiness == "ready"
        finally:
            await asyncio.wait_for(task, timeout=2.0)
            await plugin.close()

    async def test_envelope_heal_promotes_ready_to_playing(self, harness):
        """Bidirectional — a stale 'ready' cache is promoted to 'playing'
        from the envelope, so the next write correctly blocks instead of
        slipping through against a now-running game."""
        plugin = await harness.connect_plugin(session_id="env-heal-2", readiness="ready")
        client = GodotClient(harness.server, harness.registry)
        runtime = DirectRuntime(registry=harness.registry, client=client)
        session = harness.registry.get("env-heal-2")

        async def mock_plugin():
            cmd = await plugin.recv_command()
            await plugin.send_response(
                cmd["request_id"],
                {"selected_paths": [], "count": 0},
                readiness="playing",
            )

        task = asyncio.create_task(mock_plugin())
        try:
            await editor_handlers.editor_selection_get(runtime)
            assert session.readiness == "playing"
            with pytest.raises(GodotCommandError) as exc_info:
                await scene_handlers.scene_save(runtime)
            assert exc_info.value.code == "EDITOR_NOT_READY"
            # #651 stage 1: the gate attributes the block to its sub-code.
            assert exc_info.value.data["sub_code"] == "EDITOR_PLAYING"
        finally:
            await asyncio.wait_for(task, timeout=2.0)
            await plugin.close()

    async def test_old_plugin_omitting_envelope_readiness_is_a_no_op(self, harness):
        """Old plugins (pre-envelope-stamping) don't send the field at all.
        The cache must keep its current value rather than being blanked."""
        plugin = await harness.connect_plugin(session_id="env-heal-old", readiness="playing")
        client = GodotClient(harness.server, harness.registry)
        runtime = DirectRuntime(registry=harness.registry, client=client)
        session = harness.registry.get("env-heal-old")

        async def mock_plugin():
            cmd = await plugin.recv_command()
            ## `readiness=None` -> field omitted on the wire, exactly what
            ## an unupgraded plugin would send.
            await plugin.send_response(
                cmd["request_id"],
                {"selected_paths": [], "count": 0},
                readiness=None,
            )

        task = asyncio.create_task(mock_plugin())
        try:
            await editor_handlers.editor_selection_get(runtime)
            assert session.readiness == "playing", (
                "old plugin omitting `readiness` must not blank or change the cache"
            )
        finally:
            await asyncio.wait_for(task, timeout=2.0)
            await plugin.close()

    async def test_unknown_envelope_readiness_value_is_ignored(self, harness):
        """A future plugin emitting a state the server doesn't know yet
        must not corrupt the cache — the canonical KNOWN_READINESS set
        gates writes through forward-compat omission."""
        plugin = await harness.connect_plugin(session_id="env-heal-fwd", readiness="ready")
        client = GodotClient(harness.server, harness.registry)
        runtime = DirectRuntime(registry=harness.registry, client=client)
        session = harness.registry.get("env-heal-fwd")

        async def mock_plugin():
            cmd = await plugin.recv_command()
            await plugin.send_response(
                cmd["request_id"],
                {"selected_paths": [], "count": 0},
                readiness="bogus_state",
            )

        task = asyncio.create_task(mock_plugin())
        try:
            await editor_handlers.editor_selection_get(runtime)
            assert session.readiness == "ready"
        finally:
            await asyncio.wait_for(task, timeout=2.0)
            await plugin.close()


# ---------------------------------------------------------------------------
# Malformed-frame resilience (#526)
# ---------------------------------------------------------------------------


class TestMalformedFrameResilience:
    """A single garbled frame must not tear down the editor session (#526).

    Before the fix, a non-JSON frame or a command response failing Pydantic
    validation raised out of the per-message loop into the catch-all, and the
    finally block unregistered the session — one bad frame dropped the whole
    editor↔server bridge.
    """

    async def test_non_json_frame_is_skipped_and_session_survives(self, harness):
        plugin = await harness.connect_plugin(session_id="bad-frame")

        await plugin.ws.send("this is not json {")
        await asyncio.sleep(0.1)
        assert harness.registry.get("bad-frame") is not None, (
            "one non-JSON frame must not unregister the session"
        )

        ## Subsequent commands still round-trip over the surviving connection.
        client = GodotClient(harness.server, harness.registry)

        async def mock_handler():
            cmd = await plugin.recv_command()
            await plugin.send_response(cmd["request_id"], {"version": "4.4.1"})

        handler_task = asyncio.create_task(mock_handler())
        result = await client.send("get_editor_state")
        await handler_task
        assert result == {"version": "4.4.1"}
        await plugin.close()

    async def test_non_object_json_frame_is_skipped_and_session_survives(self, harness):
        ## Valid JSON that isn't an object (`[]`, `42`) reaches `.get()` and
        ## would raise AttributeError through the catch-all without the
        ## isinstance guard (#526 Copilot follow-up).
        plugin = await harness.connect_plugin(session_id="non-obj-frame")

        await plugin.ws.send("[]")
        await plugin.ws.send("42")
        await asyncio.sleep(0.1)
        assert harness.registry.get("non-obj-frame") is not None, (
            "non-object JSON frames must not unregister the session"
        )
        await plugin.close()

    async def test_invalid_command_response_is_skipped_and_session_survives(self, harness):
        plugin = await harness.connect_plugin(session_id="bad-response")

        ## Not an event and fails CommandResponse validation (no request_id,
        ## bad status type).
        await plugin.ws.send(json.dumps({"status": 42, "data": "nope"}))
        await asyncio.sleep(0.1)
        assert harness.registry.get("bad-response") is not None, (
            "one invalid command response must not unregister the session"
        )

        client = GodotClient(harness.server, harness.registry)

        async def mock_handler():
            cmd = await plugin.recv_command()
            await plugin.send_response(cmd["request_id"], {"ok": True})

        handler_task = asyncio.create_task(mock_handler())
        result = await client.send("get_editor_state")
        await handler_task
        assert result == {"ok": True}
        await plugin.close()

    async def test_invalid_response_with_request_id_fails_pending_fast(self, harness):
        """A malformed frame that names a pending request_id fails that
        future immediately with a clear error instead of leaving the caller
        to hit its timeout — and the session still survives."""
        plugin = await harness.connect_plugin(session_id="bad-corr")
        client = GodotClient(harness.server, harness.registry)

        async def mock_handler():
            cmd = await plugin.recv_command()
            ## Correct request_id, but `status` has the wrong type so
            ## CommandResponse validation fails.
            await plugin.ws.send(json.dumps({"request_id": cmd["request_id"], "status": 42}))

        handler_task = asyncio.create_task(mock_handler())
        with pytest.raises(ConnectionError, match="Malformed response"):
            await client.send("get_editor_state", timeout=5.0)
        await handler_task

        assert harness.registry.get("bad-corr") is not None
        await plugin.close()

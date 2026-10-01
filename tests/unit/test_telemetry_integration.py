"""Integration-ish tests that pin the wiring between telemetry and the
rest of the package: session registry hooks, the ``<domain>_manage``
rollup capturing ``op`` as ``sub_action``, the plugin_event allowlist.

Lives in tests/unit (no asyncio websockets) but exercises real modules
end-to-end through their public API.
"""

from __future__ import annotations

import asyncio
import types

import pytest
from fastmcp import FastMCP

from godot_ai import telemetry as tel
from godot_ai.sessions.registry import Session, SessionRegistry
from godot_ai.tools._meta_tool import register_manage_tool


@pytest.fixture
def captured(isolated_data_dir):
    """Yield the list that ``_add_pending`` appends to. Builds on the shared
    ``isolated_data_dir`` (``tests/unit/conftest.py``) for env-clean +
    tmp-dir + reset_telemetry isolation."""
    collector = tel.get_telemetry()
    sent: list[tel.TelemetryRecord] = []
    collector._add_pending = sent.append  # type: ignore[method-assign]
    return sent


@pytest.fixture(autouse=True)
def _restore_manage_registry():
    """Don't leak rollup registrations between tests."""
    from godot_ai.tools import _meta_tool

    ops = dict(_meta_tool.MANAGE_TOOL_OPS)
    handlers = {k: dict(v) for k, v in _meta_tool.MANAGE_TOOL_HANDLERS.items()}
    forms = {k: dict(v) for k, v in _meta_tool.MANAGE_TOOL_RESOURCE_FORMS.items()}
    yield
    _meta_tool.MANAGE_TOOL_OPS.clear()
    _meta_tool.MANAGE_TOOL_OPS.update(ops)
    _meta_tool.MANAGE_TOOL_HANDLERS.clear()
    _meta_tool.MANAGE_TOOL_HANDLERS.update(handlers)
    _meta_tool.MANAGE_TOOL_RESOURCE_FORMS.clear()
    _meta_tool.MANAGE_TOOL_RESOURCE_FORMS.update(forms)


def _wait_for(records: list, count: int, timeout: float = 2.0) -> None:
    import time

    deadline = time.monotonic() + timeout
    while len(records) < count and time.monotonic() < deadline:
        time.sleep(0.02)


def _wait_for_plugin_events(records: list, count: int, timeout: float = 2.0) -> None:
    """Wait until ``count`` PLUGIN_EVENT records are visible.

    The plain ``_wait_for`` counts ALL records, so a late-flushing connect
    record from a previous test's registry can satisfy it before the
    plugin event drains from the background telemetry worker — the
    type-filtered assertion then sees zero (flaky under the full suite).
    Wait on the filtered condition instead.
    """
    import time

    from godot_ai import telemetry as tel

    deadline = time.monotonic() + timeout
    while (
        sum(1 for r in records if r.record_type is tel.RecordType.PLUGIN_EVENT) < count
        and time.monotonic() < deadline
    ):
        time.sleep(0.02)


# --- session registry telemetry ------------------------------------------


class TestSessionRegistryTelemetry:
    def _make_session(self, sid: str = "demo@a3f2") -> Session:
        return Session(
            session_id=sid,
            godot_version="4.4.1",
            project_path="/tmp/demo",
            plugin_version="0.0.1",
            protocol_version=1,
            server_launch_mode="dev_venv",
        )

    def test_register_emits_connected_event(self, captured) -> None:
        reg = SessionRegistry()
        reg.register(self._make_session())
        _wait_for(captured, 1)

        match = [
            r
            for r in captured
            if r.record_type is tel.RecordType.GODOT_CONNECTION
            and r.data.get("event") == "connected"
        ]
        assert len(match) == 1
        rec = match[0]
        assert rec.data["godot_version"] == "4.4.1"
        assert rec.data["plugin_version"] == "0.0.1"
        assert rec.data["server_launch_mode"] == "dev_venv"
        ## session_id should be hashed.
        assert rec.session_id.endswith("@a3f2")
        assert "demo" not in rec.session_id

    def test_unregister_emits_disconnected_event(self, captured) -> None:
        reg = SessionRegistry()
        reg.register(self._make_session())
        reg.unregister("demo@a3f2")
        _wait_for(captured, 2)

        match = [
            r
            for r in captured
            if r.record_type is tel.RecordType.GODOT_CONNECTION
            and r.data.get("event") == "disconnected"
        ]
        assert len(match) == 1
        assert match[0].data["session_count"] == 0
        ## close_code is always present; None means no close frame was
        ## observed (non-WS teardown), a numeric value is the normalized
        ## WebSocket close code (1011 keepalive, 1013 exclusive-run flood).
        assert "close_code" in match[0].data
        assert match[0].data["close_code"] is None

    def test_unregister_records_normalized_close_code(self, captured) -> None:
        reg = SessionRegistry()
        reg.register(self._make_session())
        reg.unregister("demo@a3f2", close_code=1011)
        _wait_for(captured, 2)

        match = [
            r
            for r in captured
            if r.record_type is tel.RecordType.GODOT_CONNECTION
            and r.data.get("event") == "disconnected"
        ]
        assert len(match) == 1
        assert match[0].data["close_code"] == 1011

    def test_multiple_sessions_milestone(self, captured) -> None:
        reg = SessionRegistry()
        reg.register(self._make_session("a@aaaa"))
        reg.register(self._make_session("b@bbbb"))
        _wait_for(captured, 3)  # 2 connect + 1 milestone

        milestones = [r for r in captured if r.milestone is tel.MilestoneType.MULTIPLE_SESSIONS]
        assert len(milestones) == 1

    def test_register_swallows_telemetry_exceptions(self, captured, monkeypatch) -> None:
        """A telemetry failure inside ``register`` must not break the
        normal connect path. The except branch in registry.py is the
        load-bearing guard against a transient telemetry crash taking
        down session management — assert it actually swallows.
        """
        from godot_ai.sessions import registry as reg_mod

        def boom(*_a, **_kw) -> None:
            raise RuntimeError("telemetry kaboom")

        monkeypatch.setattr(reg_mod, "record_telemetry", boom)
        reg = SessionRegistry()
        ## Must complete without raising; session is still registered.
        reg.register(self._make_session())
        assert reg.get("demo@a3f2") is not None

    def test_unregister_swallows_telemetry_exceptions(self, captured, monkeypatch) -> None:
        from godot_ai.sessions import registry as reg_mod

        reg = SessionRegistry()
        reg.register(self._make_session())

        def boom(*_a, **_kw) -> None:
            raise RuntimeError("telemetry kaboom")

        monkeypatch.setattr(reg_mod, "record_telemetry", boom)
        ## Must complete without raising.
        reg.unregister("demo@a3f2")
        assert reg.get("demo@a3f2") is None


# --- manage-tool rollup captures op as sub_action ------------------------


class TestRollupCapturesOp:
    def test_op_recorded_as_sub_action(self, captured) -> None:
        mcp = FastMCP("test")
        tel.install_fastmcp_wraps(mcp)

        async def op_one(runtime, **_kw) -> dict:
            return {"op": "one"}

        async def op_two(runtime, **_kw) -> dict:
            return {"op": "two"}

        register_manage_tool(
            mcp,
            tool_name="demo_manage",
            description="demo",
            ops={"one": op_one, "two": op_two},
        )

        async def run() -> None:
            try:
                await mcp.call_tool("demo_manage", {"op": "two", "params": {}})
            except Exception:
                pass

        asyncio.run(run())
        _wait_for(captured, 1)

        tool_records = [r for r in captured if r.record_type is tel.RecordType.TOOL_EXECUTION]
        assert len(tool_records) == 1
        rec = tool_records[0]
        assert rec.data["tool_name"] == "demo_manage"
        assert rec.data["sub_action"] == "two"


# --- plugin_event allowlist ---------------------------------------------


def _run_handle_event(stub, session_id: str, data: dict) -> None:
    """Drive the (async) ``_handle_event`` to completion synchronously.

    ``_handle_event`` became a coroutine when ``custom_tools_changed``
    started awaiting the tools/list_changed broadcast — calling it bare
    would create a never-executed coroutine and silently record nothing.
    """
    from godot_ai.transport import websocket as ws_mod

    asyncio.run(ws_mod.GodotWebSocketServer._handle_event(stub, session_id, data))


class TestPluginEventAllowlist:
    def test_known_event_recorded(self, captured) -> None:

        ## Hand-drive _handle_event with a stub server: we only need its
        ## ``registry`` attribute. The dispatcher in the real code path
        ## delegates straight to record_telemetry on a valid event.
        reg = SessionRegistry()
        session = Session(
            session_id="demo@a3f2",
            godot_version="4.4.1",
            project_path="/tmp/demo",
            plugin_version="0.0.1",
        )
        reg.register(session)
        captured.clear()  # drop the connect event

        ## Build a minimal instance to call _handle_event on; the method
        ## reads only self.registry.
        stub = types.SimpleNamespace(registry=reg)
        _run_handle_event(
            stub,  # type: ignore[arg-type]
            "demo@a3f2",
            {
                "type": "event",
                "event": "plugin_event",
                "data": {"name": "dock_startup", "data": {"developer_mode": True}},
            },
        )
        _wait_for_plugin_events(captured, 1)

        plugin_events = [r for r in captured if r.record_type is tel.RecordType.PLUGIN_EVENT]
        assert len(plugin_events) == 1
        rec = plugin_events[0]
        assert rec.data["event_name"] == "dock_startup"
        assert rec.data["developer_mode"] is True
        ## hashed
        assert rec.session_id.endswith("@a3f2")
        assert "demo" not in rec.session_id

    def test_payload_data_cannot_override_event_name(self, captured) -> None:
        """A malformed plugin_event with an ``event_name`` key hidden in
        its ``data`` dict must not be able to spoof the recorded event
        name past the allowlist. The canonical name is ``payload.name``;
        ``data`` is merged first so the canonical name always wins.
        """

        reg = SessionRegistry()
        session = Session(
            session_id="demo@a3f2",
            godot_version="4.4.1",
            project_path="/tmp/demo",
            plugin_version="0.0.1",
        )
        reg.register(session)
        captured.clear()

        stub = types.SimpleNamespace(registry=reg)
        _run_handle_event(
            stub,  # type: ignore[arg-type]
            "demo@a3f2",
            {
                "type": "event",
                "event": "plugin_event",
                "data": {
                    "name": "dock_startup",
                    "data": {"event_name": "FAKE_OVERRIDE", "other": 1},
                },
            },
        )
        _wait_for_plugin_events(captured, 1)

        plugin_events = [r for r in captured if r.record_type is tel.RecordType.PLUGIN_EVENT]
        assert len(plugin_events) == 1
        assert plugin_events[0].data["event_name"] == "dock_startup"
        assert "other" not in plugin_events[0].data

    def test_payload_unknown_fields_are_dropped(self, captured) -> None:

        reg = SessionRegistry()
        session = Session(
            session_id="demo@a3f2",
            godot_version="4.4.1",
            project_path="/tmp/demo",
            plugin_version="0.0.1",
        )
        reg.register(session)
        captured.clear()

        stub = types.SimpleNamespace(registry=reg)
        _run_handle_event(
            stub,  # type: ignore[arg-type]
            "demo@a3f2",
            {
                "type": "event",
                "event": "plugin_event",
                "data": {
                    "name": "plugin_reload",
                    "data": {
                        "success": True,
                        "source": "dock_button",
                        "project_path": "/Users/alice/private-game",
                        "event_name": "FAKE_OVERRIDE",
                    },
                },
            },
        )
        _wait_for_plugin_events(captured, 1)

        plugin_events = [r for r in captured if r.record_type is tel.RecordType.PLUGIN_EVENT]
        assert len(plugin_events) == 1
        assert plugin_events[0].data == {
            "event_name": "plugin_reload",
            "success": True,
            "source": "dock_button",
        }

    def test_malformed_payload_values_are_replaced_safely(self, captured) -> None:

        reg = SessionRegistry()
        session = Session(
            session_id="demo@a3f2",
            godot_version="4.4.1",
            project_path="/tmp/demo",
            plugin_version="0.0.1",
        )
        reg.register(session)
        captured.clear()

        stub = types.SimpleNamespace(registry=reg)
        _run_handle_event(
            stub,  # type: ignore[arg-type]
            "demo@a3f2",
            {
                "type": "event",
                "event": "plugin_event",
                "data": {
                    "name": "self_update",
                    "data": {
                        "status": "res://unexpected",
                        "from_version": "1.2.3",
                        "to_version": "res://private-game/addons/godot_ai",
                        "error": "/Users/alice/private-game/full editor log",
                        "logs": "full editor log",
                    },
                },
            },
        )
        _wait_for_plugin_events(captured, 1)

        plugin_events = [r for r in captured if r.record_type is tel.RecordType.PLUGIN_EVENT]
        assert len(plugin_events) == 1
        rec = plugin_events[0]
        assert rec.data["event_name"] == "self_update"
        assert rec.data["status"] == "unknown"
        assert rec.data["from_version"] == "1.2.3"
        assert rec.data["to_version"] == "unknown"
        assert rec.data["error"] == "reported"
        assert all("private-game" not in str(value) for value in rec.data.values())
        assert "logs" not in rec.data

    def test_plugin_reload_error_message_is_replaced(self, captured) -> None:

        reg = SessionRegistry()
        session = Session(
            session_id="demo@a3f2",
            godot_version="4.4.1",
            project_path="/tmp/demo",
            plugin_version="0.0.1",
        )
        reg.register(session)
        captured.clear()

        stub = types.SimpleNamespace(registry=reg)
        _run_handle_event(
            stub,  # type: ignore[arg-type]
            "demo@a3f2",
            {
                "type": "event",
                "event": "plugin_event",
                "data": {
                    "name": "plugin_reload",
                    "data": {
                        "success": False,
                        "source": "mcp_tool",
                        "error": "failed reading /Users/alice/private-game/plugin.gd",
                    },
                },
            },
        )
        _wait_for_plugin_events(captured, 1)

        plugin_events = [r for r in captured if r.record_type is tel.RecordType.PLUGIN_EVENT]
        assert len(plugin_events) == 1
        assert plugin_events[0].data == {
            "event_name": "plugin_reload",
            "success": False,
            "source": "mcp_tool",
            "error": "reported",
        }

    def test_plugin_reload_and_dev_server_enums_default_unknown(self, captured) -> None:

        reg = SessionRegistry()
        session = Session(
            session_id="demo@a3f2",
            godot_version="4.4.1",
            project_path="/tmp/demo",
            plugin_version="0.0.1",
        )
        reg.register(session)
        captured.clear()

        stub = types.SimpleNamespace(registry=reg)
        for name, data in (
            ("plugin_reload", {"success": "yes", "source": "shell"}),
            ("dev_server_toggle", {"action": "restart"}),
        ):
            _run_handle_event(
                stub,  # type: ignore[arg-type]
                "demo@a3f2",
                {
                    "type": "event",
                    "event": "plugin_event",
                    "data": {"name": name, "data": data},
                },
            )
        _wait_for_plugin_events(captured, 2)

        plugin_events = [r for r in captured if r.record_type is tel.RecordType.PLUGIN_EVENT]
        assert plugin_events[0].data == {
            "event_name": "plugin_reload",
            "source": "unknown",
        }
        assert plugin_events[1].data == {
            "event_name": "dev_server_toggle",
            "action": "unknown",
        }

    def test_unknown_event_dropped(self, captured) -> None:

        reg = SessionRegistry()
        session = Session(
            session_id="demo@a3f2",
            godot_version="4.4.1",
            project_path="/tmp/demo",
            plugin_version="0.0.1",
        )
        reg.register(session)
        captured.clear()

        stub = types.SimpleNamespace(registry=reg)
        _run_handle_event(
            stub,  # type: ignore[arg-type]
            "demo@a3f2",
            {
                "type": "event",
                "event": "plugin_event",
                "data": {"name": "not_in_allowlist", "data": {}},
            },
        )
        _wait_for(captured, 0, timeout=0.3)

        plugin_events = [r for r in captured if r.record_type is tel.RecordType.PLUGIN_EVENT]
        assert plugin_events == []


# --- runtime telemetry opt-out (#913) ------------------------------------


class TestRuntimeTelemetryOptOut:
    """The wire half of #913: how the latch is reached, and how it cannot be.

    ``test_telemetry.py::TestRuntimeOptOutLatch`` owns what the latch means."""

    @staticmethod
    def _registry_with_session() -> SessionRegistry:
        reg = SessionRegistry()
        reg.register(
            Session(
                session_id="demo@a3f2",
                godot_version="4.4.1",
                project_path="/tmp/demo",
                plugin_version="0.0.1",
            )
        )
        return reg

    def _dispatch(self, reg: SessionRegistry, session_id: str, event_data) -> None:
        _run_handle_event(
            types.SimpleNamespace(registry=reg),  # type: ignore[arg-type]
            session_id,
            {"type": "event", "event": "telemetry_opt_out", "data": event_data},
        )

    def test_event_latches_the_process_off(self, captured) -> None:
        reg = self._registry_with_session()
        assert tel.live_telemetry_enabled() is True

        self._dispatch(reg, "demo@a3f2", {})

        assert tel.runtime_opt_out_latched() is True
        assert tel.live_telemetry_enabled() is False

    def test_latched_server_records_nothing_further(self, captured) -> None:
        ## The point of the exercise: after the opt-out lands, the adopted
        ## server stops producing records.
        reg = self._registry_with_session()
        ## Registering queues a connect record. Drain it *before* latching —
        ## the fixture swaps ``_add_pending`` for a list append, so the worker can
        ## still deliver it after a later clear and fail the assert below.
        _wait_for(captured, 1)
        captured.clear()
        self._dispatch(reg, "demo@a3f2", {})

        tel.record_telemetry(tel.RecordType.USAGE, {"x": 1}, session_id="demo@a3f2")
        _wait_for(captured, 1, timeout=0.3)

        assert captured == []

    def test_unregistered_session_cannot_latch(self, captured) -> None:
        ## Authentication is what puts a session in the registry, and
        ## ``_handle_event`` returns early without one — so the opt-out
        ## inherits that gate rather than being reachable on its own.
        reg = SessionRegistry()

        self._dispatch(reg, "ghost@0000", {})

        assert tel.runtime_opt_out_latched() is False
        assert tel.live_telemetry_enabled() is True

    def test_malformed_payload_is_dropped_without_latching(self, captured) -> None:
        ## Dropped like any other malformed event on this channel, and it
        ## must not latch on the way out — a garbled frame is not a decision.
        reg = self._registry_with_session()

        self._dispatch(reg, "demo@a3f2", "not-a-dict")

        assert tel.runtime_opt_out_latched() is False
        assert tel.live_telemetry_enabled() is True

    def test_extra_payload_fields_cannot_re_enable_telemetry(self, captured) -> None:
        ## Field-free on purpose: no "enabled" flag for a hostile or stale
        ## plugin to set. Extras are ignored; the frame means one thing.
        reg = self._registry_with_session()

        self._dispatch(reg, "demo@a3f2", {"enabled": True, "telemetry_enabled": True})

        assert tel.live_telemetry_enabled() is False

    def test_repeat_events_stay_latched(self, captured) -> None:
        ## Every reconnect re-asserts it, so a replay must be inert.
        reg = self._registry_with_session()
        self._dispatch(reg, "demo@a3f2", {})
        self._dispatch(reg, "demo@a3f2", {})
        self._dispatch(reg, "demo@a3f2", {})

        assert tel.live_telemetry_enabled() is False

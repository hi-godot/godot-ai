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
    """Yield the list that ``_send`` appends to. Builds on the shared
    ``isolated_data_dir`` (``tests/unit/conftest.py``) for env-clean +
    tmp-dir + reset_telemetry isolation."""
    collector = tel.get_telemetry()
    sent: list[tel.TelemetryRecord] = []
    collector._send = sent.append  # type: ignore[method-assign]
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


class TestPluginEventAllowlist:
    def test_known_event_recorded(self, captured) -> None:
        from godot_ai.transport import websocket as ws_mod

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
        ws_mod.GodotWebSocketServer._handle_event(
            stub,  # type: ignore[arg-type]
            "demo@a3f2",
            {
                "type": "event",
                "event": "plugin_event",
                "data": {"name": "dock_startup", "data": {"developer_mode": True}},
            },
        )
        _wait_for(captured, 1)

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
        from godot_ai.transport import websocket as ws_mod

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
        ws_mod.GodotWebSocketServer._handle_event(
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
        _wait_for(captured, 1)

        plugin_events = [r for r in captured if r.record_type is tel.RecordType.PLUGIN_EVENT]
        assert len(plugin_events) == 1
        assert plugin_events[0].data["event_name"] == "dock_startup"
        assert plugin_events[0].data["other"] == 1

    def test_unknown_event_dropped(self, captured) -> None:
        from godot_ai.transport import websocket as ws_mod

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
        ws_mod.GodotWebSocketServer._handle_event(
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

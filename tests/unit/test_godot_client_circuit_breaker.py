"""GodotClient ↔ circuit breaker wiring (F-006 death-spiral guard).

Exercises the integration between ``GodotClient.send`` and
``EditorBridgeCircuitBreaker`` using a stubbed WebSocket server, so the
tests don't depend on real port binding (and so the suite stays fast).
The tracker's own state machine is covered by
``test_circuit_breaker.py`` — the tests here are about the wiring:

* every transport-error path increments the counter
* a plugin-level error response does NOT increment the counter
* a successful round-trip clears the counter
* once the circuit is open, calls short-circuit with PLUGIN_DISCONNECTED
  carrying a retry_after_ms hint
* per-session and "no active session" circuits stay isolated
"""

from __future__ import annotations

import pytest

from godot_ai.godot_client.circuit_breaker import EditorBridgeCircuitBreaker
from godot_ai.godot_client.client import GodotClient, GodotCommandError
from godot_ai.protocol.envelope import CommandResponse, ErrorDetail
from godot_ai.sessions.registry import Session, SessionRegistry


class _FakeClock:
    def __init__(self, start: float = 1000.0):
        self.now = start

    def __call__(self) -> float:
        return self.now

    def advance(self, seconds: float) -> None:
        self.now += seconds


class _StubWsServer:
    """Minimal stand-in for ``GodotWebSocketServer.send_command``.

    The script is a list of (command_filter, action) pairs: each ``send_command``
    call consumes the first script entry whose ``command_filter`` matches the
    request. ``action`` is either:

    * an ``Exception`` instance — raised as if transport failed
    * a ``dict`` — returned wrapped in a ``CommandResponse(status="ok", data=…)``
    * an ``ErrorDetail`` — returned as ``CommandResponse(status="error", error=…)``

    ``recorded_calls`` lets tests assert what actually reached the wire.
    """

    def __init__(self) -> None:
        self.script: list[tuple[str | None, Exception | dict | ErrorDetail]] = []
        self.recorded_calls: list[tuple[str, str]] = []  # (command, session_id)

    def queue(self, action, *, command: str | None = None) -> None:
        self.script.append((command, action))

    async def send_command(
        self,
        session_id: str,
        command: str,
        params=None,
        timeout: float = 5.0,
    ) -> CommandResponse:
        self.recorded_calls.append((command, session_id))
        if not self.script:
            raise AssertionError(f"unexpected send_command({command!r}) — script exhausted")
        ## Find first matching entry by command filter (None matches anything).
        for idx, (filter_cmd, action) in enumerate(self.script):
            if filter_cmd is None or filter_cmd == command:
                self.script.pop(idx)
                break
        else:
            raise AssertionError(
                f"no script entry for command {command!r}; remaining: {self.script!r}"
            )
        if isinstance(action, Exception):
            raise action
        if isinstance(action, ErrorDetail):
            return CommandResponse(request_id="r", status="error", data={}, error=action)
        return CommandResponse(request_id="r", status="ok", data=action)


def _make_registry(*session_ids: str, active: str | None = None) -> SessionRegistry:
    registry = SessionRegistry()
    for sid in session_ids:
        registry.register(
            Session(
                session_id=sid,
                godot_version="4.4.1",
                project_path="/tmp/test",
                plugin_version="0.0.1",
            )
        )
    if active is not None:
        registry.set_active(active)
    return registry


def _client(registry, *, threshold: int = 3, initial_open_ms: int = 1000):
    ws = _StubWsServer()
    breaker = EditorBridgeCircuitBreaker(
        threshold=threshold,
        initial_open_ms=initial_open_ms,
        max_open_ms=30_000,
        time_fn=_FakeClock(),
    )
    return GodotClient(ws, registry, circuit_breaker=breaker), ws, breaker


class TestPreThresholdBehavior:
    """Below the threshold, transport exceptions still propagate."""

    async def test_first_no_session_failures_raise_actionable_error(self) -> None:
        client, _, breaker = _client(_make_registry(), threshold=3)
        for _ in range(2):
            with pytest.raises(GodotCommandError) as exc_info:
                await client.send("anything")
            assert exc_info.value.code == "PLUGIN_DISCONNECTED"
            assert "No active Godot session" in exc_info.value.message
            assert exc_info.value.data["reason"] == "no_active_session"
            assert exc_info.value.data["connected"] is False
            assert exc_info.value.data["retryable"] is True
            assert "container localhost is not host localhost" in exc_info.value.data["hint"]
        assert breaker.check_open(None) is None
        assert breaker.snapshot(None)["consecutive_failures"] == 2

    async def test_first_session_not_found_failures_raise_actionable_error(self) -> None:
        client, _, breaker = _client(_make_registry(), threshold=3)
        for _ in range(2):
            with pytest.raises(GodotCommandError) as exc_info:
                await client.send("anything", session_id="ghost")
            assert exc_info.value.code == "PLUGIN_DISCONNECTED"
            assert "ghost" in exc_info.value.message
            assert exc_info.value.data["reason"] == "session_not_found"
            assert exc_info.value.data["session_id"] == "ghost"
            assert exc_info.value.data["connected"] is False
            assert "session_manage(op='list')" in exc_info.value.data["hint"]
        assert breaker.check_open("ghost") is None

    async def test_first_transport_timeout_raises_bare_timeout(self) -> None:
        client, ws, breaker = _client(_make_registry("sess", active="sess"), threshold=3)
        for _ in range(2):
            ws.queue(TimeoutError("boom"))
            with pytest.raises(TimeoutError):
                await client.send("slow", session_id="sess")
        assert breaker.snapshot("sess")["consecutive_failures"] == 2
        assert breaker.check_open("sess") is None


class TestCircuitOpens:
    async def test_no_session_threshold_opens_circuit(self) -> None:
        client, _, breaker = _client(_make_registry(), threshold=3)
        for _ in range(3):
            with pytest.raises(GodotCommandError):
                await client.send("anything")
        ## Threshold reached on the 3rd failure — the 4th call short-circuits.
        with pytest.raises(GodotCommandError) as exc_info:
            await client.send("anything")
        assert exc_info.value.code == "PLUGIN_DISCONNECTED"
        data = exc_info.value.data
        assert data["circuit_open"] is True
        assert data["retryable"] is True
        assert data["retry_after_ms"] > 0
        assert data["last_failure_kind"] == "no_active_session"
        assert "no connected Godot editor" in exc_info.value.message
        assert "retry in" in exc_info.value.message

    async def test_session_not_found_threshold_opens_circuit_keyed_by_session(self) -> None:
        client, _, breaker = _client(_make_registry(), threshold=3)
        for _ in range(3):
            with pytest.raises(GodotCommandError):
                await client.send("anything", session_id="ghost")
        with pytest.raises(GodotCommandError) as exc_info:
            await client.send("anything", session_id="ghost")
        assert exc_info.value.code == "PLUGIN_DISCONNECTED"
        data = exc_info.value.data
        assert data["last_failure_kind"] == "session_not_found"
        assert data["reason"] == "session_not_found"
        assert data["session_id"] == "ghost"
        assert data["circuit_open"] is True
        assert "missing-session" in exc_info.value.message
        assert "still not connected" in exc_info.value.message

    async def test_transport_timeout_threshold_opens_circuit(self) -> None:
        client, ws, _ = _client(_make_registry("sess", active="sess"), threshold=3)
        for _ in range(3):
            ws.queue(TimeoutError("nope"))
            with pytest.raises(TimeoutError):
                await client.send("slow", session_id="sess")
        ## 4th call short-circuits before any transport work.
        before_len = len(ws.recorded_calls)
        with pytest.raises(GodotCommandError) as exc_info:
            await client.send("slow", session_id="sess")
        assert exc_info.value.code == "PLUGIN_DISCONNECTED"
        assert exc_info.value.data["last_failure_kind"] == "TimeoutError"
        ## The circuit-open path must not have hit transport.
        assert len(ws.recorded_calls) == before_len

    async def test_transport_connection_error_threshold_opens_circuit(self) -> None:
        client, ws, _ = _client(_make_registry("sess", active="sess"), threshold=3)
        for _ in range(3):
            ws.queue(ConnectionError("ws dropped"))
            with pytest.raises(ConnectionError):
                await client.send("ping", session_id="sess")
        with pytest.raises(GodotCommandError) as exc_info:
            await client.send("ping", session_id="sess")
        assert exc_info.value.code == "PLUGIN_DISCONNECTED"
        assert exc_info.value.data["last_failure_kind"] == "ConnectionError"


class TestCircuitDoesNotOpen:
    async def test_plugin_error_response_does_not_count_as_transport_failure(self) -> None:
        ## F-006 rationale: a plugin-side error (NODE_NOT_FOUND, etc.) is a
        ## *successful* bridge round-trip — the transport works, the request
        ## was answered. Such errors must NOT increment the breaker or it
        ## would slam shut on any tool getting a normal validation error.
        client, ws, breaker = _client(_make_registry("sess", active="sess"), threshold=3)
        for _ in range(5):
            ws.queue(ErrorDetail(code="NODE_NOT_FOUND", message="/Missing"))
            with pytest.raises(GodotCommandError) as exc_info:
                await client.send("get_node", session_id="sess")
            assert exc_info.value.code == "NODE_NOT_FOUND"
        snap = breaker.snapshot("sess")
        assert snap["circuit_open"] is False
        assert snap["consecutive_failures"] == 0


class TestReset:
    async def test_successful_call_resets_counter(self) -> None:
        client, ws, breaker = _client(_make_registry("sess", active="sess"), threshold=3)
        for _ in range(2):
            ws.queue(TimeoutError("nope"))
            with pytest.raises(TimeoutError):
                await client.send("slow", session_id="sess")
        ws.queue({"ok": True})
        result = await client.send("ping", session_id="sess")
        assert result == {"ok": True}
        assert breaker.snapshot("sess")["consecutive_failures"] == 0

        ## Fresh threshold countdown.
        for _ in range(2):
            ws.queue(TimeoutError("nope"))
            with pytest.raises(TimeoutError):
                await client.send("slow", session_id="sess")
        assert breaker.check_open("sess") is None

    async def test_per_session_success_clears_no_session_circuit(self) -> None:
        ## After a "no active session" death-spiral, the first successful
        ## per-session call must also clear the global no-session circuit.
        client, ws, breaker = _client(_make_registry(), threshold=3)
        for _ in range(3):
            with pytest.raises(GodotCommandError):
                await client.send("anything")
        assert breaker.check_open(None) is not None

        ## Register a session and serve one call.
        client.registry.register(
            Session(
                session_id="late",
                godot_version="4.4.1",
                project_path="/tmp/late",
                plugin_version="0.0.1",
            )
        )
        ws.queue({"ok": True})
        result = await client.send("ping")  # uses active session "late"
        assert result == {"ok": True}
        assert breaker.check_open(None) is None


class TestPerSessionIsolation:
    async def test_failing_session_does_not_affect_healthy_session(self) -> None:
        registry = _make_registry("good", active="good")
        client, ws, breaker = _client(registry, threshold=3)
        ## Trip the circuit on a missing pinned session.
        for _ in range(3):
            with pytest.raises(GodotCommandError):
                await client.send("anything", session_id="ghost")
        with pytest.raises(GodotCommandError):
            await client.send("anything", session_id="ghost")
        ## "good" session is still untouched.
        assert breaker.check_open("good") is None
        ws.queue({"alive": True})
        result = await client.send("ping", session_id="good")
        assert result == {"alive": True}


class TestErrorPayloadShape:
    async def test_payload_carries_actionable_fields(self) -> None:
        client, _, _ = _client(_make_registry(), threshold=3)
        for _ in range(3):
            with pytest.raises(GodotCommandError):
                await client.send("anything")
        with pytest.raises(GodotCommandError) as exc_info:
            await client.send("anything")

        err = exc_info.value
        assert err.code == "PLUGIN_DISCONNECTED"
        assert err.data["retryable"] is True
        assert isinstance(err.data["retry_after_ms"], int)
        assert err.data["retry_after_ms"] >= 1
        assert err.data["circuit_open"] is True
        assert err.data["consecutive_failures"] >= 3
        assert err.data["reason"] == "no_active_session"
        assert err.data["connected"] is False
        assert err.data["diagnostics"]["check_sessions"] == "session_manage(op='list')"
        assert "no connected Godot editor" in err.message

        ## Payload is JSON-serializable (no Exception objects or Enums) so it
        ## flows through MCP without surprises.
        payload = err.to_payload()
        import json

        json.dumps(payload)  # no TypeError


class TestSettingsViaConstructor:
    async def test_default_threshold_does_not_open_until_5_failures(self) -> None:
        ## Pin the production default — the docstring claims threshold=5.
        client = GodotClient(
            _StubWsServer(),
            _make_registry(),
            # default breaker
        )
        for _ in range(4):
            with pytest.raises(GodotCommandError):
                await client.send("anything")
        assert client.circuit_breaker.check_open(None) is None
        with pytest.raises(GodotCommandError):
            await client.send("anything")  # 5th — trips
        with pytest.raises(GodotCommandError) as exc_info:
            await client.send("anything")  # 6th — short-circuits
        assert exc_info.value.code == "PLUGIN_DISCONNECTED"

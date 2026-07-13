"""Non-finite float rejection on the server->plugin params path (#688).

JSON cannot represent NaN/Infinity. Empirically, pydantic accepts them into
``dict[str, Any]`` params and ``model_dump_json`` serializes them as ``null``
— so without a guard, a client whose float computation went NaN calls a write
tool, the value silently becomes null in transit, and the plugin stores null
while the tool reports success. ``GodotClient.send`` now rejects such params
with INVALID_PARAMS naming the offending key path, before the command touches
the transport or the circuit breaker.
"""

from __future__ import annotations

import json
import math

import pytest

from godot_ai.godot_client.circuit_breaker import EditorBridgeCircuitBreaker
from godot_ai.godot_client.client import GodotClient, GodotCommandError
from godot_ai.protocol.envelope import CommandRequest, find_non_finite_float
from godot_ai.sessions.registry import Session, SessionRegistry


class _RecordingWsServer:
    """send_command stub that records calls and returns a canned response."""

    def __init__(self) -> None:
        self.calls: list[tuple[str, dict]] = []

    async def send_command(self, session_id, command, params=None, timeout=5.0):
        self.calls.append((command, params or {}))
        from godot_ai.protocol.envelope import CommandResponse

        return CommandResponse(request_id="r", status="ok", data={})


def _make_client() -> tuple[GodotClient, _RecordingWsServer, EditorBridgeCircuitBreaker]:
    registry = SessionRegistry()
    registry.register(
        Session(
            session_id="proj@abcd",
            godot_version="4.7",
            project_path="/tmp/proj",
            plugin_version="2.9.2",
        )
    )
    registry.set_active("proj@abcd")
    ws = _RecordingWsServer()
    breaker = EditorBridgeCircuitBreaker()
    return GodotClient(ws, registry, circuit_breaker=breaker), ws, breaker


class TestFindNonFiniteFloat:
    def test_none_for_finite_tree(self) -> None:
        params = {"a": 1.5, "b": [1, 2.0, {"c": -3.25}], "d": "nan", "e": True}
        assert find_non_finite_float(params) is None

    def test_top_level_nan(self) -> None:
        assert find_non_finite_float({"speed": float("nan")}) == "params.speed"

    def test_top_level_inf(self) -> None:
        assert find_non_finite_float({"x": float("inf")}) == "params.x"
        assert find_non_finite_float({"x": float("-inf")}) == "params.x"

    def test_nested_dict_path(self) -> None:
        params = {"value": {"position": {"x": 1.0, "y": float("nan")}}}
        assert find_non_finite_float(params) == "params.value.position.y"

    def test_list_index_path(self) -> None:
        params = {"points": [1.0, 2.0, float("inf")]}
        assert find_non_finite_float(params) == "params.points[2]"

    def test_tuple_supported(self) -> None:
        assert find_non_finite_float({"t": (1.0, float("nan"))}) == "params.t[1]"

    def test_bool_is_not_treated_as_float(self) -> None:
        ## bool is an int subclass, not float — but guard the assumption.
        assert find_non_finite_float({"flag": True}) is None

    def test_empty_params(self) -> None:
        assert find_non_finite_float({}) is None


class TestSendRejectsNonFinite:
    async def test_nan_param_raises_invalid_params_before_transport(self) -> None:
        client, ws, _ = _make_client()
        with pytest.raises(GodotCommandError) as exc_info:
            await client.send("set_property", {"path": "/Main", "value": float("nan")})
        assert exc_info.value.code == "INVALID_PARAMS"
        assert "params.value" in exc_info.value.message
        assert ws.calls == [], "command must never reach the transport"

    async def test_nested_inf_names_key_path(self) -> None:
        client, ws, _ = _make_client()
        with pytest.raises(GodotCommandError) as exc_info:
            await client.send(
                "set_property",
                {"value": {"gravity": [0.0, float("-inf")]}},
            )
        assert "params.value.gravity[1]" in exc_info.value.message
        assert ws.calls == []

    async def test_rejection_does_not_trip_circuit_breaker(self) -> None:
        client, _, breaker = _make_client()
        for _ in range(10):
            with pytest.raises(GodotCommandError):
                await client.send("set_property", {"v": float("nan")})
        assert breaker.check_open("proj@abcd") is None, (
            "param validation errors are caller errors, not transport failures"
        )

    async def test_finite_params_still_sent(self) -> None:
        client, ws, _ = _make_client()
        result = await client.send("set_property", {"path": "/Main", "value": 1.5})
        assert isinstance(result, dict)
        assert ws.calls == [("set_property", {"path": "/Main", "value": 1.5})]


class TestWhyTheGuardExists:
    def test_model_dump_json_silently_nullifies_nan(self) -> None:
        """Documents the pydantic behavior the guard defends against: if a
        NaN ever reached serialization it would become null on the wire."""
        request = CommandRequest(command="set_property", params={"v": float("nan")})
        wire = json.loads(request.model_dump_json())
        assert wire["params"]["v"] is None

    def test_json_loads_accepts_nonstandard_nan_inbound(self) -> None:
        """Documents that stdlib json.loads accepts non-standard NaN/Infinity
        tokens, so stringified-params coercion cannot be relied on to reject
        them — the send-side guard is the enforcement point."""
        parsed = json.loads('{"v": NaN, "w": Infinity}')
        assert math.isnan(parsed["v"])
        assert math.isinf(parsed["w"])

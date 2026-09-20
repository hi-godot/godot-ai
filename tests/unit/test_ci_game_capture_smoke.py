from __future__ import annotations

import runpy
from pathlib import Path

import pytest

SCRIPT = Path(__file__).resolve().parents[2] / "script" / "ci-game-capture-smoke"
MODULE = runpy.run_path(str(SCRIPT))


@pytest.mark.parametrize("size,limit,valid", [
    ((63, 44), 64, True), ((64, 50), 64, True), ((64, 52), 64, True),
    ((62, 44), 64, False), ((65, 44), 64, False), ((64, 0), 64, False),
    ((850, 595), 0, True), ((649, 510), 0, True), ((649, 533), 0, True),
    ((2, 2), 0, False),
])
def test_capture_size_accepts_only_bounded_rounding(size, limit, valid):
    assert MODULE["_capture_size_valid"](size, limit) is valid


@pytest.fixture
def rendering_probe(monkeypatch):
    probe = MODULE["_check_game_rendering"]
    clock = [0.0]
    calls = []
    monkeypatch.setenv("CAPTURE_HDR_2D", "1")
    monkeypatch.setattr(probe.__globals__["time"], "monotonic", lambda: clock[0])
    def sleep(delay):
        clock[0] += delay
    monkeypatch.setattr(probe.__globals__["time"], "sleep", sleep)

    def run(responses, deadline=5.0):
        pending = iter(responses)
        def tool_call(*args):
            calls.append(args)
            return next(pending)
        monkeypatch.setitem(probe.__globals__, "_tool_call", tool_call)
        history = []
        probe("owned-session", history, deadline)
        return history
    return run, calls, clock


def test_rendering_retries_only_explicit_not_ready(rendering_probe):
    run, calls, clock = rendering_probe
    transient = {"error": {"code": "EVAL_GAME_NOT_READY", "message": "liveness pending"}}
    result = {"result": {"hdr": True, "renderer": "forward_plus"}}
    history = run([transient, result])
    assert len(calls) == 2
    assert clock[0] == 2.0
    assert "liveness pending" in history[0]
    assert "forward_plus" in history[1]


@pytest.mark.parametrize("response", [
    {"error": {"code": "INTERNAL_ERROR", "message": "broken"}},
    {"_text": "EVAL_GAME_NOT_READY without a structured code"},
    {}, {"result": None},
    {"result": {"hdr": False, "renderer": "forward_plus"}},
    {"result": {"hdr": True, "renderer": "gl_compatibility"}},
    {"result": {"hdr": True, "renderer": "unknown"}},
    {"error": {"code": "INTERNAL_ERROR"}, "result": {"hdr": True, "renderer": "forward_plus"}},
])
def test_rendering_permanent_or_malformed_response_fails_immediately(rendering_probe, response):
    run, calls, clock = rendering_probe
    with pytest.raises(RuntimeError):
        run([response])
    assert len(calls) == 1
    assert clock[0] == 0


def test_rendering_retry_uses_existing_deadline(rendering_probe):
    run, calls, clock = rendering_probe
    response = {"error": {"code": "EVAL_GAME_NOT_READY"}}
    with pytest.raises(RuntimeError, match="exceeded the capture budget"):
        run([response, response, response], deadline=3.0)
    assert len(calls) == 2
    assert clock[0] == 3.0


def test_sdr_requires_a_known_renderer(rendering_probe, monkeypatch):
    run, calls, clock = rendering_probe
    monkeypatch.setenv("CAPTURE_HDR_2D", "0")
    with pytest.raises(RuntimeError, match="Unknown game renderer"):
        run([{"result": {"hdr": False}}])
    assert len(calls) == 1
    assert clock[0] == 0


def test_rendering_success_after_deadline_fails(rendering_probe, monkeypatch):
    _, _, clock = rendering_probe
    probe = MODULE["_check_game_rendering"]
    def late_response(*args):
        clock[0] = 6.0
        return {"result": {"hdr": True, "renderer": "forward_plus"}}
    monkeypatch.setitem(probe.__globals__, "_tool_call", late_response)
    history = []
    with pytest.raises(RuntimeError, match="exceeded the capture budget"):
        probe("owned-session", history, 5.0)
    assert "forward_plus" in history[0]

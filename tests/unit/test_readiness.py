"""Unit tests for readiness gating."""

from __future__ import annotations

import pytest

from godot_ai.godot_client.client import GodotCommandError
from godot_ai.handlers._readiness import require_writable
from godot_ai.protocol.errors import ErrorCode
from godot_ai.runtime.direct import DirectRuntime
from godot_ai.sessions.registry import Session, SessionRegistry


def _make_session(readiness: str = "ready") -> Session:
    return Session(
        session_id="test-001",
        godot_version="4.4.1",
        project_path="/tmp/test",
        plugin_version="0.0.1",
        readiness=readiness,
    )


def _make_runtime(readiness: str = "ready") -> DirectRuntime:
    registry = SessionRegistry()
    registry.register(_make_session(readiness))
    return DirectRuntime(registry=registry, client=object())


def test_require_writable_passes_when_ready():
    require_writable(_make_runtime("ready"))


def test_require_writable_passes_when_no_scene():
    require_writable(_make_runtime("no_scene"))


def test_require_writable_passes_when_no_session():
    runtime = DirectRuntime(registry=SessionRegistry(), client=object())
    require_writable(runtime)  # no-op, no error


def test_require_writable_rejects_importing():
    with pytest.raises(GodotCommandError) as exc_info:
        require_writable(_make_runtime("importing"))
    assert exc_info.value.code == ErrorCode.EDITOR_NOT_READY
    assert "importing" in exc_info.value.message
    assert exc_info.value.data == {"retryable": True, "state": "importing"}
    # Structured hints are also embedded in the serialized form so MCP
    # clients that only see str(exc) can still distinguish retryable cases.
    assert "retryable=True" in str(exc_info.value)
    assert "state=importing" in str(exc_info.value)


def test_require_writable_rejects_playing():
    with pytest.raises(GodotCommandError) as exc_info:
        require_writable(_make_runtime("playing"))
    assert exc_info.value.code == ErrorCode.EDITOR_NOT_READY
    assert "play mode" in exc_info.value.message
    assert exc_info.value.data == {"retryable": False, "state": "playing"}
    assert "retryable=False" in str(exc_info.value)


def test_session_readiness_in_to_dict():
    session = _make_session("importing")
    d = session.to_dict()
    assert d["readiness"] == "importing"


def test_godot_command_error_without_data_preserves_legacy_format():
    err = GodotCommandError(code=ErrorCode.EDITOR_NOT_READY, message="oops")
    assert err.data == {}
    assert str(err) == "EDITOR_NOT_READY: oops"


def test_session_readiness_defaults_to_ready():
    session = Session(
        session_id="x",
        godot_version="4.4.1",
        project_path="/tmp",
        plugin_version="0.0.1",
    )
    assert session.readiness == "ready"

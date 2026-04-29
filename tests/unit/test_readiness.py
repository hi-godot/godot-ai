"""Unit tests for readiness gating."""

from __future__ import annotations

import pytest

from godot_ai.godot_client.client import GodotCommandError
from godot_ai.handlers import editor as editor_handlers
from godot_ai.handlers._readiness import KNOWN_READINESS, require_writable
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
    # The message names the recovery tool so MCP clients don't have to
    # infer "how do I unstick this" from the state string alone.
    assert "project_stop" in exc_info.value.message
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


# --- editor_state self-heal — issue #262 ---


class _EditorStateClient:
    """Stub plugin that only handles get_editor_state.

    `readiness=None` means "omit the field from the response" — older plugins
    pre-dating the readiness self-heal don't emit it.
    """

    def __init__(self, readiness: str | None):
        self._readiness = readiness

    async def send(
        self,
        command: str,
        params: dict | None = None,
        session_id: str | None = None,
        timeout: float = 5.0,
    ) -> dict:
        if command != "get_editor_state":
            raise AssertionError(f"unexpected command: {command}")
        payload: dict = {
            "current_scene": "res://main.tscn",
            "project_name": "p",
            "is_playing": self._readiness == "playing",
            "godot_version": "4.4.1",
        }
        if self._readiness is not None:
            payload["readiness"] = self._readiness
        return payload


def _runtime_for_self_heal(
    cached: str, plugin_reports: str | None
) -> tuple[DirectRuntime, Session]:
    session = _make_session(cached)
    registry = SessionRegistry()
    registry.register(session)
    runtime = DirectRuntime(registry=registry, client=_EditorStateClient(plugin_reports))
    return runtime, session


async def test_editor_state_overwrites_stale_playing_cache():
    runtime, session = _runtime_for_self_heal(cached="playing", plugin_reports="ready")

    result = await editor_handlers.editor_state(runtime)

    assert result["readiness"] == "ready"
    assert session.readiness == "ready"
    # Followup require_writable now sees the refreshed cache and lets the
    # caller through. This is the critical end-to-end invariant — without
    # it, editor_state -> scene_save still fails with the stale cache.
    require_writable(runtime)


async def test_editor_state_syncs_playing_when_truly_playing():
    """Self-heal is bidirectional — a stale 'ready' cache must also reconcile
    so the next write correctly blocks instead of slipping through."""
    runtime, session = _runtime_for_self_heal(cached="ready", plugin_reports="playing")

    await editor_handlers.editor_state(runtime)

    assert session.readiness == "playing"
    with pytest.raises(GodotCommandError):
        require_writable(runtime)


async def test_editor_state_ignores_missing_readiness_field():
    """Older plugins that omit readiness must not blank the cache."""
    runtime, session = _runtime_for_self_heal(cached="ready", plugin_reports=None)

    await editor_handlers.editor_state(runtime)

    assert session.readiness == "ready"


async def test_editor_state_ignores_unknown_readiness_field():
    """Pinning this case lets a future plugin add new readiness values
    without a forward-compat refactor; the server keeps the prior value
    until the Python KNOWN_READINESS set is widened to match."""
    runtime, session = _runtime_for_self_heal(cached="ready", plugin_reports="bogus_state")

    await editor_handlers.editor_state(runtime)

    assert session.readiness == "ready"


async def test_editor_state_no_session_is_no_op():
    runtime = DirectRuntime(registry=SessionRegistry(), client=_EditorStateClient("ready"))

    result = await editor_handlers.editor_state(runtime)

    assert result["readiness"] == "ready"


def test_known_readiness_covers_all_states_handlers_emit():
    """Lock the canonical readiness set so contributors don't drift the
    plugin and server states out of sync. The plugin's get_readiness emits
    exactly these values today (see connection.gd::get_readiness)."""
    assert KNOWN_READINESS == frozenset({"ready", "importing", "playing", "no_scene"})

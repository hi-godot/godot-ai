"""Unit tests for readiness gating."""

from __future__ import annotations

import pytest

from godot_ai.godot_client.client import GodotCommandError
from godot_ai.handlers import editor as editor_handlers
from godot_ai.handlers._readiness import KNOWN_READINESS, require_writable_async
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


# --- Shared stub: counts probe calls and can simulate plugin disconnect.
# Used by both the editor_state self-heal tests (#262) and the
# require_writable_async live-probe tests (#437). ---


class _EditorStateClient:
    """Stub plugin that handles `get_editor_state` and tracks probe traffic.

    `readiness=None` means "omit the field from the response" — older plugins
    pre-dating the readiness self-heal don't emit it.

    `raise_on_probe=True` simulates a plugin disconnect / probe timeout so
    tests can exercise the require_writable_async fallback path.
    """

    def __init__(self, readiness: str | None, raise_on_probe: bool = False):
        self._readiness = readiness
        self._raise = raise_on_probe
        self.probe_calls = 0

    async def send(
        self,
        command: str,
        params: dict | None = None,
        session_id: str | None = None,
        timeout: float = 5.0,
        surface_error_hints: bool = True,
    ) -> dict:
        if command != "get_editor_state":
            raise AssertionError(f"unexpected command: {command}")
        self.probe_calls += 1
        if self._raise:
            raise ConnectionError("simulated plugin disconnect")
        payload: dict = {
            "current_scene": "res://main.tscn",
            "project_name": "p",
            "is_playing": self._readiness == "playing",
            "godot_version": "4.4.1",
        }
        if self._readiness is not None:
            payload["readiness"] = self._readiness
        return payload


def _runtime_with_stub(
    cached: str, plugin_reports: str | None, raise_on_probe: bool = False
) -> tuple[DirectRuntime, Session, _EditorStateClient]:
    session = _make_session(cached)
    registry = SessionRegistry()
    registry.register(session)
    client = _EditorStateClient(plugin_reports, raise_on_probe=raise_on_probe)
    return DirectRuntime(registry=registry, client=client), session, client


# --- editor_state self-heal — issue #262 ---


async def test_editor_state_overwrites_stale_playing_cache():
    runtime, session, _ = _runtime_with_stub(cached="playing", plugin_reports="ready")

    result = await editor_handlers.editor_state(runtime)

    assert result["readiness"] == "ready"
    assert session.readiness == "ready"
    # Followup require_writable_async now sees the refreshed cache and lets
    # the caller through. This is the critical end-to-end invariant —
    # without it, editor_state -> scene_save still fails with the stale
    # cache.
    await require_writable_async(runtime)


async def test_editor_state_syncs_playing_when_truly_playing():
    """Self-heal is bidirectional — a stale 'ready' cache must also reconcile
    so the next write correctly blocks instead of slipping through."""
    runtime, session, _ = _runtime_with_stub(cached="ready", plugin_reports="playing")

    await editor_handlers.editor_state(runtime)

    assert session.readiness == "playing"
    with pytest.raises(GodotCommandError):
        await require_writable_async(runtime)


async def test_editor_state_ignores_missing_readiness_field():
    """Older plugins that omit readiness must not blank the cache."""
    runtime, session, _ = _runtime_with_stub(cached="ready", plugin_reports=None)

    await editor_handlers.editor_state(runtime)

    assert session.readiness == "ready"


async def test_editor_state_ignores_unknown_readiness_field():
    """Pinning this case lets a future plugin add new readiness values
    without a forward-compat refactor; the server keeps the prior value
    until the Python KNOWN_READINESS set is widened to match."""
    runtime, session, _ = _runtime_with_stub(cached="ready", plugin_reports="bogus_state")

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


# --- require_writable_async fast/slow path —
# the case the envelope-level sync alone can't cover: the FIRST tool call
# after a stale state IS the write itself, so there's no prior response
# envelope to refresh the cache. ---


async def test_require_writable_async_passes_when_ready_no_probe():
    """Cache says writable -> no network, no probe. Critical for the
    common case so the gate adds zero latency."""
    runtime, _, client = _runtime_with_stub(cached="ready", plugin_reports="ready")
    await require_writable_async(runtime)
    assert client.probe_calls == 0


async def test_require_writable_async_passes_when_no_scene_no_probe():
    runtime, _, client = _runtime_with_stub(cached="no_scene", plugin_reports="ready")
    await require_writable_async(runtime)
    assert client.probe_calls == 0


async def test_require_writable_async_no_session_is_no_op():
    runtime = DirectRuntime(registry=SessionRegistry(), client=_EditorStateClient("ready"))
    await require_writable_async(runtime)


async def test_require_writable_async_probe_heals_stale_playing_cache():
    """The case the envelope sync alone can't catch — the first call after
    a stale 'playing' state is the write itself. The async gate must
    probe before rejecting and let the call through if the editor is
    actually ready."""
    runtime, session, client = _runtime_with_stub(cached="playing", plugin_reports="ready")
    await require_writable_async(runtime)
    assert client.probe_calls == 1
    assert session.readiness == "ready", "probe must heal the cache before letting the call through"


async def test_require_writable_async_rejects_importing_after_probe_confirms():
    runtime, session, client = _runtime_with_stub(cached="importing", plugin_reports="importing")
    with pytest.raises(GodotCommandError) as exc_info:
        await require_writable_async(runtime)
    assert exc_info.value.code == ErrorCode.EDITOR_NOT_READY
    data = exc_info.value.data
    assert data["editor_state"] == "importing"
    assert data["retryable"] is True
    # The hint must be an explicit, action-oriented instruction so AI callers
    # don't loop the failing write. See F-EDITOR-NOT-READY-LOOP fix.
    assert "Wait" in data["hint"] or "wait" in data["hint"]
    assert "importing" in data["hint"].lower()
    # Structured hints are also embedded in the serialized form so MCP
    # clients that only see str(exc) can still distinguish retryable cases.
    assert "retryable=True" in str(exc_info.value)
    assert "editor_state=importing" in str(exc_info.value)
    assert client.probe_calls == 1


async def test_require_writable_async_rejects_playing_after_probe_confirms():
    runtime, session, client = _runtime_with_stub(cached="playing", plugin_reports="playing")
    with pytest.raises(GodotCommandError) as exc_info:
        await require_writable_async(runtime)
    assert exc_info.value.code == ErrorCode.EDITOR_NOT_READY
    assert "play mode" in exc_info.value.message
    # The message names the recovery tool (the rolled-up form) so MCP
    # clients don't have to infer "how do I unstick this" from the state
    # string alone.
    assert 'project_manage(op="stop")' in exc_info.value.message
    data = exc_info.value.data
    assert data["editor_state"] == "playing"
    assert data["retryable"] is False
    # Hint must name the exact recovery call — this is the F-EDITOR-NOT-READY-
    # LOOP fix: cure the 89%-of-EDITOR_NOT_READYs-from-2-users retry pattern
    # by telling the LLM exactly which tool stops the stall.
    assert 'project_manage(op="stop")' in data["hint"]
    assert "retryable=False" in str(exc_info.value)
    assert "editor_state=playing" in str(exc_info.value)
    assert client.probe_calls == 1


async def test_require_writable_async_probe_failure_falls_back_to_cached_value():
    """If the probe itself fails (timeout, disconnect, plugin error), we
    can't trust the network — raise the gating error against the cached
    value rather than escalating to a connection error. The actual write
    would have failed too, so this keeps the failure mode coherent."""
    runtime, session, client = _runtime_with_stub(
        cached="playing", plugin_reports="ready", raise_on_probe=True
    )
    with pytest.raises(GodotCommandError) as exc_info:
        await require_writable_async(runtime)
    assert exc_info.value.code == ErrorCode.EDITOR_NOT_READY
    data = exc_info.value.data
    assert data["editor_state"] == "playing"
    assert data["retryable"] is False
    assert 'project_manage(op="stop")' in data["hint"]
    assert client.probe_calls == 1


async def test_require_writable_async_probe_handles_unknown_state_gracefully():
    """Forward-compat: if the probe returns a state the server doesn't
    know yet, sync_readiness_for_session is a no-op and we enforce
    against the prior cached value. A future plugin's new state name
    can't accidentally let a write slip through or get blocked."""
    runtime, session, client = _runtime_with_stub(
        cached="playing", plugin_reports="bogus_future_state"
    )
    with pytest.raises(GodotCommandError):
        await require_writable_async(runtime)
    assert client.probe_calls == 1
    assert session.readiness == "playing"

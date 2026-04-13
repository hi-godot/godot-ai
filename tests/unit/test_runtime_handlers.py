"""Unit tests for the direct runtime adapter and shared handlers."""

from __future__ import annotations

from godot_ai.handlers import editor as editor_handlers
from godot_ai.handlers import project as project_handlers
from godot_ai.handlers import session as session_handlers
from godot_ai.runtime.direct import DirectRuntime
from godot_ai.sessions.registry import Session, SessionRegistry


class StubClient:
    def __init__(self):
        self.calls: list[dict] = []

    async def send(
        self,
        command: str,
        params: dict | None = None,
        session_id: str | None = None,
        timeout: float = 5.0,
    ) -> dict:
        self.calls.append(
            {
                "command": command,
                "params": params,
                "session_id": session_id,
                "timeout": timeout,
            }
        )
        if command == "get_logs":
            return {"lines": [f"line {i}" for i in range(6)]}
        if command == "get_project_setting":
            key = params["key"] if params else ""
            return {"key": key, "value": f"value:{key}"}
        return {"status": "ok"}


class ReloadStubClient:
    def __init__(
        self,
        registry: SessionRegistry,
        new_session_id: str = "reloaded",
        raise_timeout: bool = False,
    ):
        self.registry = registry
        self.new_session_id = new_session_id
        self.raise_timeout = raise_timeout
        self.calls: list[dict] = []

    async def send(
        self,
        command: str,
        params: dict | None = None,
        session_id: str | None = None,
        timeout: float = 5.0,
    ) -> dict:
        self.calls.append(
            {
                "command": command,
                "params": params,
                "session_id": session_id,
                "timeout": timeout,
            }
        )
        if command == "reload_plugin":
            self.registry.unregister("old-session")
            self.registry.register(
                _make_session(
                    self.new_session_id,
                    project_path="/tmp/test_project",
                )
            )
            if self.raise_timeout:
                raise TimeoutError("disconnect during reload")
            return {"status": "reloading", "message": "Plugin reload initiated"}
        return {"status": "ok"}


def _make_session(session_id: str = "test-001", **overrides) -> Session:
    defaults = {
        "session_id": session_id,
        "godot_version": "4.4.1",
        "project_path": "/tmp/test_project",
        "plugin_version": "0.0.1",
    }
    defaults.update(overrides)
    return Session(**defaults)


def test_direct_runtime_exposes_registry_state():
    registry = SessionRegistry()
    registry.register(_make_session("a"))
    registry.register(_make_session("b"))
    registry.set_active("b")
    runtime = DirectRuntime(registry=registry, client=StubClient())

    assert runtime.active_session_id == "b"
    assert runtime.get_active_session().session_id == "b"
    assert [session.session_id for session in runtime.list_sessions()] == ["a", "b"]


async def test_logs_read_handler_uses_runtime_and_paginates():
    runtime = DirectRuntime(registry=SessionRegistry(), client=StubClient())

    result = await editor_handlers.logs_read(runtime, count=2, offset=3)

    assert result["lines"] == ["line 3", "line 4"]
    assert result["offset"] == 3
    assert result["limit"] == 2
    assert result["total_count"] == 6
    assert result["has_more"] is True


async def test_project_settings_resource_collects_results():
    runtime = DirectRuntime(registry=SessionRegistry(), client=StubClient())

    result = await project_handlers.project_settings_resource_data(runtime)

    assert result["settings"]["application/config/name"] == "value:application/config/name"
    assert result["errors"] is None


def test_session_handlers_keep_active_flag_shape():
    registry = SessionRegistry()
    registry.register(_make_session("a"))
    registry.register(_make_session("b"))
    registry.set_active("b")
    runtime = DirectRuntime(registry=registry, client=StubClient())

    result = session_handlers.session_list(runtime)

    sessions = {session["session_id"]: session["is_active"] for session in result["sessions"]}
    assert sessions == {"a": False, "b": True}


async def test_reload_plugin_returns_existing_replacement_session_without_wait_race():
    registry = SessionRegistry()
    registry.register(_make_session("old-session"))
    runtime = DirectRuntime(
        registry=registry,
        client=ReloadStubClient(registry=registry, new_session_id="new-session"),
    )

    result = await editor_handlers.reload_plugin(runtime)

    assert result == {
        "status": "reloaded",
        "old_session_id": "old-session",
        "new_session_id": "new-session",
    }
    assert runtime.active_session_id == "new-session"


async def test_reload_plugin_handles_disconnect_before_ack_if_replacement_is_present():
    registry = SessionRegistry()
    registry.register(_make_session("old-session"))
    runtime = DirectRuntime(
        registry=registry,
        client=ReloadStubClient(
            registry=registry,
            new_session_id="new-after-timeout",
            raise_timeout=True,
        ),
    )

    result = await editor_handlers.reload_plugin(runtime)

    assert result["new_session_id"] == "new-after-timeout"
    assert runtime.active_session_id == "new-after-timeout"

"""Tests for SessionRegistry."""

import asyncio

import pytest

from godot_ai.sessions.registry import Session, SessionRegistry


def _make_session(session_id: str = "test-001", **overrides) -> Session:
    defaults = {
        "session_id": session_id,
        "godot_version": "4.4.1",
        "project_path": "/tmp/test_project",
        "plugin_version": "0.0.1",
    }
    defaults.update(overrides)
    return Session(**defaults)


class TestSessionRegistry:
    def test_empty_registry(self):
        reg = SessionRegistry()
        assert len(reg) == 0
        assert reg.list_all() == []
        assert reg.get_active() is None

    def test_register_session(self):
        reg = SessionRegistry()
        s = _make_session()
        reg.register(s)

        assert len(reg) == 1
        assert reg.get("test-001") is s
        assert reg.get_active() is s

    def test_first_session_becomes_active(self):
        reg = SessionRegistry()
        reg.register(_make_session("a"))
        reg.register(_make_session("b"))

        assert reg.active_session_id == "a"

    def test_unregister_active_clears_active(self):
        ## Disconnect of the active session must NOT silently promote another
        ## session to active — that would route commands to whichever session
        ## was registered first, which is the 'multi-instance routing' bug.
        reg = SessionRegistry()
        reg.register(_make_session("a"))
        reg.register(_make_session("b"))
        reg.unregister("a")

        assert reg.active_session_id is None
        assert len(reg) == 1

    def test_unregister_non_active_leaves_active(self):
        reg = SessionRegistry()
        reg.register(_make_session("a"))
        reg.register(_make_session("b"))
        reg.unregister("b")

        assert reg.active_session_id == "a"
        assert len(reg) == 1

    def test_unregister_last_clears_active(self):
        reg = SessionRegistry()
        reg.register(_make_session("a"))
        reg.unregister("a")

        assert reg.active_session_id is None
        assert reg.get_active() is None

    def test_set_active(self):
        reg = SessionRegistry()
        reg.register(_make_session("a"))
        reg.register(_make_session("b"))
        reg.set_active("b")

        assert reg.active_session_id == "b"

    def test_set_active_unknown_raises(self):
        reg = SessionRegistry()
        with pytest.raises(KeyError):
            reg.set_active("nonexistent")

    def test_list_all(self):
        reg = SessionRegistry()
        reg.register(_make_session("a"))
        reg.register(_make_session("b"))

        sessions = reg.list_all()
        ids = {s.session_id for s in sessions}
        assert ids == {"a", "b"}

    def test_to_dict(self):
        s = _make_session()
        d = s.to_dict()
        assert d["session_id"] == "test-001"
        assert d["godot_version"] == "4.4.1"
        assert d["project_path"] == "/tmp/test_project"
        assert "connected_at" in d
        assert "last_seen" in d
        assert d["name"] == "test_project"
        assert d["editor_pid"] == 0

    def test_to_dict_includes_server_version(self):
        from godot_ai import __version__ as running_version

        s = _make_session()
        d = s.to_dict()
        assert d["server_version"] == running_version
        assert d["plugin_version"] == "0.0.1"

    def test_server_launch_mode_defaults_to_unknown(self):
        ## A legacy plugin that doesn't populate server_launch_mode lands
        ## as "unknown" — agents can detect this alongside plugin_version
        ## to tell "old plugin" from "mode not detectable on this system".
        s = _make_session()
        assert s.server_launch_mode == "unknown"
        assert s.to_dict()["server_launch_mode"] == "unknown"

    def test_server_launch_mode_round_trips_through_to_dict(self):
        s = _make_session(server_launch_mode="dev_venv")
        assert s.to_dict()["server_launch_mode"] == "dev_venv"


class TestSessionRegistryNoThreadingLock:
    """Guard against reintroducing a threading lock; this registry is asyncio-only."""

    def test_registry_has_no_lock_attribute(self):
        reg = SessionRegistry()
        assert not hasattr(reg, "_lock")

    def test_registry_module_does_not_import_threading(self):
        import godot_ai.sessions.registry as registry_module

        assert "threading" not in vars(registry_module)
        assert "RLock" not in vars(registry_module)


class TestSessionMetadata:
    def test_name_derived_from_project_path(self):
        s = _make_session(project_path="/Users/me/projects/my_game/")
        assert s.name == "my_game"

    def test_name_strips_trailing_slash(self):
        s = _make_session(project_path="/tmp/test_project")
        assert s.name == "test_project"

    def test_name_handles_windows_path(self):
        s = _make_session(project_path="C:\\Users\\me\\my_game\\")
        assert s.name == "my_game"

    def test_name_falls_back_to_session_id_prefix_when_path_empty(self):
        s = _make_session("abcdef1234567890", project_path="")
        assert s.name == "abcdef12"

    def test_editor_pid_defaults_to_zero(self):
        s = _make_session()
        assert s.editor_pid == 0

    def test_editor_pid_stored(self):
        s = _make_session(editor_pid=12345)
        assert s.editor_pid == 12345

    def test_touch_updates_last_seen(self):
        s = _make_session()
        original = s.last_seen
        ## busy-wait a tiny amount to guarantee timestamp delta
        import time

        time.sleep(0.001)
        s.touch()
        assert s.last_seen > original


class TestWaitForSession:
    async def test_resolves_immediately_if_session_already_registered(self):
        """Waiter installed before registration resolves as soon as session registers."""
        reg = SessionRegistry()
        s = _make_session("new-1")

        async def register_soon():
            await asyncio.sleep(0.05)
            reg.register(s)

        asyncio.create_task(register_soon())
        result = await reg.wait_for_session(timeout=2.0)
        assert result.session_id == "new-1"

    async def test_blocks_then_resolves(self):
        reg = SessionRegistry()

        async def register_later():
            await asyncio.sleep(0.1)
            reg.register(_make_session("delayed"))

        asyncio.create_task(register_later())
        result = await reg.wait_for_session(timeout=2.0)
        assert result.session_id == "delayed"

    async def test_timeout_raises(self):
        reg = SessionRegistry()
        with pytest.raises(TimeoutError, match="Timed out"):
            await reg.wait_for_session(timeout=0.1)

    async def test_ignores_excluded_id(self):
        reg = SessionRegistry()

        async def register_both():
            await asyncio.sleep(0.05)
            reg.register(_make_session("old-1"))  # excluded
            await asyncio.sleep(0.05)
            reg.register(_make_session("new-1"))  # should match

        asyncio.create_task(register_both())
        result = await reg.wait_for_session(exclude_id="old-1", timeout=2.0)
        assert result.session_id == "new-1"

    async def test_rechecks_registered_replacement_before_installing_waiter(self):
        reg = SessionRegistry()
        reg.register(_make_session("old-1", project_path="/tmp/test_project"))
        reg.register(_make_session("other-project", project_path="/tmp/other_project"))
        known_ids = {session.session_id for session in reg.list_all()}
        replacement = _make_session("new-1", project_path="/tmp/test_project")
        reg.register(replacement)

        result = await reg.wait_for_session(
            exclude_id="old-1",
            timeout=0.01,
            known_ids=known_ids,
            project_path="/tmp/test_project",
        )

        assert result is replacement
        assert reg._session_waiters == []

    async def test_concurrent_registers_and_activate_keep_registry_consistent(self):
        reg = SessionRegistry()
        waiter_task = asyncio.create_task(reg.wait_for_session(exclude_id="a", timeout=1.0))
        await asyncio.sleep(0)

        async def register_a():
            await asyncio.sleep(0)
            reg.register(_make_session("a"))

        async def register_b():
            await asyncio.sleep(0.001)
            reg.register(_make_session("b"))

        async def activate_b():
            for _ in range(100):
                if reg.get("b") is not None:
                    reg.set_active("b")
                    return
                await asyncio.sleep(0.001)
            raise AssertionError("session b was never registered")

        await asyncio.gather(register_a(), register_b(), activate_b())
        waited = await waiter_task

        assert waited.session_id == "b"
        assert reg.active_session_id == "b"
        assert {session.session_id for session in reg.list_all()} == {"a", "b"}
        assert len(reg) == 2
        assert reg._session_waiters == []

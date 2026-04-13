"""Unit tests for the direct runtime adapter and shared handlers."""

from __future__ import annotations

import pytest

from godot_ai.handlers import client as client_handlers
from godot_ai.handlers import editor as editor_handlers
from godot_ai.handlers import node as node_handlers
from godot_ai.handlers import project as project_handlers
from godot_ai.handlers import scene as scene_handlers
from godot_ai.handlers import session as session_handlers
from godot_ai.handlers import testing as testing_handlers
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
        if command == "get_editor_state":
            return {
                "current_scene": "res://main.tscn",
                "project_name": "TestProject",
                "is_playing": False,
                "godot_version": "4.4.1",
            }
        if command == "get_selection":
            return {"selected": ["/Main/Camera3D"]}
        if command == "get_scene_tree":
            return {
                "root": "Main",
                "nodes": [{"name": f"Node{i}", "type": "Node3D"} for i in range(3)],
            }
        if command == "get_open_scenes":
            return {"scenes": ["res://main.tscn"], "current": "res://main.tscn"}
        if command == "find_nodes":
            return {"nodes": [{"name": "Player", "type": "CharacterBody3D"}]}
        if command == "create_node":
            return {"path": "/Main/NewNode", "type": params.get("type", "Node")}
        if command == "get_node_properties":
            return {"properties": [{"name": "position", "value": "(0, 0, 0)"}]}
        if command == "get_children":
            return {"children": [{"name": "Child1", "type": "Node3D"}]}
        if command == "get_groups":
            return {"groups": ["enemies"]}
        if command == "delete_node":
            return {"path": params.get("path", ""), "undoable": True}
        if command == "reparent_node":
            return {
                "path": "/Main/World/" + params.get("path", "").split("/")[-1],
                "old_parent": "/Main",
                "new_parent": params.get("new_parent", ""),
                "undoable": True,
            }
        if command == "set_property":
            return {
                "path": params.get("path", ""),
                "property": params.get("property", ""),
                "value": params.get("value"),
                "old_value": "old",
                "undoable": True,
            }
        if command == "duplicate_node":
            return {
                "path": params.get("path", "") + "2",
                "original_path": params.get("path", ""),
                "name": params.get("name", "Dup"),
                "type": "Node3D",
                "undoable": True,
            }
        if command == "move_node":
            return {
                "path": params.get("path", ""),
                "old_index": 0,
                "new_index": params.get("index", 0),
                "undoable": True,
            }
        if command == "add_to_group":
            return {
                "path": params.get("path", ""),
                "group": params.get("group", ""),
                "undoable": True,
            }
        if command == "remove_from_group":
            return {
                "path": params.get("path", ""),
                "group": params.get("group", ""),
                "undoable": True,
            }
        if command == "set_selection":
            paths = params.get("paths", [])
            return {"selected": paths, "not_found": [], "count": len(paths)}
        if command == "create_scene":
            return {
                "path": params.get("path", ""),
                "root_type": params.get("root_type", "Node3D"),
                "root_name": "new_scene",
                "undoable": False,
            }
        if command == "open_scene":
            return {"path": params.get("path", ""), "undoable": False}
        if command == "save_scene":
            return {"path": "res://main.tscn", "undoable": False}
        if command == "save_scene_as":
            return {"path": params.get("path", ""), "undoable": False}
        if command == "search_filesystem":
            return {"files": [{"path": f"res://file_{i}.gd"} for i in range(3)]}
        if command == "run_tests":
            return {"passed": 5, "failed": 0, "results": []}
        if command == "get_test_results":
            return {"passed": 5, "failed": 0, "results": []}
        if command == "configure_client":
            return {"status": "ok", "client": params.get("client", "")}
        if command == "check_client_status":
            return {"claude_code": "configured", "codex": "not_configured"}
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


async def test_reload_plugin_raises_when_no_active_session():
    runtime = DirectRuntime(registry=SessionRegistry(), client=StubClient())
    with pytest.raises(ConnectionError, match="No active Godot session"):
        await editor_handlers.reload_plugin(runtime)


# ---------------------------------------------------------------------------
# Editor handler passthrough tests
# ---------------------------------------------------------------------------


async def test_editor_state_handler():
    client = StubClient()
    runtime = DirectRuntime(registry=SessionRegistry(), client=client)
    result = await editor_handlers.editor_state(runtime)
    assert result["project_name"] == "TestProject"
    assert client.calls[-1]["command"] == "get_editor_state"


async def test_editor_selection_get_handler():
    client = StubClient()
    runtime = DirectRuntime(registry=SessionRegistry(), client=client)
    result = await editor_handlers.editor_selection_get(runtime)
    assert result["selected"] == ["/Main/Camera3D"]


async def test_selection_resource_data_handler():
    runtime = DirectRuntime(registry=SessionRegistry(), client=StubClient())
    result = await editor_handlers.selection_resource_data(runtime)
    assert "selected" in result


async def test_logs_resource_data_handler():
    client = StubClient()
    runtime = DirectRuntime(registry=SessionRegistry(), client=client)
    result = await editor_handlers.logs_resource_data(runtime)
    assert "lines" in result
    assert client.calls[-1]["params"] == {"count": 100}


# ---------------------------------------------------------------------------
# Scene handler tests
# ---------------------------------------------------------------------------


async def test_scene_get_hierarchy_handler():
    runtime = DirectRuntime(registry=SessionRegistry(), client=StubClient())
    result = await scene_handlers.scene_get_hierarchy(runtime, depth=5, offset=0, limit=2)
    assert result["root"] == "Main"
    assert len(result["nodes"]) == 2
    assert result["total_count"] == 3
    assert result["has_more"] is True


async def test_scene_get_roots_handler():
    client = StubClient()
    runtime = DirectRuntime(registry=SessionRegistry(), client=client)
    result = await scene_handlers.scene_get_roots(runtime)
    assert result["scenes"] == ["res://main.tscn"]


async def test_current_scene_resource_data_handler():
    runtime = DirectRuntime(registry=SessionRegistry(), client=StubClient())
    result = await scene_handlers.current_scene_resource_data(runtime)
    assert result["current_scene"] == "res://main.tscn"
    assert result["project_name"] == "TestProject"
    assert result["is_playing"] is False


async def test_scene_hierarchy_resource_data_handler():
    runtime = DirectRuntime(registry=SessionRegistry(), client=StubClient())
    result = await scene_handlers.scene_hierarchy_resource_data(runtime)
    assert "nodes" in result


async def test_scene_create_handler():
    client = StubClient()
    runtime = DirectRuntime(registry=SessionRegistry(), client=client)
    result = await scene_handlers.scene_create(
        runtime, path="res://scenes/level.tscn", root_type="Node2D",
    )
    assert result["path"] == "res://scenes/level.tscn"
    assert result["root_type"] == "Node2D"
    assert client.calls[-1]["params"] == {"path": "res://scenes/level.tscn", "root_type": "Node2D"}


async def test_scene_create_handler_default_root_type():
    client = StubClient()
    runtime = DirectRuntime(registry=SessionRegistry(), client=client)
    result = await scene_handlers.scene_create(runtime, path="res://new.tscn")
    assert result["root_type"] == "Node3D"
    assert client.calls[-1]["params"] == {"path": "res://new.tscn", "root_type": "Node3D"}


async def test_scene_open_handler():
    client = StubClient()
    runtime = DirectRuntime(registry=SessionRegistry(), client=client)
    result = await scene_handlers.scene_open(runtime, path="res://main.tscn")
    assert result["path"] == "res://main.tscn"
    assert client.calls[-1]["params"] == {"path": "res://main.tscn"}


async def test_scene_save_handler():
    client = StubClient()
    runtime = DirectRuntime(registry=SessionRegistry(), client=client)
    result = await scene_handlers.scene_save(runtime)
    assert result["path"] == "res://main.tscn"
    assert client.calls[-1]["command"] == "save_scene"


async def test_scene_save_as_handler():
    client = StubClient()
    runtime = DirectRuntime(registry=SessionRegistry(), client=client)
    result = await scene_handlers.scene_save_as(runtime, path="res://copy.tscn")
    assert result["path"] == "res://copy.tscn"
    assert client.calls[-1]["params"] == {"path": "res://copy.tscn"}


# ---------------------------------------------------------------------------
# Node handler tests
# ---------------------------------------------------------------------------


async def test_node_create_handler():
    client = StubClient()
    runtime = DirectRuntime(registry=SessionRegistry(), client=client)
    result = await node_handlers.node_create(
        runtime, type="Sprite2D", name="MySprite", parent_path="/Main",
    )
    assert result["type"] == "Sprite2D"
    expected = {"type": "Sprite2D", "name": "MySprite", "parent_path": "/Main"}
    assert client.calls[-1]["params"] == expected


async def test_node_find_handler_paginates():
    runtime = DirectRuntime(registry=SessionRegistry(), client=StubClient())
    result = await node_handlers.node_find(runtime, name="Player", offset=0, limit=10)
    assert result["nodes"] == [{"name": "Player", "type": "CharacterBody3D"}]
    assert result["total_count"] == 1


async def test_node_get_properties_handler():
    client = StubClient()
    runtime = DirectRuntime(registry=SessionRegistry(), client=client)
    result = await node_handlers.node_get_properties(runtime, path="/Main/Camera3D")
    assert "properties" in result
    assert client.calls[-1]["params"] == {"path": "/Main/Camera3D"}


async def test_node_get_children_handler():
    client = StubClient()
    runtime = DirectRuntime(registry=SessionRegistry(), client=client)
    result = await node_handlers.node_get_children(runtime, path="/Main")
    assert result["children"] == [{"name": "Child1", "type": "Node3D"}]


async def test_node_get_groups_handler():
    client = StubClient()
    runtime = DirectRuntime(registry=SessionRegistry(), client=client)
    result = await node_handlers.node_get_groups(runtime, path="/Main/Enemy")
    assert result["groups"] == ["enemies"]


async def test_node_delete_handler():
    client = StubClient()
    runtime = DirectRuntime(registry=SessionRegistry(), client=client)
    result = await node_handlers.node_delete(runtime, path="/Main/Enemy")
    assert result["path"] == "/Main/Enemy"
    assert result["undoable"] is True
    assert client.calls[-1]["params"] == {"path": "/Main/Enemy"}


async def test_node_reparent_handler():
    client = StubClient()
    runtime = DirectRuntime(registry=SessionRegistry(), client=client)
    result = await node_handlers.node_reparent(
        runtime, path="/Main/Player", new_parent="/Main/World",
    )
    assert result["new_parent"] == "/Main/World"
    assert result["undoable"] is True
    assert client.calls[-1]["params"] == {"path": "/Main/Player", "new_parent": "/Main/World"}


async def test_node_set_property_handler():
    client = StubClient()
    runtime = DirectRuntime(registry=SessionRegistry(), client=client)
    result = await node_handlers.node_set_property(
        runtime, path="/Main/Camera3D", property="fov", value=90,
    )
    assert result["property"] == "fov"
    assert result["value"] == 90
    assert result["undoable"] is True


async def test_node_duplicate_handler():
    client = StubClient()
    runtime = DirectRuntime(registry=SessionRegistry(), client=client)
    result = await node_handlers.node_duplicate(
        runtime, path="/Main/Enemy", name="Enemy2",
    )
    assert result["original_path"] == "/Main/Enemy"
    assert result["name"] == "Enemy2"
    assert result["undoable"] is True
    assert client.calls[-1]["params"] == {"path": "/Main/Enemy", "name": "Enemy2"}


async def test_node_move_handler():
    client = StubClient()
    runtime = DirectRuntime(registry=SessionRegistry(), client=client)
    result = await node_handlers.node_move(runtime, path="/Main/Camera3D", index=2)
    assert result["new_index"] == 2
    assert result["undoable"] is True
    assert client.calls[-1]["params"] == {"path": "/Main/Camera3D", "index": 2}


async def test_node_add_to_group_handler():
    client = StubClient()
    runtime = DirectRuntime(registry=SessionRegistry(), client=client)
    result = await node_handlers.node_add_to_group(
        runtime, path="/Main/Enemy", group="damageable",
    )
    assert result["group"] == "damageable"
    assert result["undoable"] is True
    assert client.calls[-1]["params"] == {"path": "/Main/Enemy", "group": "damageable"}


async def test_node_remove_from_group_handler():
    client = StubClient()
    runtime = DirectRuntime(registry=SessionRegistry(), client=client)
    result = await node_handlers.node_remove_from_group(
        runtime, path="/Main/Enemy", group="enemies",
    )
    assert result["group"] == "enemies"
    assert result["undoable"] is True
    assert client.calls[-1]["params"] == {"path": "/Main/Enemy", "group": "enemies"}


async def test_editor_selection_set_handler():
    client = StubClient()
    runtime = DirectRuntime(registry=SessionRegistry(), client=client)
    result = await node_handlers.editor_selection_set(
        runtime, paths=["/Main/Camera3D", "/Main/World"],
    )
    assert result["selected"] == ["/Main/Camera3D", "/Main/World"]
    assert result["count"] == 2
    assert client.calls[-1]["params"] == {"paths": ["/Main/Camera3D", "/Main/World"]}


# ---------------------------------------------------------------------------
# Testing handler tests
# ---------------------------------------------------------------------------


async def test_run_tests_handler_with_no_params():
    client = StubClient()
    runtime = DirectRuntime(registry=SessionRegistry(), client=client)
    result = await testing_handlers.run_tests(runtime)
    assert result["passed"] == 5
    assert client.calls[-1]["params"] == {}


async def test_run_tests_handler_with_suite_and_test_name():
    client = StubClient()
    runtime = DirectRuntime(registry=SessionRegistry(), client=client)
    await testing_handlers.run_tests(runtime, suite="scene", test_name="test_tree")
    assert client.calls[-1]["params"] == {"suite": "scene", "test_name": "test_tree"}


async def test_get_test_results_handler():
    client = StubClient()
    runtime = DirectRuntime(registry=SessionRegistry(), client=client)
    result = await testing_handlers.get_test_results(runtime)
    assert result["passed"] == 5
    assert client.calls[-1]["command"] == "get_test_results"


# ---------------------------------------------------------------------------
# Client handler tests
# ---------------------------------------------------------------------------


async def test_client_configure_handler():
    client = StubClient()
    runtime = DirectRuntime(registry=SessionRegistry(), client=client)
    result = await client_handlers.client_configure(runtime, client="codex")
    assert result["client"] == "codex"
    assert client.calls[-1]["params"] == {"client": "codex"}


async def test_client_status_handler():
    client = StubClient()
    runtime = DirectRuntime(registry=SessionRegistry(), client=client)
    result = await client_handlers.client_status(runtime)
    assert result["claude_code"] == "configured"
    assert client.calls[-1]["command"] == "check_client_status"


# ---------------------------------------------------------------------------
# Session handler tests
# ---------------------------------------------------------------------------


def test_session_activate_handler_success():
    registry = SessionRegistry()
    registry.register(_make_session("a"))
    runtime = DirectRuntime(registry=registry, client=StubClient())
    result = session_handlers.session_activate(runtime, "a")
    assert result == {"status": "ok", "active_session_id": "a"}


def test_session_activate_handler_not_found():
    runtime = DirectRuntime(registry=SessionRegistry(), client=StubClient())
    result = session_handlers.session_activate(runtime, "nonexistent")
    assert result["status"] == "error"
    assert "not found" in result["message"]


def test_session_resource_data_delegates_to_session_list():
    registry = SessionRegistry()
    registry.register(_make_session("a"))
    runtime = DirectRuntime(registry=registry, client=StubClient())
    result = session_handlers.session_resource_data(runtime)
    assert result["count"] == 1
    assert result["sessions"][0]["session_id"] == "a"


# ---------------------------------------------------------------------------
# Project handler tests
# ---------------------------------------------------------------------------


def test_project_info_resource_data_with_active_session():
    registry = SessionRegistry()
    registry.register(_make_session("proj-1"))
    runtime = DirectRuntime(registry=registry, client=StubClient())
    result = project_handlers.project_info_resource_data(runtime)
    assert result["session_id"] == "proj-1"
    assert "connected_at" not in result


def test_project_info_resource_data_no_session():
    runtime = DirectRuntime(registry=SessionRegistry(), client=StubClient())
    result = project_handlers.project_info_resource_data(runtime)
    assert result["error"] == "No active Godot session"
    assert result["connected"] is False


async def test_filesystem_search_handler():
    client = StubClient()
    runtime = DirectRuntime(registry=SessionRegistry(), client=client)
    result = await project_handlers.filesystem_search(
        runtime, name="file", type="GDScript", path="res://", offset=0, limit=2,
    )
    assert len(result["files"]) == 2
    assert result["total_count"] == 3
    assert client.calls[-1]["params"] == {"name": "file", "type": "GDScript", "path": "res://"}


async def test_filesystem_search_handler_empty_params():
    client = StubClient()
    runtime = DirectRuntime(registry=SessionRegistry(), client=client)
    await project_handlers.filesystem_search(runtime)
    assert client.calls[-1]["params"] == {}


async def test_project_settings_resource_data_collects_errors():
    """When a setting fetch raises, the error is collected not propagated."""

    class FailingClient(StubClient):
        async def send(self, command, params=None, **kwargs):
            if command == "get_project_setting":
                key = params["key"] if params else ""
                if key == "application/config/name":
                    raise RuntimeError("connection lost")
            return await super().send(command, params, **kwargs)

    runtime = DirectRuntime(registry=SessionRegistry(), client=FailingClient())
    result = await project_handlers.project_settings_resource_data(runtime)
    assert result["errors"] is not None
    error_keys = [e["key"] for e in result["errors"]]
    assert "application/config/name" in error_keys
    # Other settings should still succeed
    assert len(result["settings"]) == len(project_handlers.COMMON_SETTINGS) - 1

"""Unit tests for the direct runtime adapter and shared handlers."""

from __future__ import annotations

import pytest

from godot_ai.handlers import autoload as autoload_handlers
from godot_ai.handlers import client as client_handlers
from godot_ai.handlers import editor as editor_handlers
from godot_ai.handlers import filesystem as filesystem_handlers
from godot_ai.handlers import input_map as input_map_handlers
from godot_ai.handlers import node as node_handlers
from godot_ai.handlers import project as project_handlers
from godot_ai.handlers import resource as resource_handlers
from godot_ai.handlers import scene as scene_handlers
from godot_ai.handlers import script as script_handlers
from godot_ai.handlers import session as session_handlers
from godot_ai.handlers import signal as signal_handlers
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
        if command == "quit_editor":
            return {"status": "quitting", "message": "Editor quit initiated"}
        if command == "get_logs":
            return {"lines": [f"line {i}" for i in range(6)]}
        if command == "get_project_setting":
            key = params["key"] if params else ""
            return {"key": key, "value": f"value:{key}"}
        if command == "set_project_setting":
            key = params.get("key", "")
            value = params.get("value")
            return {
                "key": key,
                "value": value,
                "old_value": None,
                "type": type(value).__name__,
                "undoable": False,
            }
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
            return {
                "passed": 5,
                "failed": 0,
                "total": 5,
                "duration_ms": 12,
                "suites_run": ["scene", "node"],
                "suite_count": 2,
            }
        if command == "get_test_results":
            return {
                "passed": 5,
                "failed": 0,
                "total": 5,
                "duration_ms": 12,
                "suites_run": ["scene", "node"],
                "suite_count": 2,
            }
        if command == "configure_client":
            return {"status": "ok", "client": params.get("client", "")}
        if command == "check_client_status":
            return {"claude_code": "configured", "codex": "not_configured"}
        if command == "create_script":
            return {
                "path": params.get("path", ""),
                "size": len(params.get("content", "")),
                "undoable": False,
            }
        if command == "read_script":
            return {
                "path": params.get("path", ""),
                "content": "extends Node\n",
                "size": 14,
                "line_count": 2,
            }
        if command == "attach_script":
            return {
                "path": params.get("path", ""),
                "script_path": params.get("script_path", ""),
                "had_previous_script": False,
                "undoable": True,
            }
        if command == "detach_script":
            return {
                "path": params.get("path", ""),
                "removed_script": "res://old.gd",
                "undoable": True,
            }
        if command == "find_symbols":
            return {
                "path": params.get("path", ""),
                "class_name": "MyClass",
                "extends": "Node3D",
                "functions": [{"name": "_ready", "line": 5}],
                "signals": ["died"],
                "exports": [{"name": "speed", "line": 3}],
                "function_count": 1,
                "signal_count": 1,
                "export_count": 1,
            }
        if command == "search_resources":
            return {
                "resources": [
                    {"path": f"res://resource_{i}.tres", "type": "Material"} for i in range(4)
                ]
            }
        if command == "load_resource":
            return {
                "path": params.get("path", ""),
                "type": "StandardMaterial3D",
                "properties": [
                    {
                        "name": "albedo_color",
                        "type": "Color",
                        "value": {"r": 1, "g": 1, "b": 1, "a": 1},
                    }
                ],
                "property_count": 1,
            }
        if command == "assign_resource":
            return {
                "path": params.get("path", ""),
                "property": params.get("property", ""),
                "resource_path": params.get("resource_path", ""),
                "resource_type": "StandardMaterial3D",
                "undoable": True,
            }
        if command == "read_file":
            return {
                "path": params.get("path", ""),
                "content": "[gd_scene]\n",
                "size": 11,
                "line_count": 2,
            }
        if command == "write_file":
            return {
                "path": params.get("path", ""),
                "size": len(params.get("content", "")),
                "undoable": False,
            }
        if command == "reimport":
            paths = params.get("paths", [])
            return {
                "reimported": paths,
                "not_found": [],
                "reimported_count": len(paths),
                "not_found_count": 0,
                "undoable": False,
            }
        if command == "list_signals":
            return {
                "path": params.get("path", ""),
                "signals": [
                    {"name": "ready", "args": []},
                    {"name": "tree_entered", "args": []},
                ],
                "signal_count": 2,
                "connections": [],
                "connection_count": 0,
            }
        if command == "connect_signal":
            return {
                "source": params.get("path", ""),
                "signal": params.get("signal", ""),
                "target": params.get("target", ""),
                "method": params.get("method", ""),
                "undoable": True,
            }
        if command == "disconnect_signal":
            return {
                "source": params.get("path", ""),
                "signal": params.get("signal", ""),
                "target": params.get("target", ""),
                "method": params.get("method", ""),
                "undoable": True,
            }
        if command == "list_autoloads":
            return {
                "autoloads": [
                    {
                        "name": "GameManager",
                        "path": "res://autoloads/game_manager.gd",
                        "singleton": True,
                    },
                ],
                "count": 1,
            }
        if command == "add_autoload":
            return {
                "name": params.get("name", ""),
                "path": params.get("path", ""),
                "singleton": params.get("singleton", True),
                "undoable": False,
            }
        if command == "remove_autoload":
            return {
                "name": params.get("name", ""),
                "removed": True,
                "undoable": False,
            }
        if command == "list_actions":
            return {
                "actions": [
                    {"name": "ui_accept", "events": [], "event_count": 0, "is_builtin": True},
                    {"name": "jump", "events": [], "event_count": 0, "is_builtin": False},
                ],
                "count": 2,
            }
        if command == "add_action":
            return {
                "action": params.get("action", ""),
                "deadzone": params.get("deadzone", 0.5),
                "undoable": False,
            }
        if command == "remove_action":
            return {
                "action": params.get("action", ""),
                "removed": True,
                "undoable": False,
            }
        if command == "bind_event":
            return {
                "action": params.get("action", ""),
                "event": {
                    "type": params.get("event_type", ""),
                    "keycode": params.get("keycode", ""),
                },
                "undoable": False,
            }
        if command == "take_screenshot":
            # 1x1 red PNG as base64
            import base64

            one_px_png = (
                b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01"
                b"\x00\x00\x00\x01\x08\x02\x00\x00\x00\x90wS\xde\x00"
                b"\x00\x00\x0cIDATx\x9cc\xf8\x0f\x00\x00\x01\x01\x00"
                b"\x05\x18\xd8N\x00\x00\x00\x00IEND\xaeB`\x82"
            )
            img_b64 = base64.b64encode(one_px_png).decode()

            # Coverage response: return 2 reference shots (establishing + top)
            if params.get("coverage") and params.get("view_target"):
                presets = [
                    {"label": "establishing", "elevation": 25.0,
                     "azimuth": 20.0, "fov": 50.0, "ortho": False},
                    {"label": "top", "elevation": 90.0, "azimuth": 0.0,
                     "fov": 0.0, "ortho": True},
                ]
                images = []
                for p in presets:
                    images.append({
                        "source": "viewport",
                        "width": 1,
                        "height": 1,
                        "original_width": 100,
                        "original_height": 100,
                        "format": "png",
                        "image_base64": img_b64,
                        **p,
                    })
                result = {
                    "source": "viewport",
                    "view_target": params["view_target"],
                    "view_target_count": len(
                        {
                            pt.strip()
                            for pt in params["view_target"].split(",")
                            if pt.strip()
                        }
                    ),
                    "coverage": True,
                    "images": images,
                    "aabb_center": [1.0, 0.5, 0.0],
                    "aabb_size": [3.0, 2.0, 2.0],
                    "aabb_longest_ground_axis": "x",
                }
                return result

            result = {
                "source": params.get("source", "viewport"),
                "width": 1,
                "height": 1,
                "original_width": 100,
                "original_height": 100,
                "format": "png",
                "image_base64": img_b64,
            }
            if params.get("view_target"):
                result["view_target"] = params["view_target"]
                result["view_target_count"] = len(
                    {
                        p.strip()
                        for p in params["view_target"].split(",")
                        if p.strip()
                    }
                )
                result["aabb_center"] = [1.0, 0.5, 0.0]
                result["aabb_size"] = [3.0, 2.0, 2.0]
                result["aabb_longest_ground_axis"] = "x"
            # Pass through angle/fov if provided
            if "elevation" in params:
                result["elevation"] = params["elevation"]
            if "azimuth" in params:
                result["azimuth"] = params["azimuth"]
            if "fov" in params:
                result["fov"] = params["fov"]
            return result
        if command == "clear_logs":
            return {"cleared_count": 5}
        if command == "run_project":
            return {
                "mode": params.get("mode", "main"),
                "scene": params.get("scene", ""),
                "undoable": False,
            }
        if command == "stop_project":
            return {"stopped": True, "undoable": False}
        if command == "get_performance_monitors":
            return {
                "monitors": {
                    "time/fps": 60.0,
                    "time/process": 0.001,
                    "memory/static": 1048576,
                },
                "monitor_count": 3,
            }
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


async def test_editor_quit_handler():
    client = StubClient()
    runtime = DirectRuntime(registry=SessionRegistry(), client=client)
    result = await editor_handlers.editor_quit(runtime)
    assert result["status"] == "quitting"
    assert client.calls[-1]["command"] == "quit_editor"


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
        runtime,
        path="res://scenes/level.tscn",
        root_type="Node2D",
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
        runtime,
        type="Sprite2D",
        name="MySprite",
        parent_path="/Main",
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
        runtime,
        path="/Main/Player",
        new_parent="/Main/World",
    )
    assert result["new_parent"] == "/Main/World"
    assert result["undoable"] is True
    assert client.calls[-1]["params"] == {"path": "/Main/Player", "new_parent": "/Main/World"}


async def test_node_set_property_handler():
    client = StubClient()
    runtime = DirectRuntime(registry=SessionRegistry(), client=client)
    result = await node_handlers.node_set_property(
        runtime,
        path="/Main/Camera3D",
        property="fov",
        value=90,
    )
    assert result["property"] == "fov"
    assert result["value"] == 90
    assert result["undoable"] is True


async def test_node_duplicate_handler():
    client = StubClient()
    runtime = DirectRuntime(registry=SessionRegistry(), client=client)
    result = await node_handlers.node_duplicate(
        runtime,
        path="/Main/Enemy",
        name="Enemy2",
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
        runtime,
        path="/Main/Enemy",
        group="damageable",
    )
    assert result["group"] == "damageable"
    assert result["undoable"] is True
    assert client.calls[-1]["params"] == {"path": "/Main/Enemy", "group": "damageable"}


async def test_node_remove_from_group_handler():
    client = StubClient()
    runtime = DirectRuntime(registry=SessionRegistry(), client=client)
    result = await node_handlers.node_remove_from_group(
        runtime,
        path="/Main/Enemy",
        group="enemies",
    )
    assert result["group"] == "enemies"
    assert result["undoable"] is True
    assert client.calls[-1]["params"] == {"path": "/Main/Enemy", "group": "enemies"}


async def test_editor_selection_set_handler():
    client = StubClient()
    runtime = DirectRuntime(registry=SessionRegistry(), client=client)
    result = await node_handlers.editor_selection_set(
        runtime,
        paths=["/Main/Camera3D", "/Main/World"],
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


async def test_run_tests_handler_verbose():
    client = StubClient()
    runtime = DirectRuntime(registry=SessionRegistry(), client=client)
    await testing_handlers.run_tests(runtime, verbose=True)
    assert client.calls[-1]["params"] == {"verbose": True}


async def test_get_test_results_handler_verbose():
    client = StubClient()
    runtime = DirectRuntime(registry=SessionRegistry(), client=client)
    await testing_handlers.get_test_results(runtime, verbose=True)
    assert client.calls[-1]["params"] == {"verbose": True}


async def test_input_map_list_handler_with_include_builtin():
    client = StubClient()
    runtime = DirectRuntime(registry=SessionRegistry(), client=client)
    await input_map_handlers.input_map_list(runtime, include_builtin=True)
    assert client.calls[-1]["params"] == {"include_builtin": True}


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
        runtime,
        name="file",
        type="GDScript",
        path="res://",
        offset=0,
        limit=2,
    )
    assert len(result["files"]) == 2
    assert result["total_count"] == 3
    assert client.calls[-1]["params"] == {"name": "file", "type": "GDScript", "path": "res://"}


async def test_project_settings_set_handler():
    client = StubClient()
    runtime = DirectRuntime(registry=SessionRegistry(), client=client)
    result = await project_handlers.project_settings_set(
        runtime, key="display/window/size/viewport_width", value=1920
    )
    assert result["key"] == "display/window/size/viewport_width"
    assert result["value"] == 1920
    assert client.calls[-1]["command"] == "set_project_setting"
    assert client.calls[-1]["params"] == {
        "key": "display/window/size/viewport_width",
        "value": 1920,
    }


# ---------------------------------------------------------------------------
# Script handler tests
# ---------------------------------------------------------------------------


async def test_script_create_handler():
    client = StubClient()
    runtime = DirectRuntime(registry=SessionRegistry(), client=client)
    result = await script_handlers.script_create(
        runtime,
        path="res://scripts/player.gd",
        content="extends Node3D\n",
    )
    assert result["path"] == "res://scripts/player.gd"
    assert result["undoable"] is False
    assert client.calls[-1]["params"] == {
        "path": "res://scripts/player.gd",
        "content": "extends Node3D\n",
    }


async def test_script_read_handler():
    client = StubClient()
    runtime = DirectRuntime(registry=SessionRegistry(), client=client)
    result = await script_handlers.script_read(runtime, path="res://scripts/player.gd")
    assert result["content"] == "extends Node\n"
    assert client.calls[-1]["params"] == {"path": "res://scripts/player.gd"}


async def test_script_attach_handler():
    client = StubClient()
    runtime = DirectRuntime(registry=SessionRegistry(), client=client)
    result = await script_handlers.script_attach(
        runtime,
        path="/Main/Player",
        script_path="res://scripts/player.gd",
    )
    assert result["script_path"] == "res://scripts/player.gd"
    assert result["undoable"] is True
    assert client.calls[-1]["params"] == {
        "path": "/Main/Player",
        "script_path": "res://scripts/player.gd",
    }


async def test_script_detach_handler():
    client = StubClient()
    runtime = DirectRuntime(registry=SessionRegistry(), client=client)
    result = await script_handlers.script_detach(runtime, path="/Main/Player")
    assert result["removed_script"] == "res://old.gd"
    assert result["undoable"] is True
    assert client.calls[-1]["params"] == {"path": "/Main/Player"}


async def test_script_find_symbols_handler():
    client = StubClient()
    runtime = DirectRuntime(registry=SessionRegistry(), client=client)
    result = await script_handlers.script_find_symbols(
        runtime,
        path="res://scripts/player.gd",
    )
    assert result["class_name"] == "MyClass"
    assert result["function_count"] == 1
    assert result["functions"][0]["name"] == "_ready"
    assert client.calls[-1]["params"] == {"path": "res://scripts/player.gd"}


# ---------------------------------------------------------------------------
# Resource handler tests
# ---------------------------------------------------------------------------


async def test_resource_search_handler_paginates():
    client = StubClient()
    runtime = DirectRuntime(registry=SessionRegistry(), client=client)
    result = await resource_handlers.resource_search(
        runtime,
        type="Material",
        offset=1,
        limit=2,
    )
    assert len(result["resources"]) == 2
    assert result["total_count"] == 4
    assert result["has_more"] is True
    assert client.calls[-1]["params"] == {"type": "Material", "path": ""}


async def test_resource_load_handler():
    client = StubClient()
    runtime = DirectRuntime(registry=SessionRegistry(), client=client)
    result = await resource_handlers.resource_load(runtime, path="res://mat.tres")
    assert result["type"] == "StandardMaterial3D"
    assert result["property_count"] == 1
    assert client.calls[-1]["params"] == {"path": "res://mat.tres"}


async def test_resource_assign_handler():
    client = StubClient()
    runtime = DirectRuntime(registry=SessionRegistry(), client=client)
    result = await resource_handlers.resource_assign(
        runtime,
        path="/Main/Ground",
        property="mesh",
        resource_path="res://cube.tres",
    )
    assert result["resource_type"] == "StandardMaterial3D"
    assert result["undoable"] is True
    assert client.calls[-1]["params"] == {
        "path": "/Main/Ground",
        "property": "mesh",
        "resource_path": "res://cube.tres",
    }


# ---------------------------------------------------------------------------
# Filesystem handler tests
# ---------------------------------------------------------------------------


async def test_filesystem_read_text_handler():
    client = StubClient()
    runtime = DirectRuntime(registry=SessionRegistry(), client=client)
    result = await filesystem_handlers.filesystem_read_text(
        runtime,
        path="res://project.godot",
    )
    assert result["content"] == "[gd_scene]\n"
    assert result["size"] == 11
    assert client.calls[-1]["params"] == {"path": "res://project.godot"}


async def test_filesystem_write_text_handler():
    client = StubClient()
    runtime = DirectRuntime(registry=SessionRegistry(), client=client)
    result = await filesystem_handlers.filesystem_write_text(
        runtime,
        path="res://data/config.json",
        content='{"key": "val"}',
    )
    assert result["path"] == "res://data/config.json"
    assert result["undoable"] is False
    assert client.calls[-1]["params"] == {
        "path": "res://data/config.json",
        "content": '{"key": "val"}',
    }


async def test_import_reimport_handler():
    client = StubClient()
    runtime = DirectRuntime(registry=SessionRegistry(), client=client)
    result = await filesystem_handlers.import_reimport(
        runtime,
        paths=["res://icon.png", "res://logo.png"],
    )
    assert result["reimported_count"] == 2
    assert result["reimported"] == ["res://icon.png", "res://logo.png"]
    assert client.calls[-1]["params"] == {"paths": ["res://icon.png", "res://logo.png"]}


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


# ---------------------------------------------------------------------------
# Signal handler tests
# ---------------------------------------------------------------------------


async def test_signal_list_handler():
    client = StubClient()
    runtime = DirectRuntime(registry=SessionRegistry(), client=client)
    result = await signal_handlers.signal_list(runtime, path="/Main/Player")
    assert result["signal_count"] == 2
    assert result["signals"][0]["name"] == "ready"
    assert client.calls[-1]["command"] == "list_signals"
    assert client.calls[-1]["params"] == {"path": "/Main/Player"}


async def test_signal_connect_handler():
    client = StubClient()
    runtime = DirectRuntime(registry=SessionRegistry(), client=client)
    result = await signal_handlers.signal_connect(
        runtime,
        path="/Main/Button",
        signal="pressed",
        target="/Main/Player",
        method="_on_button_pressed",
    )
    assert result["signal"] == "pressed"
    assert result["undoable"] is True
    assert client.calls[-1]["command"] == "connect_signal"


async def test_signal_disconnect_handler():
    client = StubClient()
    runtime = DirectRuntime(registry=SessionRegistry(), client=client)
    result = await signal_handlers.signal_disconnect(
        runtime,
        path="/Main/Button",
        signal="pressed",
        target="/Main/Player",
        method="_on_button_pressed",
    )
    assert result["signal"] == "pressed"
    assert result["undoable"] is True
    assert client.calls[-1]["command"] == "disconnect_signal"


# ---------------------------------------------------------------------------
# Autoload handler tests
# ---------------------------------------------------------------------------


async def test_autoload_list_handler():
    client = StubClient()
    runtime = DirectRuntime(registry=SessionRegistry(), client=client)
    result = await autoload_handlers.autoload_list(runtime)
    assert result["count"] == 1
    assert result["autoloads"][0]["name"] == "GameManager"
    assert client.calls[-1]["command"] == "list_autoloads"


async def test_autoload_add_handler():
    client = StubClient()
    runtime = DirectRuntime(registry=SessionRegistry(), client=client)
    result = await autoload_handlers.autoload_add(
        runtime, name="AudioBus", path="res://autoloads/audio_bus.gd"
    )
    assert result["name"] == "AudioBus"
    assert result["path"] == "res://autoloads/audio_bus.gd"
    assert client.calls[-1]["command"] == "add_autoload"


async def test_autoload_remove_handler():
    client = StubClient()
    runtime = DirectRuntime(registry=SessionRegistry(), client=client)
    result = await autoload_handlers.autoload_remove(runtime, name="GameManager")
    assert result["name"] == "GameManager"
    assert result["removed"] is True
    assert client.calls[-1]["command"] == "remove_autoload"


# ---------------------------------------------------------------------------
# Input map handler tests
# ---------------------------------------------------------------------------


async def test_input_map_list_handler():
    client = StubClient()
    runtime = DirectRuntime(registry=SessionRegistry(), client=client)
    result = await input_map_handlers.input_map_list(runtime)
    assert result["count"] == 2
    assert result["actions"][0]["name"] == "ui_accept"
    assert client.calls[-1]["command"] == "list_actions"


async def test_input_map_add_action_handler():
    client = StubClient()
    runtime = DirectRuntime(registry=SessionRegistry(), client=client)
    result = await input_map_handlers.input_map_add_action(
        runtime, action="jump", deadzone=0.3
    )
    assert result["action"] == "jump"
    assert result["deadzone"] == 0.3
    assert client.calls[-1]["command"] == "add_action"


async def test_input_map_remove_action_handler():
    client = StubClient()
    runtime = DirectRuntime(registry=SessionRegistry(), client=client)
    result = await input_map_handlers.input_map_remove_action(runtime, action="jump")
    assert result["action"] == "jump"
    assert result["removed"] is True
    assert client.calls[-1]["command"] == "remove_action"


async def test_input_map_bind_event_handler():
    client = StubClient()
    runtime = DirectRuntime(registry=SessionRegistry(), client=client)
    result = await input_map_handlers.input_map_bind_event(
        runtime, action="jump", event_type="key", keycode="Space"
    )
    assert result["action"] == "jump"
    assert result["event"]["type"] == "key"
    assert client.calls[-1]["command"] == "bind_event"
    assert client.calls[-1]["params"]["keycode"] == "Space"


# ---------------------------------------------------------------------------
# Logs clear handler tests
# ---------------------------------------------------------------------------


async def test_logs_clear_handler():
    client = StubClient()
    runtime = DirectRuntime(registry=SessionRegistry(), client=client)
    result = await editor_handlers.logs_clear(runtime)
    assert result["cleared_count"] == 5
    assert client.calls[-1]["command"] == "clear_logs"


# ---------------------------------------------------------------------------
# Project run/stop handler tests
# ---------------------------------------------------------------------------


async def test_project_run_handler_default_mode():
    client = StubClient()
    runtime = DirectRuntime(registry=SessionRegistry(), client=client)
    result = await project_handlers.project_run(runtime)
    assert result["mode"] == "main"
    assert client.calls[-1]["command"] == "run_project"
    assert client.calls[-1]["params"] == {"mode": "main"}


async def test_project_run_handler_current_mode():
    client = StubClient()
    runtime = DirectRuntime(registry=SessionRegistry(), client=client)
    result = await project_handlers.project_run(runtime, mode="current")
    assert result["mode"] == "current"
    assert client.calls[-1]["params"] == {"mode": "current"}


async def test_project_run_handler_custom_mode():
    client = StubClient()
    runtime = DirectRuntime(registry=SessionRegistry(), client=client)
    result = await project_handlers.project_run(
        runtime, mode="custom", scene="res://levels/level1.tscn"
    )
    assert result["mode"] == "custom"
    assert client.calls[-1]["params"] == {
        "mode": "custom",
        "scene": "res://levels/level1.tscn",
    }


async def test_project_stop_handler():
    client = StubClient()
    runtime = DirectRuntime(registry=SessionRegistry(), client=client)
    result = await project_handlers.project_stop(runtime)
    assert result["stopped"] is True
    assert client.calls[-1]["command"] == "stop_project"


# ---------------------------------------------------------------------------
# Performance monitor handler tests
# ---------------------------------------------------------------------------


# ---------------------------------------------------------------------------
# Screenshot handler tests
# ---------------------------------------------------------------------------


async def test_editor_screenshot_handler_with_image():
    client = StubClient()
    runtime = DirectRuntime(registry=SessionRegistry(), client=client)
    result = await editor_handlers.editor_screenshot(runtime, include_image=True)
    # Returns a list of [TextContent, McpImage]
    assert isinstance(result, list)
    assert len(result) == 2
    assert result[0].type == "text"
    assert client.calls[-1]["command"] == "take_screenshot"


async def test_editor_screenshot_handler_without_image():
    client = StubClient()
    runtime = DirectRuntime(registry=SessionRegistry(), client=client)
    result = await editor_handlers.editor_screenshot(runtime, include_image=False)
    # Returns just metadata dict
    assert isinstance(result, dict)
    assert result["source"] == "viewport"
    assert result["width"] == 1
    assert result["original_width"] == 100
    assert "image_base64" not in result


async def test_editor_screenshot_handler_passes_source():
    client = StubClient()
    runtime = DirectRuntime(registry=SessionRegistry(), client=client)
    await editor_handlers.editor_screenshot(
        runtime, source="game", include_image=False
    )
    assert client.calls[-1]["params"]["source"] == "game"


async def test_editor_screenshot_handler_passes_max_resolution():
    client = StubClient()
    runtime = DirectRuntime(registry=SessionRegistry(), client=client)
    await editor_handlers.editor_screenshot(
        runtime, max_resolution=1024, include_image=False
    )
    assert client.calls[-1]["params"]["max_resolution"] == 1024


async def test_editor_screenshot_handler_passes_view_target():
    client = StubClient()
    runtime = DirectRuntime(registry=SessionRegistry(), client=client)
    result = await editor_handlers.editor_screenshot(
        runtime, view_target="/Main/MyCube", include_image=False
    )
    assert client.calls[-1]["params"]["view_target"] == "/Main/MyCube"
    assert result["view_target"] == "/Main/MyCube"
    assert result["view_target_count"] == 1
    # AABB metadata always included for view_target responses
    assert result["aabb_center"] == [1.0, 0.5, 0.0]
    assert result["aabb_size"] == [3.0, 2.0, 2.0]
    assert result["aabb_longest_ground_axis"] == "x"


async def test_editor_screenshot_handler_omits_view_target_when_empty():
    client = StubClient()
    runtime = DirectRuntime(registry=SessionRegistry(), client=client)
    result = await editor_handlers.editor_screenshot(runtime, include_image=False)
    assert "view_target" not in client.calls[-1]["params"]
    assert "view_target" not in result


async def test_editor_screenshot_handler_passes_comma_view_target():
    client = StubClient()
    runtime = DirectRuntime(registry=SessionRegistry(), client=client)
    result = await editor_handlers.editor_screenshot(
        runtime, view_target="/Main/A,/Main/B", include_image=False
    )
    assert client.calls[-1]["params"]["view_target"] == "/Main/A,/Main/B"
    assert result["view_target"] == "/Main/A,/Main/B"
    assert result["view_target_count"] == 2


async def test_editor_screenshot_handler_coverage_passes_param():
    client = StubClient()
    runtime = DirectRuntime(registry=SessionRegistry(), client=client)
    await editor_handlers.editor_screenshot(
        runtime, view_target="/Main/X", coverage=True, include_image=False
    )
    assert client.calls[-1]["params"]["coverage"] is True
    assert client.calls[-1]["params"]["view_target"] == "/Main/X"


async def test_editor_screenshot_handler_coverage_multi_image():
    client = StubClient()
    runtime = DirectRuntime(registry=SessionRegistry(), client=client)
    result = await editor_handlers.editor_screenshot(
        runtime, view_target="/Main/X", coverage=True, include_image=True
    )
    # 1 text metadata + 2 images
    assert isinstance(result, list)
    assert len(result) == 3
    assert result[0].type == "text"
    import json

    meta = json.loads(result[0].text)
    assert meta["coverage"] is True
    assert meta["image_count"] == 2
    assert len(meta["images"]) == 2
    assert meta["images"][0]["label"] == "establishing"
    assert meta["images"][1]["label"] == "top"
    assert meta["images"][1].get("ortho") is True
    assert meta["aabb_center"] == [1.0, 0.5, 0.0]
    assert meta["aabb_size"] == [3.0, 2.0, 2.0]
    assert meta["aabb_longest_ground_axis"] == "x"


async def test_editor_screenshot_handler_coverage_no_image():
    client = StubClient()
    runtime = DirectRuntime(registry=SessionRegistry(), client=client)
    result = await editor_handlers.editor_screenshot(
        runtime, view_target="/Main/X", coverage=True, include_image=False
    )
    assert isinstance(result, dict)
    assert result["coverage"] is True
    assert result["image_count"] == 2
    assert len(result["images"]) == 2
    assert "image_base64" not in result
    assert "aabb_center" in result
    assert "aabb_size" in result
    assert "aabb_longest_ground_axis" in result


async def test_editor_screenshot_handler_custom_angles():
    client = StubClient()
    runtime = DirectRuntime(registry=SessionRegistry(), client=client)
    result = await editor_handlers.editor_screenshot(
        runtime,
        view_target="/Main/X",
        elevation=45.0,
        azimuth=90.0,
        include_image=False,
    )
    assert client.calls[-1]["params"]["elevation"] == 45.0
    assert client.calls[-1]["params"]["azimuth"] == 90.0
    assert result["elevation"] == 45.0
    assert result["azimuth"] == 90.0


async def test_editor_screenshot_handler_view_target_not_found_single():
    class NotFoundClient:
        async def send(self, command, params=None, session_id=None, timeout=5.0):
            return {
                "source": "viewport",
                "width": 1,
                "height": 1,
                "original_width": 100,
                "original_height": 100,
                "format": "png",
                "image_base64": "",
                "view_target": params["view_target"],
                "view_target_count": 2,
                "view_target_not_found": ["/Main/Missing"],
            }

    runtime = DirectRuntime(registry=SessionRegistry(), client=NotFoundClient())
    result = await editor_handlers.editor_screenshot(
        runtime, view_target="/Main/X,/Main/Missing", include_image=False
    )
    assert result["view_target_not_found"] == ["/Main/Missing"]
    assert result["view_target_count"] == 2


async def test_editor_screenshot_handler_view_target_not_found_coverage():
    class NotFoundCoverageClient:
        async def send(self, command, params=None, session_id=None, timeout=5.0):
            return {
                "source": "viewport",
                "view_target": params["view_target"],
                "view_target_count": 2,
                "view_target_not_found": ["/Main/Missing"],
                "coverage": True,
                "images": [
                    {
                        "label": "establishing",
                        "elevation": 25.0,
                        "azimuth": 20.0,
                        "fov": 50.0,
                        "width": 1,
                        "height": 1,
                        "image_base64": "",
                        "format": "png",
                    }
                ],
            }

    runtime = DirectRuntime(
        registry=SessionRegistry(), client=NotFoundCoverageClient()
    )
    result = await editor_handlers.editor_screenshot(
        runtime,
        view_target="/Main/X,/Main/Missing",
        coverage=True,
        include_image=False,
    )
    assert result["view_target_not_found"] == ["/Main/Missing"]
    assert result["view_target_count"] == 2
    assert result["coverage"] is True


async def test_editor_screenshot_handler_fov_passes_param():
    client = StubClient()
    runtime = DirectRuntime(registry=SessionRegistry(), client=client)
    result = await editor_handlers.editor_screenshot(
        runtime,
        view_target="/Main/X",
        fov=30.0,
        include_image=False,
    )
    assert client.calls[-1]["params"]["fov"] == 30.0
    assert result["fov"] == 30.0


# ---------------------------------------------------------------------------
# Performance monitor handler tests
# ---------------------------------------------------------------------------


async def test_performance_get_monitors_handler_all():
    client = StubClient()
    runtime = DirectRuntime(registry=SessionRegistry(), client=client)
    result = await editor_handlers.performance_get_monitors(runtime)
    assert result["monitor_count"] == 3
    assert result["monitors"]["time/fps"] == 60.0
    assert client.calls[-1]["command"] == "get_performance_monitors"
    assert client.calls[-1]["params"] == {}


async def test_performance_get_monitors_handler_filtered():
    client = StubClient()
    runtime = DirectRuntime(registry=SessionRegistry(), client=client)
    await editor_handlers.performance_get_monitors(runtime, monitors=["time/fps"])
    assert client.calls[-1]["params"] == {"monitors": ["time/fps"]}

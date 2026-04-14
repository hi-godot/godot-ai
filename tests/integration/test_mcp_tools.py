"""Integration tests: MCP tools through the full FastMCP stack with mock Godot plugin."""

from __future__ import annotations

import asyncio
import json

import websockets

# ---------------------------------------------------------------------------
# scene_get_hierarchy
# ---------------------------------------------------------------------------


class TestSceneGetHierarchyTool:
    async def test_returns_paginated_nodes(self, mcp_stack):
        client, plugin = mcp_stack
        nodes = [{"name": f"Node{i}", "type": "Node3D", "path": f"/Root/Node{i}"} for i in range(5)]

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "get_scene_tree"
            await plugin.send_response(cmd["request_id"], {"root": "Root", "nodes": nodes})

        task = asyncio.create_task(respond())
        result = await client.call_tool(
            "scene_get_hierarchy", {"depth": 10, "offset": 1, "limit": 2}
        )
        await task

        data = result.data
        assert len(data["nodes"]) == 2
        assert data["nodes"][0]["name"] == "Node1"
        assert data["total_count"] == 5
        assert data["has_more"] is True
        assert data["offset"] == 1
        assert data["limit"] == 2

    async def test_last_page_has_more_false(self, mcp_stack):
        client, plugin = mcp_stack
        nodes = [{"name": "Only", "type": "Node3D", "path": "/Only"}]

        async def respond():
            cmd = await plugin.recv_command()
            await plugin.send_response(cmd["request_id"], {"root": "Root", "nodes": nodes})

        task = asyncio.create_task(respond())
        result = await client.call_tool(
            "scene_get_hierarchy", {"depth": 10, "offset": 0, "limit": 100}
        )
        await task

        assert result.data["has_more"] is False
        assert result.data["total_count"] == 1


# ---------------------------------------------------------------------------
# scene_get_roots
# ---------------------------------------------------------------------------


class TestSceneGetRootsTool:
    async def test_returns_open_scenes(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "get_open_scenes"
            await plugin.send_response(
                cmd["request_id"],
                {"scenes": ["res://main.tscn"], "current": "res://main.tscn"},
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool("scene_get_roots", {})
        await task

        assert result.data["current"] == "res://main.tscn"


# ---------------------------------------------------------------------------
# scene_create
# ---------------------------------------------------------------------------


class TestSceneCreateTool:
    async def test_create_scene(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "create_scene"
            assert cmd["params"]["path"] == "res://scenes/level.tscn"
            assert cmd["params"]["root_type"] == "Node2D"
            await plugin.send_response(
                cmd["request_id"],
                {
                    "path": "res://scenes/level.tscn",
                    "root_type": "Node2D",
                    "root_name": "level",
                    "undoable": False,
                },
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool(
            "scene_create", {"path": "res://scenes/level.tscn", "root_type": "Node2D"}
        )
        await task

        assert result.data["path"] == "res://scenes/level.tscn"
        assert result.data["root_type"] == "Node2D"
        assert result.data["undoable"] is False

    async def test_create_scene_default_root(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["params"]["root_type"] == "Node3D"
            await plugin.send_response(
                cmd["request_id"],
                {
                    "path": "res://new.tscn",
                    "root_type": "Node3D",
                    "root_name": "new",
                    "undoable": False,
                },
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool("scene_create", {"path": "res://new.tscn"})
        await task
        assert result.data["root_type"] == "Node3D"


# ---------------------------------------------------------------------------
# scene_open
# ---------------------------------------------------------------------------


class TestSceneOpenTool:
    async def test_open_scene(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "open_scene"
            assert cmd["params"]["path"] == "res://levels/world.tscn"
            await plugin.send_response(
                cmd["request_id"],
                {"path": "res://levels/world.tscn", "undoable": False},
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool("scene_open", {"path": "res://levels/world.tscn"})
        await task

        assert result.data["path"] == "res://levels/world.tscn"
        assert result.data["undoable"] is False


# ---------------------------------------------------------------------------
# scene_save
# ---------------------------------------------------------------------------


class TestSceneSaveTool:
    async def test_save_scene(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "save_scene"
            await plugin.send_response(
                cmd["request_id"],
                {"path": "res://main.tscn", "undoable": False},
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool("scene_save", {})
        await task

        assert result.data["path"] == "res://main.tscn"


# ---------------------------------------------------------------------------
# scene_save_as
# ---------------------------------------------------------------------------


class TestSceneSaveAsTool:
    async def test_save_scene_as(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "save_scene_as"
            assert cmd["params"]["path"] == "res://backup/main_copy.tscn"
            await plugin.send_response(
                cmd["request_id"],
                {"path": "res://backup/main_copy.tscn", "undoable": False},
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool("scene_save_as", {"path": "res://backup/main_copy.tscn"})
        await task

        assert result.data["path"] == "res://backup/main_copy.tscn"
        assert result.data["undoable"] is False


# ---------------------------------------------------------------------------
# editor_state
# ---------------------------------------------------------------------------


class TestEditorStateTool:
    async def test_returns_editor_state(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "get_editor_state"
            await plugin.send_response(
                cmd["request_id"],
                {
                    "godot_version": "4.4.1",
                    "project_name": "TestGame",
                    "current_scene": "res://main.tscn",
                    "is_playing": False,
                },
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool("editor_state", {})
        await task

        assert result.data["project_name"] == "TestGame"
        assert result.data["is_playing"] is False


# ---------------------------------------------------------------------------
# editor_selection_get
# ---------------------------------------------------------------------------


class TestEditorSelectionGetTool:
    async def test_returns_selection(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "get_selection"
            await plugin.send_response(cmd["request_id"], {"selected": ["/Main/Camera3D"]})

        task = asyncio.create_task(respond())
        result = await client.call_tool("editor_selection_get", {})
        await task

        assert result.data["selected"] == ["/Main/Camera3D"]


# ---------------------------------------------------------------------------
# logs_read
# ---------------------------------------------------------------------------


class TestLogsReadTool:
    async def test_returns_paginated_logs(self, mcp_stack):
        client, plugin = mcp_stack
        lines = [f"line {i}" for i in range(10)]

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "get_logs"
            await plugin.send_response(cmd["request_id"], {"lines": lines})

        task = asyncio.create_task(respond())
        result = await client.call_tool("logs_read", {"count": 3, "offset": 2})
        await task

        data = result.data
        assert data["lines"] == ["line 2", "line 3", "line 4"]
        assert data["total_count"] == 10
        assert data["offset"] == 2
        assert data["limit"] == 3
        assert data["has_more"] is True


# ---------------------------------------------------------------------------
# node_find
# ---------------------------------------------------------------------------


class TestNodeFindTool:
    async def test_returns_paginated_results(self, mcp_stack):
        client, plugin = mcp_stack
        nodes = [
            {"name": f"Mesh{i}", "type": "MeshInstance3D", "path": f"/Root/Mesh{i}"}
            for i in range(6)
        ]

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "find_nodes"
            await plugin.send_response(cmd["request_id"], {"nodes": nodes})

        task = asyncio.create_task(respond())
        result = await client.call_tool(
            "node_find", {"type": "MeshInstance3D", "offset": 2, "limit": 3}
        )
        await task

        data = result.data
        assert len(data["nodes"]) == 3
        assert data["nodes"][0]["name"] == "Mesh2"
        assert data["total_count"] == 6
        assert data["has_more"] is True


# ---------------------------------------------------------------------------
# node_get_properties / node_get_children / node_get_groups
# ---------------------------------------------------------------------------


class TestNodeReadTools:
    async def test_get_properties(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "get_node_properties"
            assert cmd["params"]["path"] == "/Main/Camera3D"
            await plugin.send_response(
                cmd["request_id"],
                {"properties": [{"name": "fov", "value": 75, "type": "float"}]},
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool("node_get_properties", {"path": "/Main/Camera3D"})
        await task

        assert result.data["properties"][0]["name"] == "fov"

    async def test_get_children(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "get_children"
            await plugin.send_response(
                cmd["request_id"],
                {"children": [{"name": "Ground", "type": "MeshInstance3D"}]},
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool("node_get_children", {"path": "/Main/World"})
        await task

        assert result.data["children"][0]["name"] == "Ground"

    async def test_get_groups(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "get_groups"
            await plugin.send_response(cmd["request_id"], {"groups": ["enemies", "damageable"]})

        task = asyncio.create_task(respond())
        result = await client.call_tool("node_get_groups", {"path": "/Main/Enemy"})
        await task

        assert "enemies" in result.data["groups"]


# ---------------------------------------------------------------------------
# node_create
# ---------------------------------------------------------------------------


class TestNodeCreateTool:
    async def test_create_node(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "create_node"
            assert cmd["params"]["type"] == "MeshInstance3D"
            await plugin.send_response(
                cmd["request_id"],
                {"path": "/Main/NewMesh", "type": "MeshInstance3D", "undoable": True},
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool(
            "node_create", {"type": "MeshInstance3D", "name": "NewMesh", "parent_path": "/Main"}
        )
        await task

        assert result.data["path"] == "/Main/NewMesh"
        assert result.data["undoable"] is True


# ---------------------------------------------------------------------------
# node_delete
# ---------------------------------------------------------------------------


class TestNodeDeleteTool:
    async def test_delete_node(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "delete_node"
            assert cmd["params"]["path"] == "/Main/Enemy"
            await plugin.send_response(
                cmd["request_id"],
                {"path": "/Main/Enemy", "undoable": True},
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool("node_delete", {"path": "/Main/Enemy"})
        await task

        assert result.data["path"] == "/Main/Enemy"
        assert result.data["undoable"] is True


# ---------------------------------------------------------------------------
# node_reparent
# ---------------------------------------------------------------------------


class TestNodeReparentTool:
    async def test_reparent_node(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "reparent_node"
            assert cmd["params"]["path"] == "/Main/Player"
            assert cmd["params"]["new_parent"] == "/Main/World"
            await plugin.send_response(
                cmd["request_id"],
                {
                    "path": "/Main/World/Player",
                    "old_parent": "/Main",
                    "new_parent": "/Main/World",
                    "undoable": True,
                },
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool(
            "node_reparent", {"path": "/Main/Player", "new_parent": "/Main/World"}
        )
        await task

        assert result.data["new_parent"] == "/Main/World"
        assert result.data["undoable"] is True


# ---------------------------------------------------------------------------
# node_set_property
# ---------------------------------------------------------------------------


class TestNodeSetPropertyTool:
    async def test_set_property(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "set_property"
            assert cmd["params"]["path"] == "/Main/Camera3D"
            assert cmd["params"]["property"] == "fov"
            assert cmd["params"]["value"] == 90
            await plugin.send_response(
                cmd["request_id"],
                {
                    "path": "/Main/Camera3D",
                    "property": "fov",
                    "value": 90,
                    "old_value": 75,
                    "undoable": True,
                },
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool(
            "node_set_property",
            {"path": "/Main/Camera3D", "property": "fov", "value": 90},
        )
        await task

        assert result.data["value"] == 90
        assert result.data["old_value"] == 75
        assert result.data["undoable"] is True


# ---------------------------------------------------------------------------
# node_duplicate
# ---------------------------------------------------------------------------


class TestNodeDuplicateTool:
    async def test_duplicate_node(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "duplicate_node"
            assert cmd["params"]["path"] == "/Main/Enemy"
            assert cmd["params"]["name"] == "Enemy2"
            await plugin.send_response(
                cmd["request_id"],
                {
                    "path": "/Main/Enemy2",
                    "original_path": "/Main/Enemy",
                    "name": "Enemy2",
                    "type": "CharacterBody3D",
                    "undoable": True,
                },
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool("node_duplicate", {"path": "/Main/Enemy", "name": "Enemy2"})
        await task

        assert result.data["name"] == "Enemy2"
        assert result.data["undoable"] is True


# ---------------------------------------------------------------------------
# node_move
# ---------------------------------------------------------------------------


class TestNodeMoveTool:
    async def test_move_node(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "move_node"
            assert cmd["params"]["path"] == "/Main/Camera3D"
            assert cmd["params"]["index"] == 2
            await plugin.send_response(
                cmd["request_id"],
                {
                    "path": "/Main/Camera3D",
                    "old_index": 0,
                    "new_index": 2,
                    "undoable": True,
                },
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool("node_move", {"path": "/Main/Camera3D", "index": 2})
        await task

        assert result.data["new_index"] == 2
        assert result.data["undoable"] is True


# ---------------------------------------------------------------------------
# node_add_to_group / node_remove_from_group
# ---------------------------------------------------------------------------


class TestNodeGroupTools:
    async def test_add_to_group(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "add_to_group"
            assert cmd["params"]["group"] == "enemies"
            await plugin.send_response(
                cmd["request_id"],
                {"path": "/Main/Enemy", "group": "enemies", "undoable": True},
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool(
            "node_add_to_group", {"path": "/Main/Enemy", "group": "enemies"}
        )
        await task

        assert result.data["group"] == "enemies"
        assert result.data["undoable"] is True

    async def test_remove_from_group(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "remove_from_group"
            assert cmd["params"]["group"] == "enemies"
            await plugin.send_response(
                cmd["request_id"],
                {"path": "/Main/Enemy", "group": "enemies", "undoable": True},
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool(
            "node_remove_from_group", {"path": "/Main/Enemy", "group": "enemies"}
        )
        await task

        assert result.data["group"] == "enemies"


# ---------------------------------------------------------------------------
# editor_selection_set
# ---------------------------------------------------------------------------


class TestEditorSelectionSetTool:
    async def test_set_selection(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "set_selection"
            assert cmd["params"]["paths"] == ["/Main/Camera3D", "/Main/World"]
            await plugin.send_response(
                cmd["request_id"],
                {
                    "selected": ["/Main/Camera3D", "/Main/World"],
                    "not_found": [],
                    "count": 2,
                    "undoable": False,
                },
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool(
            "editor_selection_set",
            {"paths": ["/Main/Camera3D", "/Main/World"]},
        )
        await task

        assert result.data["count"] == 2
        assert result.data["selected"] == ["/Main/Camera3D", "/Main/World"]

    async def test_set_selection_with_missing_nodes(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            await plugin.send_response(
                cmd["request_id"],
                {
                    "selected": ["/Main/Camera3D"],
                    "not_found": ["/Main/Ghost"],
                    "count": 1,
                    "undoable": False,
                },
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool(
            "editor_selection_set",
            {"paths": ["/Main/Camera3D", "/Main/Ghost"]},
        )
        await task

        assert result.data["count"] == 1
        assert result.data["not_found"] == ["/Main/Ghost"]


# ---------------------------------------------------------------------------
# project_settings_get
# ---------------------------------------------------------------------------


class TestProjectSettingsGetTool:
    async def test_returns_setting(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "get_project_setting"
            await plugin.send_response(
                cmd["request_id"],
                {"key": "application/config/name", "value": "MyGame", "type": "String"},
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool("project_settings_get", {"key": "application/config/name"})
        await task

        assert result.data["value"] == "MyGame"


# ---------------------------------------------------------------------------
# project_settings_set
# ---------------------------------------------------------------------------


class TestProjectSettingsSetTool:
    async def test_set_setting(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "set_project_setting"
            assert cmd["params"]["key"] == "display/window/size/viewport_width"
            assert cmd["params"]["value"] == 1920
            await plugin.send_response(
                cmd["request_id"],
                {
                    "key": "display/window/size/viewport_width",
                    "value": 1920,
                    "old_value": 1152,
                    "type": "int",
                    "undoable": False,
                },
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool(
            "project_settings_set",
            {"key": "display/window/size/viewport_width", "value": 1920},
        )
        await task

        assert result.data["value"] == 1920
        assert result.data["old_value"] == 1152


# ---------------------------------------------------------------------------
# filesystem_search
# ---------------------------------------------------------------------------


class TestFilesystemSearchTool:
    async def test_returns_paginated_files(self, mcp_stack):
        client, plugin = mcp_stack
        files = [{"path": f"res://scripts/script_{i}.gd", "type": "GDScript"} for i in range(8)]

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "search_filesystem"
            await plugin.send_response(cmd["request_id"], {"files": files, "count": 8})

        task = asyncio.create_task(respond())
        result = await client.call_tool(
            "filesystem_search", {"type": "GDScript", "offset": 5, "limit": 10}
        )
        await task

        data = result.data
        assert len(data["files"]) == 3
        assert data["total_count"] == 8
        assert data["offset"] == 5
        assert data["has_more"] is False


# ---------------------------------------------------------------------------
# editor_quit
# ---------------------------------------------------------------------------


class TestEditorQuitTool:
    async def test_quit_editor(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "quit_editor"
            await plugin.send_response(
                cmd["request_id"],
                {"status": "quitting", "message": "Editor quit initiated"},
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool("editor_quit", {})
        await task

        assert result.data["status"] == "quitting"


# ---------------------------------------------------------------------------
# reload_plugin
# ---------------------------------------------------------------------------
# No GDScript test for reload_plugin — calling it triggers a real plugin
# reload that kills the test runner.


class TestReloadPluginTool:
    async def test_reload_cycle(self, mcp_stack):
        """Full reload cycle: ack, disconnect, reconnect with new session."""
        client, plugin = mcp_stack
        ws_port = 19502  # matches mcp_stack fixture

        async def simulate_reload():
            # Receive the reload command and ack it
            cmd = await plugin.recv_command()
            assert cmd["command"] == "reload_plugin"
            await plugin.send_response(
                cmd["request_id"],
                {"status": "reloading", "message": "Plugin reload initiated"},
            )
            # Simulate the plugin dying and reconnecting
            await plugin.close()
            await asyncio.sleep(0.1)
            # Reconnect as a new session
            ws = await websockets.connect(f"ws://127.0.0.1:{ws_port}")
            handshake = {
                "type": "handshake",
                "session_id": "reloaded-session",
                "godot_version": "4.4.1",
                "project_path": "/tmp/test_project",
                "plugin_version": "0.0.1",
                "protocol_version": 1,
            }
            await ws.send(json.dumps(handshake))
            await asyncio.sleep(0.05)
            return ws

        task = asyncio.create_task(simulate_reload())
        result = await client.call_tool("reload_plugin", {})
        new_ws = await task

        assert result.data["status"] == "reloaded"
        assert result.data["old_session_id"] == "mcp-test"
        assert result.data["new_session_id"] == "reloaded-session"
        await new_ws.close()


# ---------------------------------------------------------------------------
# session_list / session_activate
# ---------------------------------------------------------------------------


class TestSessionTools:
    async def test_session_list_returns_connected_session(self, mcp_stack):
        client, plugin = mcp_stack
        result = await client.call_tool("session_list", {})
        assert result.data["count"] == 1
        assert result.data["sessions"][0]["session_id"] == "mcp-test"
        assert result.data["sessions"][0]["is_active"] is True

    async def test_session_activate_existing(self, mcp_stack):
        client, plugin = mcp_stack
        result = await client.call_tool("session_activate", {"session_id": "mcp-test"})
        assert result.data["status"] == "ok"

    async def test_session_activate_nonexistent(self, mcp_stack):
        client, plugin = mcp_stack
        result = await client.call_tool("session_activate", {"session_id": "no-such-session"})
        assert result.data["status"] == "error"


# ---------------------------------------------------------------------------
# client_configure / client_status
# ---------------------------------------------------------------------------


class TestClientTools:
    async def test_client_status(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "check_client_status"
            await plugin.send_response(
                cmd["request_id"],
                {"claude_code": "configured", "codex": "not_configured"},
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool("client_status", {})
        await task
        assert result.data["claude_code"] == "configured"

    async def test_client_configure(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "configure_client"
            assert cmd["params"]["client"] == "codex"
            await plugin.send_response(cmd["request_id"], {"status": "ok"})

        task = asyncio.create_task(respond())
        result = await client.call_tool("client_configure", {"client": "codex"})
        await task
        assert result.data["status"] == "ok"


# ---------------------------------------------------------------------------
# run_tests / get_test_results
# ---------------------------------------------------------------------------


class TestTestingTools:
    async def test_run_tests(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "run_tests"
            await plugin.send_response(cmd["request_id"], {"passed": 3, "failed": 0, "results": []})

        task = asyncio.create_task(respond())
        result = await client.call_tool("run_tests", {})
        await task
        assert result.data["passed"] == 3

    async def test_run_tests_with_suite(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "run_tests"
            assert cmd["params"]["suite"] == "scene"
            await plugin.send_response(cmd["request_id"], {"passed": 2, "failed": 0, "results": []})

        task = asyncio.create_task(respond())
        result = await client.call_tool("run_tests", {"suite": "scene"})
        await task
        assert result.data["passed"] == 2

    async def test_get_test_results(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "get_test_results"
            await plugin.send_response(cmd["request_id"], {"passed": 5, "failed": 1, "results": []})

        task = asyncio.create_task(respond())
        result = await client.call_tool("get_test_results", {})
        await task
        assert result.data["failed"] == 1


# ---------------------------------------------------------------------------
# Resource reads (through MCP client)
# ---------------------------------------------------------------------------


class TestResourceReads:
    async def test_read_sessions_resource(self, mcp_stack):
        client, plugin = mcp_stack
        result = await client.read_resource("godot://sessions")
        data = json.loads(result[0].text)
        assert data["count"] == 1
        assert data["sessions"][0]["session_id"] == "mcp-test"

    async def test_read_project_info_resource(self, mcp_stack):
        client, plugin = mcp_stack
        result = await client.read_resource("godot://project/info")
        data = json.loads(result[0].text)
        assert data["session_id"] == "mcp-test"

    async def test_read_selection_resource(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "get_selection"
            await plugin.send_response(cmd["request_id"], {"selected": ["/Main/Cam"]})

        task = asyncio.create_task(respond())
        result = await client.read_resource("godot://selection/current")
        await task
        data = json.loads(result[0].text)
        assert data["selected"] == ["/Main/Cam"]

    async def test_read_logs_resource(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "get_logs"
            await plugin.send_response(cmd["request_id"], {"lines": ["log line 1"]})

        task = asyncio.create_task(respond())
        result = await client.read_resource("godot://logs/recent")
        await task
        data = json.loads(result[0].text)
        assert "lines" in data

    async def test_read_scene_current_resource(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "get_editor_state"
            await plugin.send_response(
                cmd["request_id"],
                {"current_scene": "res://main.tscn", "project_name": "Test", "is_playing": False},
            )

        task = asyncio.create_task(respond())
        result = await client.read_resource("godot://scene/current")
        await task
        data = json.loads(result[0].text)
        assert data["current_scene"] == "res://main.tscn"

    async def test_read_scene_hierarchy_resource(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "get_scene_tree"
            await plugin.send_response(
                cmd["request_id"],
                {"root": "Main", "nodes": [{"name": "Camera3D"}]},
            )

        task = asyncio.create_task(respond())
        result = await client.read_resource("godot://scene/hierarchy")
        await task
        data = json.loads(result[0].text)
        assert data["root"] == "Main"


# ---------------------------------------------------------------------------
# script_create
# ---------------------------------------------------------------------------


class TestScriptCreateTool:
    async def test_create_script(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "create_script"
            assert cmd["params"]["path"] == "res://scripts/player.gd"
            assert "extends" in cmd["params"]["content"]
            await plugin.send_response(
                cmd["request_id"],
                {"path": "res://scripts/player.gd", "size": 42, "undoable": False},
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool(
            "script_create",
            {"path": "res://scripts/player.gd", "content": "extends Node3D\n"},
        )
        await task

        assert result.data["path"] == "res://scripts/player.gd"
        assert result.data["undoable"] is False


# ---------------------------------------------------------------------------
# script_read
# ---------------------------------------------------------------------------


class TestScriptReadTool:
    async def test_read_script(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "read_script"
            assert cmd["params"]["path"] == "res://scripts/player.gd"
            await plugin.send_response(
                cmd["request_id"],
                {
                    "path": "res://scripts/player.gd",
                    "content": "extends Node3D\n",
                    "size": 15,
                    "line_count": 2,
                },
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool("script_read", {"path": "res://scripts/player.gd"})
        await task

        assert result.data["content"] == "extends Node3D\n"
        assert result.data["line_count"] == 2


# ---------------------------------------------------------------------------
# script_attach
# ---------------------------------------------------------------------------


class TestScriptAttachTool:
    async def test_attach_script(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "attach_script"
            assert cmd["params"]["path"] == "/Main/Player"
            assert cmd["params"]["script_path"] == "res://scripts/player.gd"
            await plugin.send_response(
                cmd["request_id"],
                {
                    "path": "/Main/Player",
                    "script_path": "res://scripts/player.gd",
                    "had_previous_script": False,
                    "undoable": True,
                },
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool(
            "script_attach",
            {"path": "/Main/Player", "script_path": "res://scripts/player.gd"},
        )
        await task

        assert result.data["script_path"] == "res://scripts/player.gd"
        assert result.data["undoable"] is True


# ---------------------------------------------------------------------------
# script_detach
# ---------------------------------------------------------------------------


class TestScriptDetachTool:
    async def test_detach_script(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "detach_script"
            assert cmd["params"]["path"] == "/Main/Player"
            await plugin.send_response(
                cmd["request_id"],
                {
                    "path": "/Main/Player",
                    "removed_script": "res://scripts/player.gd",
                    "undoable": True,
                },
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool("script_detach", {"path": "/Main/Player"})
        await task

        assert result.data["removed_script"] == "res://scripts/player.gd"
        assert result.data["undoable"] is True

    async def test_detach_no_script(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "detach_script"
            await plugin.send_response(
                cmd["request_id"],
                {"path": "/Main/Player", "had_script": False, "undoable": False},
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool("script_detach", {"path": "/Main/Player"})
        await task

        assert result.data["had_script"] is False


# ---------------------------------------------------------------------------
# script_find_symbols
# ---------------------------------------------------------------------------


class TestScriptFindSymbolsTool:
    async def test_find_symbols(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "find_symbols"
            assert cmd["params"]["path"] == "res://scripts/player.gd"
            await plugin.send_response(
                cmd["request_id"],
                {
                    "path": "res://scripts/player.gd",
                    "class_name": "Player",
                    "extends": "CharacterBody3D",
                    "functions": [{"name": "_ready", "line": 5}],
                    "signals": ["health_changed"],
                    "exports": [{"name": "speed", "line": 3}],
                    "function_count": 1,
                    "signal_count": 1,
                    "export_count": 1,
                },
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool("script_find_symbols", {"path": "res://scripts/player.gd"})
        await task

        assert result.data["class_name"] == "Player"
        assert result.data["function_count"] == 1
        assert result.data["functions"][0]["name"] == "_ready"
        assert result.data["signals"] == ["health_changed"]


# ---------------------------------------------------------------------------
# resource_search
# ---------------------------------------------------------------------------


class TestResourceSearchTool:
    async def test_search_resources(self, mcp_stack):
        client, plugin = mcp_stack
        resources = [
            {"path": f"res://materials/mat_{i}.tres", "type": "StandardMaterial3D"}
            for i in range(5)
        ]

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "search_resources"
            assert cmd["params"]["type"] == "Material"
            await plugin.send_response(cmd["request_id"], {"resources": resources, "count": 5})

        task = asyncio.create_task(respond())
        result = await client.call_tool(
            "resource_search", {"type": "Material", "offset": 2, "limit": 2}
        )
        await task

        data = result.data
        assert len(data["resources"]) == 2
        assert data["total_count"] == 5
        assert data["has_more"] is True


# ---------------------------------------------------------------------------
# resource_load
# ---------------------------------------------------------------------------


class TestResourceLoadTool:
    async def test_load_resource(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "load_resource"
            assert cmd["params"]["path"] == "res://materials/ground.tres"
            await plugin.send_response(
                cmd["request_id"],
                {
                    "path": "res://materials/ground.tres",
                    "type": "StandardMaterial3D",
                    "properties": [{"name": "albedo_color", "type": "Color"}],
                    "property_count": 1,
                },
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool("resource_load", {"path": "res://materials/ground.tres"})
        await task

        assert result.data["type"] == "StandardMaterial3D"
        assert result.data["property_count"] == 1


# ---------------------------------------------------------------------------
# resource_assign
# ---------------------------------------------------------------------------


class TestResourceAssignTool:
    async def test_assign_resource(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "assign_resource"
            assert cmd["params"]["path"] == "/Main/Ground"
            assert cmd["params"]["property"] == "material_override"
            assert cmd["params"]["resource_path"] == "res://materials/ground.tres"
            await plugin.send_response(
                cmd["request_id"],
                {
                    "path": "/Main/Ground",
                    "property": "material_override",
                    "resource_path": "res://materials/ground.tres",
                    "resource_type": "StandardMaterial3D",
                    "undoable": True,
                },
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool(
            "resource_assign",
            {
                "path": "/Main/Ground",
                "property": "material_override",
                "resource_path": "res://materials/ground.tres",
            },
        )
        await task

        assert result.data["resource_type"] == "StandardMaterial3D"
        assert result.data["undoable"] is True


# ---------------------------------------------------------------------------
# filesystem_read_text
# ---------------------------------------------------------------------------


class TestFilesystemReadTextTool:
    async def test_read_text(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "read_file"
            assert cmd["params"]["path"] == "res://project.godot"
            await plugin.send_response(
                cmd["request_id"],
                {
                    "path": "res://project.godot",
                    "content": "[gd_scene]\n",
                    "size": 11,
                    "line_count": 2,
                },
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool("filesystem_read_text", {"path": "res://project.godot"})
        await task

        assert result.data["content"] == "[gd_scene]\n"
        assert result.data["size"] == 11


# ---------------------------------------------------------------------------
# filesystem_write_text
# ---------------------------------------------------------------------------


class TestFilesystemWriteTextTool:
    async def test_write_text(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "write_file"
            assert cmd["params"]["path"] == "res://data/config.json"
            assert "key" in cmd["params"]["content"]
            await plugin.send_response(
                cmd["request_id"],
                {
                    "path": "res://data/config.json",
                    "size": 14,
                    "undoable": False,
                },
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool(
            "filesystem_write_text",
            {"path": "res://data/config.json", "content": '{"key": "val"}'},
        )
        await task

        assert result.data["path"] == "res://data/config.json"
        assert result.data["undoable"] is False


# ---------------------------------------------------------------------------
# import_reimport
# ---------------------------------------------------------------------------


class TestImportReimportTool:
    async def test_reimport(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "reimport"
            assert cmd["params"]["paths"] == ["res://icon.png", "res://logo.png"]
            await plugin.send_response(
                cmd["request_id"],
                {
                    "reimported": ["res://icon.png", "res://logo.png"],
                    "not_found": [],
                    "reimported_count": 2,
                    "not_found_count": 0,
                    "undoable": False,
                },
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool(
            "import_reimport", {"paths": ["res://icon.png", "res://logo.png"]}
        )
        await task

        assert result.data["reimported_count"] == 2
        assert result.data["not_found_count"] == 0


# ---------------------------------------------------------------------------
# signal_list / signal_connect / signal_disconnect
# ---------------------------------------------------------------------------


class TestSignalListTool:
    async def test_list_signals(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "list_signals"
            assert cmd["params"]["path"] == "/Main/Button"
            await plugin.send_response(
                cmd["request_id"],
                {
                    "path": "/Main/Button",
                    "signals": [{"name": "pressed", "args": []}],
                    "signal_count": 1,
                    "connections": [],
                    "connection_count": 0,
                },
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool("signal_list", {"path": "/Main/Button"})
        await task

        assert result.data["signal_count"] == 1
        assert result.data["signals"][0]["name"] == "pressed"


class TestSignalConnectTool:
    async def test_connect_signal(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "connect_signal"
            assert cmd["params"]["signal"] == "pressed"
            await plugin.send_response(
                cmd["request_id"],
                {
                    "source": "/Main/Button",
                    "signal": "pressed",
                    "target": "/Main/Player",
                    "method": "_on_pressed",
                    "undoable": True,
                },
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool(
            "signal_connect",
            {
                "path": "/Main/Button",
                "signal": "pressed",
                "target": "/Main/Player",
                "method": "_on_pressed",
            },
        )
        await task

        assert result.data["undoable"] is True


class TestSignalDisconnectTool:
    async def test_disconnect_signal(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "disconnect_signal"
            await plugin.send_response(
                cmd["request_id"],
                {
                    "source": "/Main/Button",
                    "signal": "pressed",
                    "target": "/Main/Player",
                    "method": "_on_pressed",
                    "undoable": True,
                },
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool(
            "signal_disconnect",
            {
                "path": "/Main/Button",
                "signal": "pressed",
                "target": "/Main/Player",
                "method": "_on_pressed",
            },
        )
        await task

        assert result.data["undoable"] is True


# ---------------------------------------------------------------------------
# autoload_list / autoload_add / autoload_remove
# ---------------------------------------------------------------------------


class TestAutoloadListTool:
    async def test_list_autoloads(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "list_autoloads"
            await plugin.send_response(
                cmd["request_id"],
                {
                    "autoloads": [
                        {
                            "name": "GameManager",
                            "path": "res://autoloads/game_manager.gd",
                            "singleton": True,
                        },
                    ],
                    "count": 1,
                },
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool("autoload_list", {})
        await task

        assert result.data["count"] == 1
        assert result.data["autoloads"][0]["name"] == "GameManager"


class TestAutoloadAddTool:
    async def test_add_autoload(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "add_autoload"
            assert cmd["params"]["name"] == "AudioBus"
            assert cmd["params"]["path"] == "res://audio_bus.gd"
            await plugin.send_response(
                cmd["request_id"],
                {
                    "name": "AudioBus",
                    "path": "res://audio_bus.gd",
                    "singleton": True,
                    "undoable": False,
                },
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool(
            "autoload_add",
            {"name": "AudioBus", "path": "res://audio_bus.gd"},
        )
        await task

        assert result.data["name"] == "AudioBus"


class TestAutoloadRemoveTool:
    async def test_remove_autoload(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "remove_autoload"
            assert cmd["params"]["name"] == "AudioBus"
            await plugin.send_response(
                cmd["request_id"],
                {"name": "AudioBus", "removed": True, "undoable": False},
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool("autoload_remove", {"name": "AudioBus"})
        await task

        assert result.data["removed"] is True


# ---------------------------------------------------------------------------
# input_map_list / input_map_add_action / input_map_remove_action / input_map_bind_event
# ---------------------------------------------------------------------------


class TestInputMapListTool:
    async def test_list_actions(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "list_actions"
            await plugin.send_response(
                cmd["request_id"],
                {
                    "actions": [
                        {"name": "jump", "events": [], "event_count": 0, "is_builtin": False},
                    ],
                    "count": 1,
                },
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool("input_map_list", {})
        await task

        assert result.data["count"] == 1
        assert result.data["actions"][0]["name"] == "jump"


class TestInputMapAddActionTool:
    async def test_add_action(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "add_action"
            assert cmd["params"]["action"] == "attack"
            await plugin.send_response(
                cmd["request_id"],
                {"action": "attack", "deadzone": 0.5, "undoable": False},
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool(
            "input_map_add_action", {"action": "attack"}
        )
        await task

        assert result.data["action"] == "attack"


class TestInputMapRemoveActionTool:
    async def test_remove_action(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "remove_action"
            assert cmd["params"]["action"] == "attack"
            await plugin.send_response(
                cmd["request_id"],
                {"action": "attack", "removed": True, "undoable": False},
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool(
            "input_map_remove_action", {"action": "attack"}
        )
        await task

        assert result.data["removed"] is True


class TestInputMapBindEventTool:
    async def test_bind_key_event(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "bind_event"
            assert cmd["params"]["action"] == "jump"
            assert cmd["params"]["event_type"] == "key"
            assert cmd["params"]["keycode"] == "Space"
            await plugin.send_response(
                cmd["request_id"],
                {
                    "action": "jump",
                    "event": {"type": "key", "keycode": "Space"},
                    "undoable": False,
                },
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool(
            "input_map_bind_event",
            {"action": "jump", "event_type": "key", "keycode": "Space"},
        )
        await task

        assert result.data["event"]["type"] == "key"
        assert result.data["event"]["keycode"] == "Space"

    async def test_bind_key_event_with_modifiers(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["params"]["ctrl"] is True
            assert cmd["params"]["alt"] is True
            assert cmd["params"]["shift"] is True
            assert cmd["params"]["meta"] is True
            await plugin.send_response(
                cmd["request_id"],
                {
                    "action": "save",
                    "event": {"type": "key", "keycode": "S", "ctrl": True},
                    "undoable": False,
                },
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool(
            "input_map_bind_event",
            {
                "action": "save",
                "event_type": "key",
                "keycode": "S",
                "ctrl": True,
                "alt": True,
                "shift": True,
                "meta": True,
            },
        )
        await task

        assert result.data["event"]["type"] == "key"

    async def test_bind_mouse_button_event(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["params"]["event_type"] == "mouse_button"
            assert cmd["params"]["button"] == 1
            await plugin.send_response(
                cmd["request_id"],
                {
                    "action": "shoot",
                    "event": {"type": "mouse_button", "button": 1},
                    "undoable": False,
                },
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool(
            "input_map_bind_event",
            {"action": "shoot", "event_type": "mouse_button", "button": 1},
        )
        await task

        assert result.data["event"]["type"] == "mouse_button"
        assert result.data["event"]["button"] == 1


# ---------------------------------------------------------------------------
# input_map_list (include_builtin)
# ---------------------------------------------------------------------------


class TestInputMapListBuiltinFilter:
    async def test_list_with_include_builtin(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "list_actions"
            assert cmd["params"]["include_builtin"] is True
            await plugin.send_response(
                cmd["request_id"],
                {
                    "actions": [
                        {"name": "ui_accept", "events": [], "event_count": 0, "is_builtin": True},
                    ],
                    "count": 1,
                },
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool(
            "input_map_list", {"include_builtin": True}
        )
        await task

        assert result.data["count"] == 1
        assert result.data["actions"][0]["is_builtin"] is True


# ---------------------------------------------------------------------------
# Readiness gating
# ---------------------------------------------------------------------------


class TestReadinessGating:
    async def _set_readiness(self, plugin, readiness: str) -> None:
        """Send a readiness_changed event and wait for it to be processed."""
        await plugin.send_event("readiness_changed", {"readiness": readiness})
        await asyncio.sleep(0.05)

    async def test_write_tool_rejected_when_importing(self, mcp_stack):
        client, plugin = mcp_stack
        await self._set_readiness(plugin, "importing")

        result = await client.call_tool(
            "node_create", {"type": "Node3D", "name": "Blocked"},
            raise_on_error=False,
        )

        assert result.is_error
        assert "EDITOR_NOT_READY" in str(result.content)

    async def test_write_tool_rejected_when_playing(self, mcp_stack):
        client, plugin = mcp_stack
        await self._set_readiness(plugin, "playing")

        result = await client.call_tool("scene_save", {}, raise_on_error=False)

        assert result.is_error
        assert "EDITOR_NOT_READY" in str(result.content)

    async def test_read_tool_allowed_when_importing(self, mcp_stack):
        client, plugin = mcp_stack
        await self._set_readiness(plugin, "importing")

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "get_editor_state"
            await plugin.send_response(
                cmd["request_id"],
                {
                    "godot_version": "4.4.1",
                    "project_name": "Test",
                    "current_scene": "",
                    "is_playing": False,
                    "readiness": "importing",
                },
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool("editor_state", {})
        await task

        assert not result.is_error

    async def test_write_tool_works_after_readiness_restored(self, mcp_stack):
        client, plugin = mcp_stack
        # First set importing to block writes
        await self._set_readiness(plugin, "importing")
        result = await client.call_tool(
            "node_create", {"type": "Node3D", "name": "Blocked"},
            raise_on_error=False,
        )
        assert result.is_error

        # Restore readiness
        await self._set_readiness(plugin, "ready")

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "create_node"
            await plugin.send_response(
                cmd["request_id"],
                {"path": "/Main/Unblocked", "type": "Node3D"},
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool(
            "node_create", {"type": "Node3D", "name": "Unblocked"}
        )
        await task

        assert not result.is_error
        assert result.data["path"] == "/Main/Unblocked"

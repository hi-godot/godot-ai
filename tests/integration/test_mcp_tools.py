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
# node_rename
# ---------------------------------------------------------------------------


class TestNodeRenameTool:
    async def test_rename_node(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "rename_node"
            assert cmd["params"] == {"path": "/Main/Player", "new_name": "Hero"}
            await plugin.send_response(
                cmd["request_id"],
                {
                    "path": "/Main/Hero",
                    "old_path": "/Main/Player",
                    "name": "Hero",
                    "old_name": "Player",
                    "undoable": True,
                },
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool("node_rename", {"path": "/Main/Player", "new_name": "Hero"})
        await task

        assert result.data["name"] == "Hero"
        assert result.data["old_name"] == "Player"
        assert result.data["path"] == "/Main/Hero"
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
        result = await client.call_tool("editor_reload_plugin", {})
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
                {
                    "clients": [
                        {
                            "id": "claude_code",
                            "display_name": "Claude Code",
                            "status": "configured",
                            "installed": True,
                        },
                        {
                            "id": "codex",
                            "display_name": "Codex",
                            "status": "not_configured",
                            "installed": False,
                        },
                    ]
                },
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool("client_status", {})
        await task
        clients = {entry["id"]: entry for entry in result.data["clients"]}
        assert clients["claude_code"]["status"] == "configured"
        assert clients["codex"]["installed"] is False

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

    async def test_client_remove(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "remove_client"
            assert cmd["params"]["client"] == "cursor"
            await plugin.send_response(cmd["request_id"], {"status": "ok"})

        task = asyncio.create_task(respond())
        result = await client.call_tool("client_remove", {"client": "cursor"})
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
        result = await client.call_tool("test_run", {})
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
        result = await client.call_tool("test_run", {"suite": "scene"})
        await task
        assert result.data["passed"] == 2

    async def test_get_test_results(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "get_test_results"
            await plugin.send_response(cmd["request_id"], {"passed": 5, "failed": 1, "results": []})

        task = asyncio.create_task(respond())
        result = await client.call_tool("test_results_get", {})
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
# script_patch
# ---------------------------------------------------------------------------


class TestScriptPatchTool:
    async def test_patch_script(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "patch_script"
            assert cmd["params"] == {
                "path": "res://scripts/player.gd",
                "old_text": "speed = 5",
                "new_text": "speed = 10",
                "replace_all": False,
            }
            await plugin.send_response(
                cmd["request_id"],
                {
                    "path": "res://scripts/player.gd",
                    "replacements": 1,
                    "size": 120,
                    "old_size": 119,
                    "undoable": False,
                },
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool(
            "script_patch",
            {
                "path": "res://scripts/player.gd",
                "old_text": "speed = 5",
                "new_text": "speed = 10",
            },
        )
        await task

        assert result.data["replacements"] == 1
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
            "filesystem_reimport", {"paths": ["res://icon.png", "res://logo.png"]}
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
        result = await client.call_tool("input_map_add_action", {"action": "attack"})
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
        result = await client.call_tool("input_map_remove_action", {"action": "attack"})
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
        result = await client.call_tool("input_map_list", {"include_builtin": True})
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
            "node_create",
            {"type": "Node3D", "name": "Blocked"},
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
            "node_create",
            {"type": "Node3D", "name": "Blocked"},
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
        result = await client.call_tool("node_create", {"type": "Node3D", "name": "Unblocked"})
        await task

        assert not result.is_error
        assert result.data["path"] == "/Main/Unblocked"


# ---------------------------------------------------------------------------
# logs_clear
# ---------------------------------------------------------------------------


class TestLogsClearTool:
    async def test_clears_log_buffer(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "clear_logs"
            await plugin.send_response(cmd["request_id"], {"cleared_count": 12})

        task = asyncio.create_task(respond())
        result = await client.call_tool("logs_clear", {})
        await task

        assert not result.is_error
        assert result.data["cleared_count"] == 12


# ---------------------------------------------------------------------------
# project_run / project_stop
# ---------------------------------------------------------------------------


class TestProjectRunTool:
    async def test_run_main_scene(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "run_project"
            assert cmd["params"]["mode"] == "main"
            await plugin.send_response(
                cmd["request_id"],
                {"mode": "main", "scene": "", "undoable": False},
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool("project_run", {})
        await task

        assert not result.is_error
        assert result.data["mode"] == "main"

    async def test_run_current_scene(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["params"]["mode"] == "current"
            await plugin.send_response(
                cmd["request_id"],
                {"mode": "current", "scene": "", "undoable": False},
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool("project_run", {"mode": "current"})
        await task

        assert not result.is_error
        assert result.data["mode"] == "current"

    async def test_run_custom_scene(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["params"]["mode"] == "custom"
            assert cmd["params"]["scene"] == "res://levels/level1.tscn"
            await plugin.send_response(
                cmd["request_id"],
                {
                    "mode": "custom",
                    "scene": "res://levels/level1.tscn",
                    "undoable": False,
                },
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool(
            "project_run",
            {"mode": "custom", "scene": "res://levels/level1.tscn"},
        )
        await task

        assert not result.is_error
        assert result.data["scene"] == "res://levels/level1.tscn"


class TestProjectStopTool:
    async def test_stop_running_project(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "stop_project"
            await plugin.send_response(
                cmd["request_id"],
                {"stopped": True, "undoable": False},
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool("project_stop", {})
        await task

        assert not result.is_error
        assert result.data["stopped"] is True


# ---------------------------------------------------------------------------
# editor_screenshot
# ---------------------------------------------------------------------------


class TestEditorScreenshotTool:
    _ONE_PX_PNG_B64 = (
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4"
        "nGP4DwABAQEBYY2JxQAAAABJRU5ErkJggg=="
    )

    async def test_screenshot_with_image(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "take_screenshot"
            await plugin.send_response(
                cmd["request_id"],
                {
                    "source": "viewport",
                    "width": 640,
                    "height": 480,
                    "original_width": 1920,
                    "original_height": 1080,
                    "format": "png",
                    "image_base64": self._ONE_PX_PNG_B64,
                },
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool("editor_screenshot", {})
        await task

        assert not result.is_error
        # When include_image=True, result contains both text and image content blocks
        assert len(result.content) >= 2

    async def test_screenshot_metadata_only(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            await plugin.send_response(
                cmd["request_id"],
                {
                    "source": "viewport",
                    "width": 640,
                    "height": 480,
                    "original_width": 1920,
                    "original_height": 1080,
                    "format": "png",
                    "image_base64": self._ONE_PX_PNG_B64,
                },
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool("editor_screenshot", {"include_image": False})
        await task

        assert not result.is_error
        assert result.data["source"] == "viewport"
        assert result.data["width"] == 640

    async def test_screenshot_custom_source(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["params"]["source"] == "game"
            await plugin.send_response(
                cmd["request_id"],
                {
                    "source": "game",
                    "width": 640,
                    "height": 480,
                    "original_width": 1920,
                    "original_height": 1080,
                    "format": "png",
                    "image_base64": self._ONE_PX_PNG_B64,
                },
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool(
            "editor_screenshot",
            {"source": "game", "include_image": False},
        )
        await task

        assert result.data["source"] == "game"

    async def test_screenshot_with_view_target(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["params"]["view_target"] == "/Main/MyCube"
            await plugin.send_response(
                cmd["request_id"],
                {
                    "source": "viewport",
                    "width": 640,
                    "height": 480,
                    "original_width": 1920,
                    "original_height": 1080,
                    "format": "png",
                    "image_base64": self._ONE_PX_PNG_B64,
                    "view_target": "/Main/MyCube",
                },
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool(
            "editor_screenshot",
            {"view_target": "/Main/MyCube", "include_image": False},
        )
        await task

        assert not result.is_error
        assert result.data["view_target"] == "/Main/MyCube"

    async def test_screenshot_with_multi_view_target(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["params"]["view_target"] == "/Main/A,/Main/B"
            await plugin.send_response(
                cmd["request_id"],
                {
                    "source": "viewport",
                    "width": 640,
                    "height": 480,
                    "original_width": 1920,
                    "original_height": 1080,
                    "format": "png",
                    "image_base64": self._ONE_PX_PNG_B64,
                    "view_target": "/Main/A,/Main/B",
                    "view_target_count": 2,
                },
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool(
            "editor_screenshot",
            {"view_target": "/Main/A,/Main/B", "include_image": False},
        )
        await task

        assert not result.is_error
        assert result.data["view_target"] == "/Main/A,/Main/B"
        assert result.data["view_target_count"] == 2

    async def test_screenshot_coverage_round_trip(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["params"].get("coverage") is True
            assert cmd["params"]["view_target"] == "/Main/X"
            images = []
            for preset in [
                {
                    "label": "establishing",
                    "elevation": 25.0,
                    "azimuth": 20.0,
                    "fov": 50.0,
                    "ortho": False,
                },
                {"label": "top", "elevation": 90.0, "azimuth": 0.0, "fov": 0.0, "ortho": True},
            ]:
                images.append(
                    {
                        "source": "viewport",
                        "width": 1,
                        "height": 1,
                        "original_width": 100,
                        "original_height": 100,
                        "format": "png",
                        "image_base64": self._ONE_PX_PNG_B64,
                        **preset,
                    }
                )
            await plugin.send_response(
                cmd["request_id"],
                {
                    "source": "viewport",
                    "view_target": "/Main/X",
                    "view_target_count": 1,
                    "coverage": True,
                    "images": images,
                    "aabb_center": [1.0, 0.5, 0.0],
                    "aabb_size": [3.0, 2.0, 2.0],
                    "aabb_longest_ground_axis": "x",
                },
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool(
            "editor_screenshot",
            {"view_target": "/Main/X", "coverage": True},
        )
        await task

        assert not result.is_error
        # 1 text metadata + 2 images = 3 content blocks
        assert len(result.content) == 3

    async def test_screenshot_custom_angles_round_trip(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["params"]["elevation"] == 45.0
            assert cmd["params"]["azimuth"] == 90.0
            await plugin.send_response(
                cmd["request_id"],
                {
                    "source": "viewport",
                    "width": 1,
                    "height": 1,
                    "original_width": 100,
                    "original_height": 100,
                    "format": "png",
                    "image_base64": self._ONE_PX_PNG_B64,
                    "view_target": "/Main/X",
                    "view_target_count": 1,
                    "elevation": 45.0,
                    "azimuth": 90.0,
                },
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool(
            "editor_screenshot",
            {
                "view_target": "/Main/X",
                "elevation": 45.0,
                "azimuth": 90.0,
                "include_image": False,
            },
        )
        await task

        assert not result.is_error
        assert result.data["elevation"] == 45.0
        assert result.data["azimuth"] == 90.0


# ---------------------------------------------------------------------------
# performance_monitors_get
# ---------------------------------------------------------------------------


class TestPerformanceMonitorsGetTool:
    async def test_get_all_monitors(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "get_performance_monitors"
            await plugin.send_response(
                cmd["request_id"],
                {
                    "monitors": {
                        "time/fps": 60.0,
                        "memory/static": 1048576,
                    },
                    "monitor_count": 2,
                },
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool("performance_monitors_get", {})
        await task

        assert not result.is_error
        assert result.data["monitors"]["time/fps"] == 60.0
        assert result.data["monitor_count"] == 2

    async def test_get_filtered_monitors(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["params"]["monitors"] == ["time/fps"]
            await plugin.send_response(
                cmd["request_id"],
                {
                    "monitors": {"time/fps": 60.0},
                    "monitor_count": 1,
                },
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool(
            "performance_monitors_get",
            {"monitors": ["time/fps"]},
        )
        await task

        assert not result.is_error
        assert result.data["monitor_count"] == 1


# ---------------------------------------------------------------------------
# batch_execute
# ---------------------------------------------------------------------------


class TestBatchExecuteTool:
    async def test_forwards_commands_and_returns_results(self, mcp_stack):
        client, plugin = mcp_stack
        cmds = [
            {"command": "create_node", "params": {"type": "Node3D"}},
            {"command": "set_property", "params": {"path": "/A", "property": "x"}},
        ]

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "batch_execute"
            assert cmd["params"]["commands"] == cmds
            assert cmd["params"]["undo"] is True
            await plugin.send_response(
                cmd["request_id"],
                {
                    "succeeded": 2,
                    "stopped_at": None,
                    "results": [
                        {"command": "create_node", "status": "ok", "data": {"undoable": True}},
                        {"command": "set_property", "status": "ok", "data": {"undoable": True}},
                    ],
                    "undo": True,
                    "rolled_back": False,
                    "undoable": True,
                },
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool("batch_execute", {"commands": cmds})
        await task

        assert not result.is_error
        assert result.data["succeeded"] == 2
        assert result.data["stopped_at"] is None
        assert result.data["undoable"] is True

    async def test_reports_sub_command_failure(self, mcp_stack):
        client, plugin = mcp_stack
        cmds = [
            {"command": "create_node", "params": {"type": "Node3D"}},
            {"command": "set_property", "params": {"path": "/Missing", "property": "x"}},
        ]

        async def respond():
            cmd = await plugin.recv_command()
            await plugin.send_response(
                cmd["request_id"],
                {
                    "succeeded": 1,
                    "stopped_at": 1,
                    "results": [
                        {"command": "create_node", "status": "ok", "data": {"undoable": True}},
                        {
                            "command": "set_property",
                            "status": "error",
                            "error": {"code": "INVALID_PARAMS", "message": "Not found"},
                        },
                    ],
                    "undo": True,
                    "rolled_back": True,
                    "undoable": False,
                    "error": {"code": "INVALID_PARAMS", "message": "Not found"},
                },
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool("batch_execute", {"commands": cmds})
        await task

        assert not result.is_error
        assert result.data["succeeded"] == 1
        assert result.data["stopped_at"] == 1
        assert result.data["rolled_back"] is True
        assert result.data["error"]["code"] == "INVALID_PARAMS"

    async def test_undo_false_is_forwarded(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["params"]["undo"] is False
            await plugin.send_response(
                cmd["request_id"],
                {
                    "succeeded": 1,
                    "stopped_at": None,
                    "results": [
                        {"command": "create_node", "status": "ok", "data": {"undoable": True}}
                    ],
                    "undo": False,
                    "rolled_back": False,
                    "undoable": True,
                },
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool(
            "batch_execute",
            {"commands": [{"command": "create_node", "params": {"type": "Node"}}], "undo": False},
        )
        await task

        assert not result.is_error

    async def test_empty_list_returns_invalid_params_without_plugin_call(self, mcp_stack):
        client, _plugin = mcp_stack
        result = await client.call_tool("batch_execute", {"commands": []})
        assert not result.is_error
        assert result.data["error"]["code"] == "INVALID_PARAMS"
        assert result.data["succeeded"] == 0


# ---------------------------------------------------------------------------
# Per-call session routing via session_id parameter
# ---------------------------------------------------------------------------


class TestPerCallSessionRouting:
    async def _connect_second_plugin(self, session_id: str, readiness: str = "ready"):
        """Connect a second mock plugin to the same MCP stack server."""
        from tests.conftest import MockGodotPlugin

        ws = await websockets.connect("ws://127.0.0.1:19502")
        handshake = {
            "type": "handshake",
            "session_id": session_id,
            "godot_version": "4.4.1",
            "project_path": f"/tmp/{session_id}",
            "plugin_version": "0.0.1",
            "protocol_version": 1,
            "readiness": readiness,
        }
        await ws.send(json.dumps(handshake))
        await asyncio.sleep(0.05)
        return MockGodotPlugin(ws=ws, session_id=session_id)

    async def test_session_id_routes_to_specific_session(self, mcp_stack):
        client, plugin_a = mcp_stack
        ## Rename the implicit session "mcp-test" for clarity: active=proj-a@0001.
        plugin_b = await self._connect_second_plugin("proj-b@0002")
        try:
            ## No session_id -> active (the default mcp-test plugin).
            async def respond_active():
                cmd = await plugin_a.recv_command()
                await plugin_a.send_response(
                    cmd["request_id"],
                    {"scenes": ["res://from_a.tscn"], "current": "res://from_a.tscn"},
                )

            task = asyncio.create_task(respond_active())
            result = await client.call_tool("scene_get_roots", {})
            await task
            assert result.data["current"] == "res://from_a.tscn"

            ## session_id="proj-b@0002" -> routed to plugin_b, not plugin_a.
            async def respond_b():
                cmd = await plugin_b.recv_command()
                await plugin_b.send_response(
                    cmd["request_id"],
                    {"scenes": ["res://from_b.tscn"], "current": "res://from_b.tscn"},
                )

            task = asyncio.create_task(respond_b())
            result = await client.call_tool("scene_get_roots", {"session_id": "proj-b@0002"})
            await task
            assert result.data["current"] == "res://from_b.tscn"
        finally:
            await plugin_b.close()

    async def test_session_id_respects_target_readiness(self, mcp_stack):
        client, plugin_a = mcp_stack
        ## Active session (plugin_a/mcp-test) is ready; plugin_b is playing.
        plugin_b = await self._connect_second_plugin("proj-b@0002", readiness="playing")
        try:
            ## require_writable must see the bound session's readiness, not active.
            result = await client.call_tool(
                "node_create",
                {"type": "Node3D", "name": "Blocked", "session_id": "proj-b@0002"},
                raise_on_error=False,
            )
            assert result.is_error
            assert "EDITOR_NOT_READY" in str(result.content)
        finally:
            await plugin_b.close()


# ---------------------------------------------------------------------------
# JSON-string coercion for list params (issue #11 — Claude Code MCP client
# stringifies complex-typed args before sending)
# ---------------------------------------------------------------------------


class TestJsonStringParamCoercion:
    async def test_batch_execute_accepts_stringified_commands(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "batch_execute"
            assert cmd["params"]["commands"] == [
                {"command": "create_node", "params": {"type": "Node3D", "name": "X"}}
            ]
            await plugin.send_response(
                cmd["request_id"],
                {
                    "succeeded": 1,
                    "stopped_at": None,
                    "results": [
                        {"command": "create_node", "status": "ok", "data": {"undoable": True}}
                    ],
                    "undo": True,
                    "rolled_back": False,
                    "undoable": True,
                },
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool(
            "batch_execute",
            {
                "commands": json.dumps(
                    [{"command": "create_node", "params": {"type": "Node3D", "name": "X"}}]
                )
            },
        )
        await task
        assert not result.is_error
        assert result.data["succeeded"] == 1

    async def test_editor_selection_set_accepts_stringified_paths(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
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
            {"paths": json.dumps(["/Main/Camera3D", "/Main/World"])},
        )
        await task
        assert result.data["count"] == 2

    async def test_filesystem_reimport_accepts_stringified_paths(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["params"]["paths"] == ["res://a.png", "res://b.png"]
            await plugin.send_response(
                cmd["request_id"],
                {"reimported": ["res://a.png", "res://b.png"], "count": 2},
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool(
            "filesystem_reimport",
            {"paths": json.dumps(["res://a.png", "res://b.png"])},
        )
        await task
        assert result.data["count"] == 2

    async def test_performance_monitors_get_accepts_stringified_monitors(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["params"]["monitors"] == ["time/fps"]
            await plugin.send_response(
                cmd["request_id"], {"monitors": {"time/fps": 60}, "missing": []}
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool(
            "performance_monitors_get",
            {"monitors": json.dumps(["time/fps"])},
        )
        await task
        assert result.data["monitors"]["time/fps"] == 60

    async def test_real_list_still_works(self, mcp_stack):
        """Regression check — passing actual lists must continue to work."""
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["params"]["paths"] == ["res://x.png"]
            await plugin.send_response(
                cmd["request_id"], {"reimported": ["res://x.png"], "count": 1}
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool(
            "filesystem_reimport",
            {"paths": ["res://x.png"]},
        )
        await task
        assert result.data["count"] == 1

    async def test_malformed_json_string_still_raises_validation(self, mcp_stack):
        """A non-JSON string must fall through and fail pydantic validation."""
        client, _plugin = mcp_stack
        result = await client.call_tool(
            "filesystem_reimport",
            {"paths": "not-json-at-all"},
            raise_on_error=False,
        )
        assert result.is_error
        error_text = str(result.content).lower()
        assert "paths" in error_text
        assert "input should be a valid list" in error_text or "list_type" in error_text


# ---------------------------------------------------------------------------
# ui_set_anchor_preset
# ---------------------------------------------------------------------------


class TestUiSetAnchorPresetTool:
    async def test_defaults_resize_mode_and_margin(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "set_anchor_preset"
            assert cmd["params"] == {
                "path": "/Main/HUD",
                "preset": "full_rect",
                "resize_mode": "minsize",
                "margin": 0,
            }
            await plugin.send_response(
                cmd["request_id"],
                {
                    "path": "/Main/HUD",
                    "preset": "full_rect",
                    "resize_mode": "minsize",
                    "margin": 0,
                    "anchors": {"left": 0.0, "top": 0.0, "right": 1.0, "bottom": 1.0},
                    "offsets": {"left": 0.0, "top": 0.0, "right": 0.0, "bottom": 0.0},
                    "undoable": True,
                },
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool(
            "ui_set_anchor_preset",
            {"path": "/Main/HUD", "preset": "full_rect"},
        )
        await task

        assert result.data["preset"] == "full_rect"
        assert result.data["anchors"]["right"] == 1.0
        assert result.data["undoable"] is True

    async def test_passes_resize_mode_and_margin(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["params"]["resize_mode"] == "keep_size"
            assert cmd["params"]["margin"] == 16
            await plugin.send_response(
                cmd["request_id"],
                {
                    "path": "/Main/HUD/Panel",
                    "preset": "center",
                    "resize_mode": "keep_size",
                    "margin": 16,
                    "anchors": {"left": 0.5, "top": 0.5, "right": 0.5, "bottom": 0.5},
                    "offsets": {"left": -50.0, "top": -25.0, "right": 50.0, "bottom": 25.0},
                    "undoable": True,
                },
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool(
            "ui_set_anchor_preset",
            {
                "path": "/Main/HUD/Panel",
                "preset": "center",
                "resize_mode": "keep_size",
                "margin": 16,
            },
        )
        await task

        assert result.data["margin"] == 16
        assert result.data["resize_mode"] == "keep_size"


# ---------------------------------------------------------------------------
# ui_set_text
# ---------------------------------------------------------------------------


class TestUiSetTextTool:
    async def test_forwards_path_and_text(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "set_text"
            assert cmd["params"] == {"path": "/Main/HUD/Score", "text": "100"}
            await plugin.send_response(
                cmd["request_id"],
                {
                    "path": "/Main/HUD/Score",
                    "text": "100",
                    "old_text": "0",
                    "node_type": "Label",
                    "undoable": True,
                },
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool(
            "ui_set_text",
            {"path": "/Main/HUD/Score", "text": "100"},
        )
        await task

        assert result.data["text"] == "100"
        assert result.data["old_text"] == "0"
        assert result.data["node_type"] == "Label"
        assert result.data["undoable"] is True

    async def test_surfaces_plugin_error(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            await plugin.send_error(
                cmd["request_id"],
                "INVALID_PARAMS",
                "Node /Main/Camera3D is not a Control (got Camera3D)",
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool(
            "ui_set_text",
            {"path": "/Main/Camera3D", "text": "x"},
            raise_on_error=False,
        )
        await task

        assert result.is_error
        assert "not a Control" in str(result.content)


# ---------------------------------------------------------------------------
# ui_build_layout
# ---------------------------------------------------------------------------


class TestUiBuildLayoutTool:
    async def test_forwards_tree_and_parent(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "build_layout"
            assert cmd["params"]["tree"]["type"] == "VBoxContainer"
            assert cmd["params"]["parent_path"] == "/Main/HUD"
            await plugin.send_response(
                cmd["request_id"],
                {
                    "root_path": "/Main/HUD/PauseMenu",
                    "node_count": 4,
                    "undoable": True,
                },
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool(
            "ui_build_layout",
            {
                "tree": {
                    "type": "VBoxContainer",
                    "name": "PauseMenu",
                    "children": [
                        {"type": "Label", "properties": {"text": "Paused"}},
                        {"type": "Button", "properties": {"text": "Resume"}},
                    ],
                },
                "parent_path": "/Main/HUD",
            },
        )
        await task

        assert result.data["node_count"] == 4
        assert result.data["undoable"] is True

    async def test_accepts_stringified_tree_via_json_coercion(self, mcp_stack):
        """Some MCP clients stringify complex args — JsonCoerced must decode them."""
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            # After JsonCoerced, the tree is a real dict, not a string.
            assert cmd["params"]["tree"]["type"] == "Panel"
            await plugin.send_response(
                cmd["request_id"],
                {"root_path": "/Panel", "node_count": 1, "undoable": True},
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool(
            "ui_build_layout",
            {"tree": '{"type": "Panel"}'},
        )
        await task
        assert result.data["node_count"] == 1


# ---------------------------------------------------------------------------
# theme_create / theme_set_* / theme_apply
# ---------------------------------------------------------------------------


class TestThemeCreateTool:
    async def test_create_theme(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "create_theme"
            assert cmd["params"] == {
                "path": "res://ui/themes/game.tres",
                "overwrite": False,
            }
            await plugin.send_response(
                cmd["request_id"],
                {
                    "path": "res://ui/themes/game.tres",
                    "overwritten": False,
                    "undoable": False,
                    "reason": "File creation is persistent",
                },
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool("theme_create", {"path": "res://ui/themes/game.tres"})
        await task
        assert result.data["path"] == "res://ui/themes/game.tres"


class TestThemeSetColorTool:
    async def test_set_color_hex(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "theme_set_color"
            assert cmd["params"]["value"] == "#e0e0ff"
            await plugin.send_response(
                cmd["request_id"],
                {
                    "path": "res://ui/themes/game.tres",
                    "kind": "color",
                    "class_name": "Label",
                    "name": "font_color",
                    "value": {"r": 0.88, "g": 0.88, "b": 1.0, "a": 1.0},
                    "previous_value": None,
                    "undoable": True,
                },
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool(
            "theme_set_color",
            {
                "theme_path": "res://ui/themes/game.tres",
                "class_name": "Label",
                "name": "font_color",
                "value": "#e0e0ff",
            },
        )
        await task
        assert result.data["kind"] == "color"
        assert result.data["undoable"] is True


class TestThemeSetConstantTool:
    async def test_set_constant(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["params"]["value"] == 16
            await plugin.send_response(
                cmd["request_id"],
                {
                    "path": "res://ui/themes/game.tres",
                    "kind": "constant",
                    "class_name": "VBoxContainer",
                    "name": "separation",
                    "value": 16,
                    "previous_value": None,
                    "undoable": True,
                },
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool(
            "theme_set_constant",
            {
                "theme_path": "res://ui/themes/game.tres",
                "class_name": "VBoxContainer",
                "name": "separation",
                "value": 16,
            },
        )
        await task
        assert result.data["value"] == 16


class TestThemeSetFontSizeTool:
    async def test_set_font_size(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["params"]["value"] == 24
            await plugin.send_response(
                cmd["request_id"],
                {
                    "path": "res://ui/themes/game.tres",
                    "kind": "font_size",
                    "class_name": "Label",
                    "name": "font_size",
                    "value": 24,
                    "previous_value": None,
                    "undoable": True,
                },
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool(
            "theme_set_font_size",
            {
                "theme_path": "res://ui/themes/game.tres",
                "class_name": "Label",
                "name": "font_size",
                "value": 24,
            },
        )
        await task
        assert result.data["value"] == 24


class TestThemeSetStyleboxFlatTool:
    async def test_composes_stylebox_fields(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "theme_set_stylebox_flat"
            params = cmd["params"]
            assert params["class_name"] == "Button"
            assert params["name"] == "normal"
            assert params["bg_color"] == "#101820"
            assert params["border_color"] == "#00ffff"
            assert params["corners"] == {"all": 8}
            # Fields not supplied must not be forwarded.
            assert "shadow" not in params
            assert "margins" not in params
            await plugin.send_response(
                cmd["request_id"],
                {
                    "path": "res://ui/themes/game.tres",
                    "class_name": "Button",
                    "name": "normal",
                    "stylebox_class": "StyleBoxFlat",
                    "bg_color": {"r": 0.06, "g": 0.09, "b": 0.13, "a": 1.0},
                    "border": {"top": 2, "bottom": 2, "left": 2, "right": 2},
                    "corners": {"top_left": 8, "top_right": 8, "bottom_left": 8, "bottom_right": 8},
                    "margins": {"top": 0, "bottom": 0, "left": 0, "right": 0},
                    "undoable": True,
                },
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool(
            "theme_set_stylebox_flat",
            {
                "theme_path": "res://ui/themes/game.tres",
                "class_name": "Button",
                "name": "normal",
                "bg_color": "#101820",
                "border_color": "#00ffff",
                "border": {"all": 2},
                "corners": {"all": 8},
            },
        )
        await task
        assert result.data["corners"]["top_left"] == 8

    async def test_nested_dicts_with_overrides_forwarded(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "theme_set_stylebox_flat"
            params = cmd["params"]
            assert params["border"] == {"all": 1, "top": 4, "bottom": 2}
            assert params["corners"] == {"top_left": 12}
            assert params["margins"] == {"top": 16.0}
            assert params["shadow"] == {"color": "#000000", "size": 6}
            await plugin.send_response(
                cmd["request_id"],
                {
                    "path": "res://themes/game.tres",
                    "class_name": "Button",
                    "name": "normal",
                    "stylebox_class": "StyleBoxFlat",
                    "bg_color": {"r": 0, "g": 0, "b": 0, "a": 1},
                    "border": {"top": 4, "bottom": 2, "left": 1, "right": 1},
                    "corners": {
                        "top_left": 12,
                        "top_right": 0,
                        "bottom_left": 0,
                        "bottom_right": 0,
                    },
                    "margins": {"top": 16.0, "bottom": 0, "left": 0, "right": 0},
                    "undoable": True,
                },
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool(
            "theme_set_stylebox_flat",
            {
                "theme_path": "res://themes/game.tres",
                "class_name": "Button",
                "name": "normal",
                "border": {"all": 1, "top": 4, "bottom": 2},
                "corners": {"top_left": 12},
                "margins": {"top": 16.0},
                "shadow": {"color": "#000000", "size": 6},
            },
        )
        await task
        assert result.data["border"]["top"] == 4
        assert result.data["margins"]["top"] == 16.0


class TestThemeApplyTool:
    async def test_apply(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "apply_theme"
            assert cmd["params"] == {
                "node_path": "/Main/HUD",
                "theme_path": "res://ui/themes/game.tres",
            }
            await plugin.send_response(
                cmd["request_id"],
                {
                    "node_path": "/Main/HUD",
                    "theme_path": "res://ui/themes/game.tres",
                    "cleared": False,
                    "undoable": True,
                },
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool(
            "theme_apply",
            {
                "node_path": "/Main/HUD",
                "theme_path": "res://ui/themes/game.tres",
            },
        )
        await task
        assert result.data["cleared"] is False

    async def test_apply_empty_clears(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["params"]["theme_path"] == ""
            await plugin.send_response(
                cmd["request_id"],
                {
                    "node_path": "/Main/HUD",
                    "theme_path": "",
                    "cleared": True,
                    "undoable": True,
                },
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool("theme_apply", {"node_path": "/Main/HUD"})
        await task
        assert result.data["cleared"] is True


# ---------------------------------------------------------------------------
# animation_player_create / animation_create / animation_add_*_track / etc.
# ---------------------------------------------------------------------------


class TestAnimationPlayerCreateTool:
    async def test_create_player(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "animation_player_create"
            assert cmd["params"] == {"parent_path": "/Main", "name": "AnimationPlayer"}
            await plugin.send_response(
                cmd["request_id"],
                {
                    "path": "/Main/AnimationPlayer",
                    "parent_path": "/Main",
                    "name": "AnimationPlayer",
                    "undoable": True,
                },
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool("animation_player_create", {"parent_path": "/Main"})
        await task
        assert result.data["path"] == "/Main/AnimationPlayer"
        assert result.data["undoable"] is True

    async def test_create_player_custom_name(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["params"]["name"] == "MyPlayer"
            await plugin.send_response(
                cmd["request_id"],
                {
                    "path": "/Main/MyPlayer",
                    "parent_path": "/Main",
                    "name": "MyPlayer",
                    "undoable": True,
                },
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool(
            "animation_player_create", {"parent_path": "/Main", "name": "MyPlayer"}
        )
        await task
        assert result.data["name"] == "MyPlayer"


class TestAnimationCreateTool:
    async def test_create_animation(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "animation_create"
            assert cmd["params"]["name"] == "idle"
            assert cmd["params"]["length"] == 1.0
            assert cmd["params"]["loop_mode"] == "linear"
            await plugin.send_response(
                cmd["request_id"],
                {
                    "player_path": "/Main/AP",
                    "name": "idle",
                    "length": 1.0,
                    "loop_mode": "linear",
                    "undoable": True,
                },
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool(
            "animation_create",
            {"player_path": "/Main/AP", "name": "idle", "length": 1.0, "loop_mode": "linear"},
        )
        await task
        assert result.data["loop_mode"] == "linear"

    async def test_create_animation_default_loop(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["params"]["loop_mode"] == "none"
            await plugin.send_response(
                cmd["request_id"],
                {
                    "player_path": "/Main/AP",
                    "name": "run",
                    "length": 0.5,
                    "loop_mode": "none",
                    "undoable": True,
                },
            )

        task = asyncio.create_task(respond())
        await client.call_tool(
            "animation_create", {"player_path": "/Main/AP", "name": "run", "length": 0.5}
        )
        await task


class TestAnimationAddPropertyTrackTool:
    async def test_add_property_track(self, mcp_stack):
        client, plugin = mcp_stack
        keyframes = [
            {"time": 0.0, "value": {"r": 1, "g": 1, "b": 1, "a": 0}},
            {"time": 0.5, "value": {"r": 1, "g": 1, "b": 1, "a": 1}},
        ]

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "animation_add_property_track"
            assert cmd["params"]["track_path"] == "Panel:modulate"
            assert cmd["params"]["interpolation"] == "linear"
            assert len(cmd["params"]["keyframes"]) == 2
            await plugin.send_response(
                cmd["request_id"],
                {
                    "player_path": "/Main/AP",
                    "animation_name": "fade",
                    "track_path": "Panel:modulate",
                    "interpolation": "linear",
                    "keyframe_count": 2,
                    "undoable": True,
                },
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool(
            "animation_add_property_track",
            {
                "player_path": "/Main/AP",
                "animation_name": "fade",
                "track_path": "Panel:modulate",
                "keyframes": keyframes,
            },
        )
        await task
        assert result.data["keyframe_count"] == 2
        assert result.data["undoable"] is True

    async def test_add_property_track_accepts_stringified_keyframes(self, mcp_stack):
        """JsonCoerced must decode string-encoded keyframes from MCP clients."""
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            # After JsonCoerced the keyframes list should be decoded.
            assert isinstance(cmd["params"]["keyframes"], list)
            await plugin.send_response(
                cmd["request_id"],
                {
                    "player_path": "/Main/AP",
                    "animation_name": "anim",
                    "track_path": ".:modulate",
                    "interpolation": "linear",
                    "keyframe_count": 1,
                    "undoable": True,
                },
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool(
            "animation_add_property_track",
            {
                "player_path": "/Main/AP",
                "animation_name": "anim",
                "track_path": ".:modulate",
                "keyframes": '[{"time": 0.0, "value": 1.0}]',
            },
        )
        await task
        assert result.data["keyframe_count"] == 1


class TestAnimationAddMethodTrackTool:
    async def test_add_method_track(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "animation_add_method_track"
            assert cmd["params"]["target_node_path"] == "."
            kf = cmd["params"]["keyframes"][0]
            assert kf["method"] == "queue_free"
            await plugin.send_response(
                cmd["request_id"],
                {
                    "player_path": "/Main/AP",
                    "animation_name": "die",
                    "target_node_path": ".",
                    "keyframe_count": 1,
                    "undoable": True,
                },
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool(
            "animation_add_method_track",
            {
                "player_path": "/Main/AP",
                "animation_name": "die",
                "target_node_path": ".",
                "keyframes": [{"time": 1.0, "method": "queue_free"}],
            },
        )
        await task
        assert result.data["undoable"] is True


class TestAnimationSetAutoplayTool:
    async def test_set_autoplay(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "animation_set_autoplay"
            assert cmd["params"]["animation_name"] == "idle"
            await plugin.send_response(
                cmd["request_id"],
                {
                    "player_path": "/Main/AP",
                    "animation_name": "idle",
                    "previous_autoplay": "",
                    "cleared": False,
                    "undoable": True,
                },
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool(
            "animation_set_autoplay",
            {"player_path": "/Main/AP", "animation_name": "idle"},
        )
        await task
        assert result.data["cleared"] is False

    async def test_set_autoplay_clear(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["params"]["animation_name"] == ""
            await plugin.send_response(
                cmd["request_id"],
                {
                    "player_path": "/Main/AP",
                    "animation_name": "",
                    "previous_autoplay": "idle",
                    "cleared": True,
                    "undoable": True,
                },
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool("animation_set_autoplay", {"player_path": "/Main/AP"})
        await task
        assert result.data["cleared"] is True


class TestAnimationPlaybackTool:
    async def test_play(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "animation_play"
            await plugin.send_response(
                cmd["request_id"],
                {
                    "player_path": "/Main/AP",
                    "animation_name": "idle",
                    "undoable": False,
                    "reason": "Runtime playback state — not saved with scene",
                },
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool(
            "animation_play", {"player_path": "/Main/AP", "animation_name": "idle"}
        )
        await task
        assert result.data["undoable"] is False

    async def test_stop(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "animation_stop"
            await plugin.send_response(
                cmd["request_id"],
                {
                    "player_path": "/Main/AP",
                    "undoable": False,
                    "reason": "Runtime playback state — not saved with scene",
                },
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool("animation_stop", {"player_path": "/Main/AP"})
        await task
        assert result.data["undoable"] is False


class TestAnimationListTool:
    async def test_list(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "animation_list"
            assert cmd["params"]["player_path"] == "/Main/AP"
            await plugin.send_response(
                cmd["request_id"],
                {
                    "player_path": "/Main/AP",
                    "animations": [
                        {"name": "idle", "length": 2.0, "loop_mode": "linear", "track_count": 3},
                    ],
                    "count": 1,
                },
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool("animation_list", {"player_path": "/Main/AP"})
        await task
        assert result.data["count"] == 1
        assert result.data["animations"][0]["name"] == "idle"


class TestAnimationGetTool:
    async def test_get(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "animation_get"
            assert cmd["params"]["animation_name"] == "fade"
            await plugin.send_response(
                cmd["request_id"],
                {
                    "player_path": "/Main/AP",
                    "name": "fade",
                    "length": 0.5,
                    "loop_mode": "none",
                    "track_count": 1,
                    "tracks": [
                        {
                            "index": 0,
                            "type": "value",
                            "path": "Panel:modulate",
                            "interpolation": "linear",
                            "key_count": 2,
                            "keys": [],
                        }
                    ],
                },
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool(
            "animation_get", {"player_path": "/Main/AP", "animation_name": "fade"}
        )
        await task
        assert result.data["name"] == "fade"
        assert result.data["tracks"][0]["type"] == "value"


class TestAnimationCreateSimpleTool:
    async def test_create_simple(self, mcp_stack):
        client, plugin = mcp_stack
        tweens = [
            {
                "target": "Panel",
                "property": "modulate",
                "from": {"r": 1, "g": 1, "b": 1, "a": 0},
                "to": {"r": 1, "g": 1, "b": 1, "a": 1},
                "duration": 0.5,
            }
        ]

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "animation_create_simple"
            assert cmd["params"]["name"] == "fade_in"
            assert len(cmd["params"]["tweens"]) == 1
            assert cmd["params"]["loop_mode"] == "none"
            assert "length" not in cmd["params"]
            await plugin.send_response(
                cmd["request_id"],
                {
                    "player_path": "/Main/AP",
                    "name": "fade_in",
                    "length": 0.5,
                    "loop_mode": "none",
                    "track_count": 1,
                    "undoable": True,
                },
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool(
            "animation_create_simple",
            {"player_path": "/Main/AP", "name": "fade_in", "tweens": tweens},
        )
        await task
        assert result.data["track_count"] == 1
        assert result.data["undoable"] is True

    async def test_create_simple_accepts_stringified_tweens(self, mcp_stack):
        """JsonCoerced must handle string-encoded tweens from MCP clients."""
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert isinstance(cmd["params"]["tweens"], list)
            await plugin.send_response(
                cmd["request_id"],
                {
                    "player_path": "/Main/AP",
                    "name": "pulse",
                    "length": 0.5,
                    "loop_mode": "pingpong",
                    "track_count": 1,
                    "undoable": True,
                },
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool(
            "animation_create_simple",
            {
                "player_path": "/Main/AP",
                "name": "pulse",
                "loop_mode": "pingpong",
                "tweens": (
                    '[{"target":"Button","property":"scale",'
                    '"from":{"x":1,"y":1},"to":{"x":1.1,"y":1.1},"duration":0.4}]'
                ),
            },
        )
        await task
        assert result.data["undoable"] is True


class TestAnimationDeleteTool:
    async def test_delete(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "animation_delete"
            assert cmd["params"]["player_path"] == "/Main/AP"
            assert cmd["params"]["animation_name"] == "idle"
            await plugin.send_response(
                cmd["request_id"],
                {
                    "player_path": "/Main/AP",
                    "animation_name": "idle",
                    "undoable": True,
                },
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool(
            "animation_delete",
            {"player_path": "/Main/AP", "animation_name": "idle"},
        )
        await task
        assert result.data["undoable"] is True


class TestAnimationValidateTool:
    async def test_validate(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "animation_validate"
            assert cmd["params"]["player_path"] == "/Main/AP"
            assert cmd["params"]["animation_name"] == "walk"
            await plugin.send_response(
                cmd["request_id"],
                {
                    "player_path": "/Main/AP",
                    "animation_name": "walk",
                    "track_count": 2,
                    "valid_count": 1,
                    "broken_count": 1,
                    "broken_tracks": [
                        {"index": 1, "path": "Gone:visible", "issue": "node_not_found"},
                    ],
                    "valid": False,
                },
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool(
            "animation_validate",
            {"player_path": "/Main/AP", "animation_name": "walk"},
        )
        await task
        assert result.data["valid"] is False
        assert result.data["broken_count"] == 1


class TestAnimationPresetTools:
    async def test_preset_fade(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "animation_preset_fade"
            assert cmd["params"]["player_path"] == "/Main/AP"
            assert cmd["params"]["target_path"] == "Panel"
            assert cmd["params"]["mode"] == "in"
            assert cmd["params"]["duration"] == 0.5
            # Optional params omitted when not set.
            assert "animation_name" not in cmd["params"]
            assert "overwrite" not in cmd["params"]
            await plugin.send_response(
                cmd["request_id"],
                {
                    "player_path": "/Main/AP",
                    "animation_name": "fade_in",
                    "mode": "in",
                    "length": 0.5,
                    "track_count": 1,
                    "library_created": False,
                    "overwritten": False,
                    "undoable": True,
                },
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool(
            "animation_preset_fade",
            {
                "player_path": "/Main/AP",
                "target_path": "Panel",
                "mode": "in",
                "duration": 0.5,
            },
        )
        await task
        assert result.data["animation_name"] == "fade_in"
        assert result.data["undoable"] is True

    async def test_preset_fade_overwrite_forwards(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["params"]["overwrite"] is True
            assert cmd["params"]["animation_name"] == "hud_flash"
            await plugin.send_response(
                cmd["request_id"],
                {
                    "player_path": "/Main/AP",
                    "animation_name": "hud_flash",
                    "mode": "out",
                    "length": 0.25,
                    "track_count": 1,
                    "library_created": False,
                    "overwritten": True,
                    "undoable": True,
                },
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool(
            "animation_preset_fade",
            {
                "player_path": "/Main/AP",
                "target_path": "HUD",
                "mode": "out",
                "duration": 0.25,
                "animation_name": "hud_flash",
                "overwrite": True,
            },
        )
        await task
        assert result.data["overwritten"] is True

    async def test_preset_slide_forwards_direction_and_distance(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "animation_preset_slide"
            assert cmd["params"]["direction"] == "left"
            assert cmd["params"]["mode"] == "in"
            assert cmd["params"]["distance"] == 250.0
            assert cmd["params"]["duration"] == 0.4
            await plugin.send_response(
                cmd["request_id"],
                {
                    "player_path": "/Main/AP",
                    "animation_name": "slide_in_left",
                    "direction": "left",
                    "mode": "in",
                    "distance": 250.0,
                    "length": 0.4,
                    "track_count": 1,
                    "library_created": False,
                    "overwritten": False,
                    "undoable": True,
                },
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool(
            "animation_preset_slide",
            {
                "player_path": "/Main/AP",
                "target_path": "Menu",
                "direction": "left",
                "mode": "in",
                "distance": 250.0,
            },
        )
        await task
        assert result.data["direction"] == "left"

    async def test_preset_slide_distance_omitted_when_default(self, mcp_stack):
        """`distance=None` means the plugin picks the 2D/3D default — don't leak it."""
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert "distance" not in cmd["params"]
            await plugin.send_response(
                cmd["request_id"],
                {
                    "player_path": "/Main/AP",
                    "animation_name": "slide_in_left",
                    "direction": "left",
                    "mode": "in",
                    "distance": 100.0,
                    "length": 0.4,
                    "track_count": 1,
                    "library_created": False,
                    "overwritten": False,
                    "undoable": True,
                },
            )

        task = asyncio.create_task(respond())
        await client.call_tool(
            "animation_preset_slide",
            {"player_path": "/Main/AP", "target_path": "Menu"},
        )
        await task

    async def test_preset_shake_forwards_seed_and_frequency(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "animation_preset_shake"
            assert cmd["params"]["seed"] == 42
            assert cmd["params"]["frequency"] == 60.0
            assert cmd["params"]["intensity"] == 8.0
            assert cmd["params"]["duration"] == 0.2
            await plugin.send_response(
                cmd["request_id"],
                {
                    "player_path": "/Main/AP",
                    "animation_name": "shake",
                    "length": 0.2,
                    "frequency": 60.0,
                    "intensity": 8.0,
                    "keyframe_count": 13,
                    "track_count": 1,
                    "library_created": False,
                    "overwritten": False,
                    "undoable": True,
                },
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool(
            "animation_preset_shake",
            {
                "player_path": "/Main/AP",
                "target_path": "Camera",
                "intensity": 8.0,
                "duration": 0.2,
                "frequency": 60.0,
                "seed": 42,
            },
        )
        await task
        assert result.data["keyframe_count"] == 13

    async def test_preset_pulse_forwards_scale_bounds(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "animation_preset_pulse"
            assert cmd["params"]["from_scale"] == 1.0
            assert cmd["params"]["to_scale"] == 1.25
            assert cmd["params"]["duration"] == 0.3
            await plugin.send_response(
                cmd["request_id"],
                {
                    "player_path": "/Main/AP",
                    "animation_name": "pulse",
                    "from_scale": 1.0,
                    "to_scale": 1.25,
                    "length": 0.3,
                    "track_count": 1,
                    "library_created": False,
                    "overwritten": False,
                    "undoable": True,
                },
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool(
            "animation_preset_pulse",
            {
                "player_path": "/Main/AP",
                "target_path": "Button",
                "from_scale": 1.0,
                "to_scale": 1.25,
                "duration": 0.3,
            },
        )
        await task
        assert result.data["animation_name"] == "pulse"


# ---------------------------------------------------------------------------
# material_create / material_set_param / material_assign / material_apply_*
# ---------------------------------------------------------------------------


class TestMaterialCreateTool:
    async def test_create_standard(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "material_create"
            assert cmd["params"] == {
                "path": "res://materials/red.tres",
                "type": "standard",
                "overwrite": False,
            }
            await plugin.send_response(
                cmd["request_id"],
                {
                    "path": "res://materials/red.tres",
                    "type": "standard",
                    "class": "StandardMaterial3D",
                    "overwritten": False,
                    "undoable": False,
                },
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool("material_create", {"path": "res://materials/red.tres"})
        await task
        assert result.data["class"] == "StandardMaterial3D"
        assert result.data["undoable"] is False

    async def test_create_shader_forwards_shader_path(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["params"]["type"] == "shader"
            assert cmd["params"]["shader_path"] == "res://shaders/pulse.gdshader"
            await plugin.send_response(
                cmd["request_id"],
                {
                    "path": "res://mat/shader.tres",
                    "type": "shader",
                    "class": "ShaderMaterial",
                    "shader_path": "res://shaders/pulse.gdshader",
                    "overwritten": False,
                    "undoable": False,
                },
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool(
            "material_create",
            {
                "path": "res://mat/shader.tres",
                "type": "shader",
                "shader_path": "res://shaders/pulse.gdshader",
            },
        )
        await task
        assert result.data["shader_path"] == "res://shaders/pulse.gdshader"


class TestMaterialSetParamTool:
    async def test_set_color(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "material_set_param"
            assert cmd["params"]["property"] == "albedo_color"
            assert cmd["params"]["value"] == "#ff0000"
            await plugin.send_response(
                cmd["request_id"],
                {
                    "path": "res://materials/red.tres",
                    "property": "albedo_color",
                    "value": {"r": 1, "g": 0, "b": 0, "a": 1},
                    "previous_value": {"r": 1, "g": 1, "b": 1, "a": 1},
                    "undoable": True,
                },
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool(
            "material_set_param",
            {
                "path": "res://materials/red.tres",
                "property": "albedo_color",
                "value": "#ff0000",
            },
        )
        await task
        assert result.data["undoable"] is True


class TestMaterialSetShaderParamTool:
    async def test_set_shader_uniform(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "material_set_shader_param"
            assert cmd["params"]["param"] == "pulse_strength"
            assert cmd["params"]["value"] == 0.75
            await plugin.send_response(
                cmd["request_id"],
                {
                    "path": "res://mat/shader.tres",
                    "param": "pulse_strength",
                    "value": 0.75,
                    "previous_value": 0.0,
                    "undoable": True,
                },
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool(
            "material_set_shader_param",
            {
                "path": "res://mat/shader.tres",
                "param": "pulse_strength",
                "value": 0.75,
            },
        )
        await task
        assert result.data["param"] == "pulse_strength"


class TestMaterialAssignTool:
    async def test_assign_resource(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "material_assign"
            assert cmd["params"]["slot"] == "override"
            await plugin.send_response(
                cmd["request_id"],
                {
                    "node_path": "/Main/Box",
                    "property": "material_override",
                    "slot": "override",
                    "resource_path": "res://materials/red.tres",
                    "material_class": "StandardMaterial3D",
                    "material_created": False,
                    "undoable": True,
                },
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool(
            "material_assign",
            {
                "node_path": "/Main/Box",
                "resource_path": "res://materials/red.tres",
            },
        )
        await task
        assert result.data["material_created"] is False


class TestMaterialGetTool:
    async def test_get_material(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "material_get"
            assert cmd["params"] == {"path": "res://materials/red.tres"}
            await plugin.send_response(
                cmd["request_id"],
                {
                    "path": "res://materials/red.tres",
                    "class": "StandardMaterial3D",
                    "type": "standard",
                    "properties": [
                        {
                            "name": "albedo_color",
                            "type": "Color",
                            "value": {"r": 1, "g": 0, "b": 0, "a": 1},
                        }
                    ],
                    "property_count": 1,
                    "shader_parameters": [],
                    "shader_path": "",
                },
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool("material_get", {"path": "res://materials/red.tres"})
        await task
        assert result.data["class"] == "StandardMaterial3D"


class TestMaterialListTool:
    async def test_list_materials(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "material_list"
            assert cmd["params"]["root"] == "res://materials"
            assert cmd["params"]["type"] == "StandardMaterial3D"
            await plugin.send_response(
                cmd["request_id"],
                {
                    "materials": [
                        {"path": "res://materials/red.tres", "class": "StandardMaterial3D"},
                    ],
                    "count": 1,
                },
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool(
            "material_list",
            {"root": "res://materials", "type": "StandardMaterial3D"},
        )
        await task
        assert result.data["count"] == 1


class TestMaterialApplyToNodeTool:
    async def test_apply_inline(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "material_apply_to_node"
            assert cmd["params"]["params"] == {
                "albedo_color": "#00ff00",
                "metallic": 0.5,
            }
            await plugin.send_response(
                cmd["request_id"],
                {
                    "node_path": "/Main/Box",
                    "property": "material_override",
                    "slot": "override",
                    "type": "standard",
                    "class": "StandardMaterial3D",
                    "applied_params": ["albedo_color", "metallic"],
                    "material_created": True,
                    "saved_to": "",
                    "undoable": True,
                },
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool(
            "material_apply_to_node",
            {
                "node_path": "/Main/Box",
                "params": {"albedo_color": "#00ff00", "metallic": 0.5},
            },
        )
        await task
        assert "albedo_color" in result.data["applied_params"]


class TestMaterialApplyPresetTool:
    async def test_apply_glass_preset(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "material_apply_preset"
            assert cmd["params"]["preset"] == "glass"
            await plugin.send_response(
                cmd["request_id"],
                {
                    "preset": "glass",
                    "type": "standard",
                    "path": "",
                    "node_path": "/Main/Box",
                    "material_created": True,
                    "assigned": True,
                    "saved_to_disk": False,
                    "undoable": True,
                    "reason": "",
                },
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool(
            "material_apply_preset",
            {"preset": "glass", "node_path": "/Main/Box"},
        )
        await task
        assert result.data["assigned"] is True


# ---------------------------------------------------------------------------
# particle_create / particle_set_* / particle_apply_preset
# ---------------------------------------------------------------------------


class TestParticleCreateTool:
    async def test_create_gpu_3d(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "particle_create"
            assert cmd["params"] == {
                "parent_path": "/Main",
                "name": "Fire",
                "type": "gpu_3d",
            }
            await plugin.send_response(
                cmd["request_id"],
                {
                    "path": "/Main/Fire",
                    "parent_path": "/Main",
                    "name": "Fire",
                    "type": "gpu_3d",
                    "class": "GPUParticles3D",
                    "process_material_created": True,
                    "draw_pass_mesh_created": True,
                    "undoable": True,
                },
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool("particle_create", {"parent_path": "/Main", "name": "Fire"})
        await task
        assert result.data["process_material_created"] is True
        assert result.data["draw_pass_mesh_created"] is True


class TestParticleSetMainTool:
    async def test_set_main_props(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "particle_set_main"
            assert cmd["params"]["properties"]["amount"] == 120
            await plugin.send_response(
                cmd["request_id"],
                {
                    "path": "/Main/Fire",
                    "applied": ["amount", "lifetime"],
                    "values": {"amount": 120, "lifetime": 2.0},
                    "undoable": True,
                },
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool(
            "particle_set_main",
            {
                "node_path": "/Main/Fire",
                "properties": {"amount": 120, "lifetime": 2.0},
            },
        )
        await task
        assert result.data["values"]["amount"] == 120


class TestParticleSetProcessTool:
    async def test_color_ramp_forwarded(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "particle_set_process"
            ramp = cmd["params"]["properties"]["color_ramp"]
            assert ramp["stops"][0]["color"] == [1, 1, 1, 1]
            await plugin.send_response(
                cmd["request_id"],
                {
                    "path": "/Main/Fire",
                    "applied": ["color_ramp"],
                    "values": {"color_ramp": {"type": "GradientTexture1D", "stops": []}},
                    "process_material_created": False,
                    "undoable": True,
                },
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool(
            "particle_set_process",
            {
                "node_path": "/Main/Fire",
                "properties": {
                    "color_ramp": {"stops": [{"time": 0, "color": [1, 1, 1, 1]}]},
                },
            },
        )
        await task
        assert "color_ramp" in result.data["applied"]


class TestParticleSetDrawPassTool:
    async def test_set_draw_pass_forwards_pass_and_mesh(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "particle_set_draw_pass"
            assert cmd["params"]["pass"] == 2
            assert cmd["params"]["mesh"] == "res://meshes/spark.mesh"
            assert "texture" not in cmd["params"]
            assert "material" not in cmd["params"]
            await plugin.send_response(
                cmd["request_id"],
                {
                    "path": "/Main/Fire",
                    "pass": 2,
                    "mesh_path": "res://meshes/spark.mesh",
                    "mesh_class": "Mesh",
                    "material_path": "",
                    "draw_pass_mesh_created": False,
                    "undoable": True,
                },
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool(
            "particle_set_draw_pass",
            {
                "node_path": "/Main/Fire",
                "pass_": 2,
                "mesh": "res://meshes/spark.mesh",
            },
        )
        await task
        assert result.data["pass"] == 2


class TestParticleApplyPresetTool:
    async def test_apply_fire(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "particle_apply_preset"
            assert cmd["params"]["preset"] == "fire"
            assert cmd["params"]["type"] == "gpu_3d"
            await plugin.send_response(
                cmd["request_id"],
                {
                    "path": "/Main/Fire",
                    "parent_path": "/Main",
                    "name": "Fire",
                    "preset": "fire",
                    "type": "gpu_3d",
                    "class": "GPUParticles3D",
                    "applied_main": ["amount", "lifetime"],
                    "applied_process": ["emission_shape", "color_ramp"],
                    "process_material_created": True,
                    "draw_pass_mesh_created": True,
                    "is_3d": True,
                    "undoable": True,
                },
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool(
            "particle_apply_preset",
            {"parent_path": "/Main", "name": "Fire", "preset": "fire"},
        )
        await task
        assert result.data["process_material_created"] is True
        assert "color_ramp" in result.data["applied_process"]


class TestParticleRestartTool:
    async def test_restart_is_not_undoable(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "particle_restart"
            await plugin.send_response(
                cmd["request_id"],
                {
                    "path": "/Main/Fire",
                    "undoable": False,
                    "reason": "Restart is a runtime operation",
                },
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool("particle_restart", {"node_path": "/Main/Fire"})
        await task
        assert result.data["undoable"] is False


class TestParticleGetTool:
    async def test_get_returns_structured_snapshot(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "particle_get"
            await plugin.send_response(
                cmd["request_id"],
                {
                    "path": "/Main/Fire",
                    "type": "gpu_3d",
                    "class": "GPUParticles3D",
                    "main": {"amount": 80, "lifetime": 1.2},
                    "process": {
                        "class": "ParticleProcessMaterial",
                        "properties": {"emission_shape": 1},
                    },
                    "draw_passes": [
                        {"pass": 1, "mesh_class": "QuadMesh"},
                        {"pass": 2, "mesh_class": ""},
                        {"pass": 3, "mesh_class": ""},
                        {"pass": 4, "mesh_class": ""},
                    ],
                    "texture_path": "",
                },
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool("particle_get", {"node_path": "/Main/Fire"})
        await task
        assert result.data["main"]["amount"] == 80
        assert result.data["draw_passes"][0]["mesh_class"] == "QuadMesh"


# ---------------------------------------------------------------------------
# camera_*
# ---------------------------------------------------------------------------


class TestCameraCreateTool:
    async def test_create_2d_forwards_params(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "camera_create"
            assert cmd["params"] == {
                "parent_path": "/Main",
                "name": "Cam",
                "type": "2d",
                "make_current": False,
            }
            await plugin.send_response(
                cmd["request_id"],
                {
                    "path": "/Main/Cam",
                    "parent_path": "/Main",
                    "name": "Cam",
                    "type": "2d",
                    "class": "Camera2D",
                    "current": False,
                    "undoable": True,
                },
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool("camera_create", {"parent_path": "/Main", "name": "Cam"})
        await task
        assert result.data["class"] == "Camera2D"

    async def test_create_3d_with_make_current(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "camera_create"
            assert cmd["params"]["type"] == "3d"
            assert cmd["params"]["make_current"] is True
            await plugin.send_response(
                cmd["request_id"],
                {
                    "path": "/Main/Cam3D",
                    "parent_path": "/Main",
                    "name": "Cam3D",
                    "type": "3d",
                    "class": "Camera3D",
                    "current": True,
                    "undoable": True,
                },
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool(
            "camera_create",
            {
                "parent_path": "/Main",
                "name": "Cam3D",
                "type": "3d",
                "make_current": True,
            },
        )
        await task
        assert result.data["current"] is True


class TestCameraConfigureTool:
    async def test_zoom_vector_forwarded(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "camera_configure"
            assert cmd["params"]["properties"]["zoom"] == {"x": 2.0, "y": 2.0}
            await plugin.send_response(
                cmd["request_id"],
                {
                    "path": "/Main/Cam",
                    "type": "2d",
                    "class": "Camera2D",
                    "applied": ["zoom"],
                    "values": {"zoom": {"x": 2.0, "y": 2.0}},
                    "undoable": True,
                },
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool(
            "camera_configure",
            {
                "camera_path": "/Main/Cam",
                "properties": {"zoom": {"x": 2.0, "y": 2.0}},
            },
        )
        await task
        assert "zoom" in result.data["applied"]

    async def test_enum_by_name_forwarded(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["params"]["properties"]["keep_aspect"] == "keep_height"
            await plugin.send_response(
                cmd["request_id"],
                {
                    "path": "/Main/Cam3D",
                    "type": "3d",
                    "class": "Camera3D",
                    "applied": ["keep_aspect"],
                    "values": {"keep_aspect": 1},
                    "undoable": True,
                },
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool(
            "camera_configure",
            {
                "camera_path": "/Main/Cam3D",
                "properties": {"keep_aspect": "keep_height"},
            },
        )
        await task
        assert result.data["applied"] == ["keep_aspect"]


class TestCameraSetLimits2DTool:
    async def test_partial_limits(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "camera_set_limits_2d"
            assert cmd["params"] == {
                "camera_path": "/Main/Cam",
                "left": -500,
                "right": 500,
            }
            await plugin.send_response(
                cmd["request_id"],
                {
                    "path": "/Main/Cam",
                    "applied": ["limit_left", "limit_right"],
                    "values": {"limit_left": -500, "limit_right": 500},
                    "undoable": True,
                },
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool(
            "camera_set_limits_2d",
            {"camera_path": "/Main/Cam", "left": -500, "right": 500},
        )
        await task
        assert "limit_left" in result.data["applied"]


class TestCameraSetDamping2DTool:
    async def test_forwards_all_params(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "camera_set_damping_2d"
            params = cmd["params"]
            assert params["position_speed"] == 4.0
            assert params["rotation_speed"] == 3.0
            assert params["drag_margins"] == {"left": 0.2, "right": 0.2}
            assert params["drag_horizontal_enabled"] is True
            await plugin.send_response(
                cmd["request_id"],
                {
                    "path": "/Main/Cam",
                    "applied": [
                        "position_smoothing_enabled",
                        "position_smoothing_speed",
                        "rotation_smoothing_enabled",
                        "rotation_smoothing_speed",
                        "drag_horizontal_enabled",
                        "drag_left_margin",
                        "drag_right_margin",
                    ],
                    "values": {},
                    "undoable": True,
                },
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool(
            "camera_set_damping_2d",
            {
                "camera_path": "/Main/Cam",
                "position_speed": 4.0,
                "rotation_speed": 3.0,
                "drag_margins": {"left": 0.2, "right": 0.2},
                "drag_horizontal_enabled": True,
            },
        )
        await task
        assert "position_smoothing_speed" in result.data["applied"]

    async def test_only_position_speed(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            # Only camera_path + position_speed should be forwarded.
            assert cmd["params"] == {
                "camera_path": "/Main/Cam",
                "position_speed": 5.0,
            }
            await plugin.send_response(
                cmd["request_id"],
                {"path": "/Main/Cam", "applied": [], "values": {}, "undoable": True},
            )

        task = asyncio.create_task(respond())
        await client.call_tool(
            "camera_set_damping_2d",
            {"camera_path": "/Main/Cam", "position_speed": 5.0},
        )
        await task


class TestCameraFollow2DTool:
    async def test_forwards_target(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "camera_follow_2d"
            assert cmd["params"] == {
                "camera_path": "/Main/Cam",
                "target_path": "/Main/Player",
                "smoothing_speed": 6.0,
                "zero_transform": True,
            }
            await plugin.send_response(
                cmd["request_id"],
                {
                    "path": "/Main/Player/Cam",
                    "target_path": "/Main/Player",
                    "reparented": True,
                    "smoothing_speed": 6.0,
                    "zero_transform": True,
                    "undoable": True,
                },
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool(
            "camera_follow_2d",
            {
                "camera_path": "/Main/Cam",
                "target_path": "/Main/Player",
                "smoothing_speed": 6.0,
            },
        )
        await task
        assert result.data["reparented"] is True


class TestCameraGetTool:
    async def test_get_current_via_empty_path(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "camera_get"
            assert cmd["params"] == {"camera_path": ""}
            await plugin.send_response(
                cmd["request_id"],
                {
                    "path": "/Main/Cam",
                    "type": "2d",
                    "class": "Camera2D",
                    "current": True,
                    "properties": {"zoom": {"x": 2.0, "y": 2.0}},
                    "resolved_via": "current",
                },
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool("camera_get", {})
        await task
        assert result.data["resolved_via"] == "current"


class TestCameraListTool:
    async def test_list_enumerates(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "camera_list"
            await plugin.send_response(
                cmd["request_id"],
                {
                    "cameras": [
                        {
                            "path": "/Main/Cam2D",
                            "class": "Camera2D",
                            "type": "2d",
                            "current": True,
                        },
                        {
                            "path": "/Main/Cam3D",
                            "class": "Camera3D",
                            "type": "3d",
                            "current": False,
                        },
                    ],
                },
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool("camera_list", {})
        await task
        assert len(result.data["cameras"]) == 2


class TestCameraApplyPresetTool:
    async def test_topdown_2d(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "camera_apply_preset"
            assert cmd["params"]["preset"] == "topdown_2d"
            assert cmd["params"]["make_current"] is True
            await plugin.send_response(
                cmd["request_id"],
                {
                    "path": "/Main/Cam",
                    "parent_path": "/Main",
                    "name": "Cam",
                    "preset": "topdown_2d",
                    "type": "2d",
                    "class": "Camera2D",
                    "applied": ["zoom", "anchor_mode", "position_smoothing_enabled"],
                    "current": True,
                    "undoable": True,
                },
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool(
            "camera_apply_preset",
            {
                "parent_path": "/Main",
                "name": "Cam",
                "preset": "topdown_2d",
            },
        )
        await task
        assert result.data["preset"] == "topdown_2d"
        assert result.data["current"] is True

    async def test_overrides_forwarded(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["params"]["overrides"] == {"zoom": {"x": 3.0, "y": 3.0}}
            await plugin.send_response(
                cmd["request_id"],
                {
                    "path": "/Main/Cam",
                    "parent_path": "/Main",
                    "name": "Cam",
                    "preset": "topdown_2d",
                    "type": "2d",
                    "class": "Camera2D",
                    "applied": ["zoom"],
                    "current": True,
                    "undoable": True,
                },
            )

        task = asyncio.create_task(respond())
        await client.call_tool(
            "camera_apply_preset",
            {
                "parent_path": "/Main",
                "name": "Cam",
                "preset": "topdown_2d",
                "overrides": {"zoom": {"x": 3.0, "y": 3.0}},
            },
        )
        await task
# audio_player_create / audio_player_set_stream / audio_play / audio_stop / audio_list
# ---------------------------------------------------------------------------


class TestAudioPlayerCreateTool:
    async def test_create_3d(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "audio_player_create"
            assert cmd["params"] == {
                "parent_path": "/Main",
                "name": "Footsteps",
                "type": "3d",
            }
            await plugin.send_response(
                cmd["request_id"],
                {
                    "path": "/Main/Footsteps",
                    "parent_path": "/Main",
                    "name": "Footsteps",
                    "type": "3d",
                    "class": "AudioStreamPlayer3D",
                    "undoable": True,
                },
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool(
            "audio_player_create",
            {"parent_path": "/Main", "name": "Footsteps", "type": "3d"},
        )
        await task
        assert result.data["class"] == "AudioStreamPlayer3D"
        assert result.data["undoable"] is True


class TestAudioPlayerSetStreamTool:
    async def test_set_stream_forwards_path(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "audio_player_set_stream"
            assert cmd["params"] == {
                "player_path": "/Main/Footsteps",
                "stream_path": "res://sfx/step.ogg",
            }
            await plugin.send_response(
                cmd["request_id"],
                {
                    "player_path": "/Main/Footsteps",
                    "stream_path": "res://sfx/step.ogg",
                    "stream_class": "AudioStreamOggVorbis",
                    "duration_seconds": 0.42,
                    "undoable": True,
                },
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool(
            "audio_player_set_stream",
            {"player_path": "/Main/Footsteps", "stream_path": "res://sfx/step.ogg"},
        )
        await task
        assert result.data["stream_class"] == "AudioStreamOggVorbis"
        assert result.data["duration_seconds"] == 0.42


class TestAudioPlayerSetPlaybackTool:
    async def test_partial_update_omits_none_fields(self, mcp_stack):
        """Only fields the caller passes should end up on the wire."""
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "audio_player_set_playback"
            assert cmd["params"] == {"player_path": "/Main/Music", "volume_db": -3.0}
            await plugin.send_response(
                cmd["request_id"],
                {
                    "player_path": "/Main/Music",
                    "applied": ["volume_db"],
                    "values": {"volume_db": -3.0},
                    "undoable": True,
                },
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool(
            "audio_player_set_playback",
            {"player_path": "/Main/Music", "volume_db": -3.0},
        )
        await task
        assert result.data["applied"] == ["volume_db"]


class TestAudioPlayTool:
    async def test_play_is_runtime_only(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "audio_play"
            assert cmd["params"] == {
                "player_path": "/Main/Footsteps",
                "from_position": 0.0,
            }
            await plugin.send_response(
                cmd["request_id"],
                {
                    "player_path": "/Main/Footsteps",
                    "from_position": 0.0,
                    "playing": True,
                    "undoable": False,
                    "reason": "Runtime playback state — not saved with scene",
                },
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool("audio_play", {"player_path": "/Main/Footsteps"})
        await task
        assert result.data["undoable"] is False
        assert result.data["playing"] is True


class TestAudioStopTool:
    async def test_stop(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "audio_stop"
            await plugin.send_response(
                cmd["request_id"],
                {
                    "player_path": "/Main/Footsteps",
                    "playing": False,
                    "undoable": False,
                    "reason": "Runtime playback state — not saved with scene",
                },
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool("audio_stop", {"player_path": "/Main/Footsteps"})
        await task
        assert result.data["playing"] is False


class TestAudioListTool:
    async def test_list_returns_streams(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "audio_list"
            assert cmd["params"] == {"root": "res://", "include_duration": True}
            await plugin.send_response(
                cmd["request_id"],
                {
                    "root": "res://",
                    "streams": [
                        {
                            "path": "res://sfx/click.ogg",
                            "class": "AudioStreamOggVorbis",
                            "duration_seconds": 0.1,
                        }
                    ],
                    "count": 1,
                },
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool("audio_list", {})
        await task
        assert result.data["count"] == 1
        assert result.data["streams"][0]["class"] == "AudioStreamOggVorbis"

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
            await plugin.send_response(
                cmd["request_id"], {"passed": 3, "failed": 0, "results": []}
            )

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
            await plugin.send_response(
                cmd["request_id"], {"passed": 2, "failed": 0, "results": []}
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool("run_tests", {"suite": "scene"})
        await task
        assert result.data["passed"] == 2

    async def test_get_test_results(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "get_test_results"
            await plugin.send_response(
                cmd["request_id"], {"passed": 5, "failed": 1, "results": []}
            )

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

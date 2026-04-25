"""Integration tests: MCP resources through the full FastMCP stack with mock Godot plugin."""

from __future__ import annotations

import asyncio
import json


def _parse_resource(result) -> dict:
    """Extract JSON dict from a ReadResourceResult."""
    return json.loads(result[0].text)


# ---------------------------------------------------------------------------
# godot://sessions
# ---------------------------------------------------------------------------


class TestSessionsResource:
    async def test_returns_connected_session(self, mcp_stack):
        client, plugin = mcp_stack
        result = await client.read_resource("godot://sessions")
        data = _parse_resource(result)

        assert data["count"] == 1
        assert data["sessions"][0]["session_id"] == "mcp-test"
        assert data["sessions"][0]["godot_version"] == "4.4.1"
        assert data["sessions"][0]["is_active"] is True


# ---------------------------------------------------------------------------
# godot://scene/current
# ---------------------------------------------------------------------------


class TestSceneCurrentResource:
    async def test_returns_current_scene(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "get_editor_state"
            await plugin.send_response(
                cmd["request_id"],
                {
                    "current_scene": "res://level1.tscn",
                    "project_name": "MyGame",
                    "is_playing": True,
                },
            )

        task = asyncio.create_task(respond())
        result = await client.read_resource("godot://scene/current")
        await task

        data = _parse_resource(result)
        assert data["current_scene"] == "res://level1.tscn"
        assert data["project_name"] == "MyGame"
        assert data["is_playing"] is True


# ---------------------------------------------------------------------------
# godot://scene/hierarchy
# ---------------------------------------------------------------------------


class TestSceneHierarchyResource:
    async def test_returns_full_tree(self, mcp_stack):
        client, plugin = mcp_stack
        nodes = [
            {"name": "Main", "type": "Node3D", "path": "/Main"},
            {"name": "Camera", "type": "Camera3D", "path": "/Main/Camera"},
        ]

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "get_scene_tree"
            assert cmd["params"]["depth"] == 10
            await plugin.send_response(cmd["request_id"], {"nodes": nodes, "total_count": 2})

        task = asyncio.create_task(respond())
        result = await client.read_resource("godot://scene/hierarchy")
        await task

        data = _parse_resource(result)
        assert len(data["nodes"]) == 2
        assert data["nodes"][0]["name"] == "Main"


# ---------------------------------------------------------------------------
# godot://selection/current
# ---------------------------------------------------------------------------


class TestSelectionCurrentResource:
    async def test_returns_selected_nodes(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "get_selection"
            await plugin.send_response(
                cmd["request_id"],
                {"selected_paths": ["/Main/Camera", "/Main/Light"], "count": 2},
            )

        task = asyncio.create_task(respond())
        result = await client.read_resource("godot://selection/current")
        await task

        data = _parse_resource(result)
        assert data["count"] == 2
        assert "/Main/Camera" in data["selected_paths"]


# ---------------------------------------------------------------------------
# godot://project/info
# ---------------------------------------------------------------------------


class TestProjectInfoResource:
    async def test_returns_session_metadata(self, mcp_stack):
        client, plugin = mcp_stack
        result = await client.read_resource("godot://project/info")
        data = _parse_resource(result)

        assert data["session_id"] == "mcp-test"
        assert data["godot_version"] == "4.4.1"
        assert data["project_path"] == "/tmp/test_project"
        assert "connected_at" not in data


# ---------------------------------------------------------------------------
# godot://project/settings
# ---------------------------------------------------------------------------


class TestProjectSettingsResource:
    async def test_returns_common_settings(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            for _ in range(8):  # 8 common settings
                cmd = await plugin.recv_command()
                assert cmd["command"] == "get_project_setting"
                key = cmd["params"]["key"]
                await plugin.send_response(cmd["request_id"], {"key": key, "value": f"val_{key}"})

        task = asyncio.create_task(respond())
        result = await client.read_resource("godot://project/settings")
        await task

        data = _parse_resource(result)
        assert "application/config/name" in data["settings"]
        assert data["settings"]["application/config/name"] == "val_application/config/name"
        assert data["errors"] is None


# ---------------------------------------------------------------------------
# godot://logs/recent
# ---------------------------------------------------------------------------


class TestLogsRecentResource:
    async def test_returns_log_lines(self, mcp_stack):
        client, plugin = mcp_stack
        lines = [f"log {i}" for i in range(5)]

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "get_logs"
            assert cmd["params"]["count"] == 100
            await plugin.send_response(cmd["request_id"], {"lines": lines})

        task = asyncio.create_task(respond())
        result = await client.read_resource("godot://logs/recent")
        await task

        data = _parse_resource(result)
        assert data["lines"] == lines


# ---------------------------------------------------------------------------
# godot://node/{path}/* templates
# ---------------------------------------------------------------------------


class TestNodeResourceTemplates:
    async def test_node_properties_template(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "get_node_properties"
            assert cmd["params"]["path"] == "/Main/Camera3D"
            await plugin.send_response(
                cmd["request_id"],
                {"path": "/Main/Camera3D", "properties": {"fov": 75.0}},
            )

        task = asyncio.create_task(respond())
        result = await client.read_resource("godot://node/Main/Camera3D/properties")
        await task

        data = _parse_resource(result)
        assert data["path"] == "/Main/Camera3D"
        assert data["properties"]["fov"] == 75.0

    async def test_node_children_template(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "get_children"
            assert cmd["params"]["path"] == "/Main"
            await plugin.send_response(
                cmd["request_id"],
                {"children": [{"name": "Camera3D", "type": "Camera3D", "path": "/Main/Camera3D"}]},
            )

        task = asyncio.create_task(respond())
        result = await client.read_resource("godot://node/Main/children")
        await task

        data = _parse_resource(result)
        assert data["children"][0]["name"] == "Camera3D"

    async def test_node_groups_template(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "get_groups"
            assert cmd["params"]["path"] == "/Main/Enemy"
            await plugin.send_response(
                cmd["request_id"],
                {"groups": ["enemies", "spawnable"]},
            )

        task = asyncio.create_task(respond())
        result = await client.read_resource("godot://node/Main/Enemy/groups")
        await task

        data = _parse_resource(result)
        assert "enemies" in data["groups"]


# ---------------------------------------------------------------------------
# godot://script/{path} template
# ---------------------------------------------------------------------------


class TestScriptResourceTemplate:
    async def test_returns_script_source(self, mcp_stack):
        client, plugin = mcp_stack
        source = "extends Node\n\nfunc _ready() -> void:\n\tprint('hi')\n"

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "read_script"
            assert cmd["params"]["path"] == "res://scripts/player.gd"
            await plugin.send_response(
                cmd["request_id"],
                {"path": "res://scripts/player.gd", "content": source, "line_count": 4},
            )

        task = asyncio.create_task(respond())
        result = await client.read_resource("godot://script/scripts/player.gd")
        await task

        data = _parse_resource(result)
        assert data["content"] == source
        assert data["line_count"] == 4


# ---------------------------------------------------------------------------
# godot://editor/state, godot://materials, godot://input_map,
# godot://performance, godot://test/results
# ---------------------------------------------------------------------------


class TestLibraryResources:
    async def test_editor_state_resource(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "get_editor_state"
            await plugin.send_response(
                cmd["request_id"],
                {
                    "godot_version": "4.4.1",
                    "project_name": "Demo",
                    "current_scene": "res://main.tscn",
                    "is_playing": False,
                    "readiness": "ready",
                },
            )

        task = asyncio.create_task(respond())
        result = await client.read_resource("godot://editor/state")
        await task

        data = _parse_resource(result)
        assert data["readiness"] == "ready"
        assert data["godot_version"] == "4.4.1"

    async def test_materials_resource(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "material_list"
            await plugin.send_response(
                cmd["request_id"],
                {
                    "materials": [
                        {"path": "res://m/red.tres", "type": "StandardMaterial3D"},
                    ],
                    "count": 1,
                },
            )

        task = asyncio.create_task(respond())
        result = await client.read_resource("godot://materials")
        await task

        data = _parse_resource(result)
        assert data["count"] == 1
        assert data["materials"][0]["path"] == "res://m/red.tres"

    async def test_input_map_resource(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "list_actions"
            await plugin.send_response(
                cmd["request_id"],
                {"actions": {"jump": {"events": ["Space"]}}, "count": 1},
            )

        task = asyncio.create_task(respond())
        result = await client.read_resource("godot://input_map")
        await task

        data = _parse_resource(result)
        assert data["count"] == 1
        assert "jump" in data["actions"]

    async def test_performance_resource(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "get_performance_monitors"
            await plugin.send_response(
                cmd["request_id"],
                {"monitors": {"time/fps": 60.0}, "missing": []},
            )

        task = asyncio.create_task(respond())
        result = await client.read_resource("godot://performance")
        await task

        data = _parse_resource(result)
        assert data["monitors"]["time/fps"] == 60.0

    async def test_test_results_resource(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "get_test_results"
            await plugin.send_response(
                cmd["request_id"],
                {"passed": 12, "failed": 0, "total": 12, "failures": [], "duration_ms": 234},
            )

        task = asyncio.create_task(respond())
        result = await client.read_resource("godot://test/results")
        await task

        data = _parse_resource(result)
        assert data["total"] == 12
        assert data["failed"] == 0


# ---------------------------------------------------------------------------
# Resource error handling — handler raises, resource returns connected:false
# ---------------------------------------------------------------------------


class TestResourceErrorPath:
    async def test_node_resource_handles_handler_error(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "get_node_properties"
            await plugin.send_error(cmd["request_id"], "INVALID_PARAMS", "no such node")

        task = asyncio.create_task(respond())
        result = await client.read_resource("godot://node/Bogus/properties")
        await task

        data = _parse_resource(result)
        assert data["connected"] is False
        assert "no such node" in data["error"]

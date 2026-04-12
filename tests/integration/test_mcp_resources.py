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
            await plugin.send_response(
                cmd["request_id"], {"nodes": nodes, "total_count": 2}
            )

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
                await plugin.send_response(
                    cmd["request_id"], {"key": key, "value": f"val_{key}"}
                )

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

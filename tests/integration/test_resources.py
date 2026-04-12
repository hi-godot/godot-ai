"""Integration tests: MCP resources via mock Godot plugin."""

from __future__ import annotations

import asyncio

from godot_ai.godot_client.client import GodotClient


class TestSceneCurrentResource:
    async def test_returns_current_scene(self, harness):
        plugin = await harness.connect_plugin()
        client = GodotClient(harness.server, harness.registry)

        async def mock_handler():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "get_editor_state"
            await plugin.send_response(
                cmd["request_id"],
                {
                    "current_scene": "res://main.tscn",
                    "project_name": "TestGame",
                    "is_playing": False,
                    "godot_version": "4.4.1",
                },
            )

        handler_task = asyncio.create_task(mock_handler())
        result = await client.send("get_editor_state")
        await handler_task

        assert result["current_scene"] == "res://main.tscn"
        assert result["project_name"] == "TestGame"
        await plugin.close()


class TestSceneHierarchyResource:
    async def test_returns_scene_tree(self, harness):
        plugin = await harness.connect_plugin()
        client = GodotClient(harness.server, harness.registry)

        async def mock_handler():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "get_scene_tree"
            await plugin.send_response(
                cmd["request_id"],
                {
                    "root": "Main",
                    "nodes": [
                        {"name": "Main", "type": "Node3D", "path": "/Main"},
                        {"name": "Camera3D", "type": "Camera3D", "path": "/Main/Camera3D"},
                    ],
                },
            )

        handler_task = asyncio.create_task(mock_handler())
        result = await client.send("get_scene_tree", {"depth": 10})
        await handler_task

        assert result["root"] == "Main"
        assert len(result["nodes"]) == 2
        await plugin.close()


class TestSelectionResource:
    async def test_returns_selection(self, harness):
        plugin = await harness.connect_plugin()
        client = GodotClient(harness.server, harness.registry)

        async def mock_handler():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "get_selection"
            await plugin.send_response(
                cmd["request_id"],
                {"selected": ["/Main/Camera3D"]},
            )

        handler_task = asyncio.create_task(mock_handler())
        result = await client.send("get_selection")
        await handler_task

        assert result["selected"] == ["/Main/Camera3D"]
        await plugin.close()


class TestProjectInfoResource:
    async def test_returns_session_metadata(self, harness):
        plugin = await harness.connect_plugin(
            session_id="info-test",
            godot_version="4.4.1",
            project_path="/home/user/game",
        )

        session = harness.registry.get("info-test")
        info = session.to_dict()

        assert info["godot_version"] == "4.4.1"
        assert info["project_path"] == "/home/user/game"
        assert info["session_id"] == "info-test"
        await plugin.close()

    async def test_no_active_session(self, harness):
        session = harness.registry.get_active()
        assert session is None


class TestLogsResource:
    async def test_returns_log_lines(self, harness):
        plugin = await harness.connect_plugin()
        client = GodotClient(harness.server, harness.registry)

        async def mock_handler():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "get_logs"
            await plugin.send_response(
                cmd["request_id"],
                {"lines": ["line1", "line2", "line3"]},
            )

        handler_task = asyncio.create_task(mock_handler())
        result = await client.send("get_logs", {"count": 100})
        await handler_task

        assert result["lines"] == ["line1", "line2", "line3"]
        await plugin.close()

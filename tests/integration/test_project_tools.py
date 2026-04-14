"""Integration tests: project settings and filesystem search commands."""

from __future__ import annotations

import asyncio

import pytest

from godot_ai.godot_client.client import GodotClient, GodotCommandError


class TestProjectSettingsGet:
    async def test_get_project_setting_roundtrip(self, harness):
        plugin = await harness.connect_plugin()
        client = GodotClient(harness.server, harness.registry)

        async def mock_handler():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "get_project_setting"
            assert cmd["params"] == {"key": "application/config/name"}
            await plugin.send_response(
                cmd["request_id"],
                {"key": "application/config/name", "value": "My Game", "type": "String"},
            )

        handler_task = asyncio.create_task(mock_handler())
        result = await client.send("get_project_setting", {"key": "application/config/name"})
        await handler_task

        assert result["key"] == "application/config/name"
        assert result["value"] == "My Game"
        await plugin.close()

    async def test_get_project_setting_error_propagates(self, harness):
        plugin = await harness.connect_plugin()
        client = GodotClient(harness.server, harness.registry)

        async def mock_handler():
            cmd = await plugin.recv_command()
            await plugin.send_error(
                cmd["request_id"], "INVALID_PARAMS", "Setting not found: bad/key"
            )

        handler_task = asyncio.create_task(mock_handler())
        with pytest.raises(GodotCommandError) as exc_info:
            await client.send("get_project_setting", {"key": "bad/key"})
        await handler_task

        assert exc_info.value.code == "INVALID_PARAMS"
        assert "Setting not found" in exc_info.value.message
        await plugin.close()


class TestProjectSettingsSet:
    async def test_set_project_setting_roundtrip(self, harness):
        plugin = await harness.connect_plugin()
        client = GodotClient(harness.server, harness.registry)

        async def mock_handler():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "set_project_setting"
            assert cmd["params"] == {
                "key": "display/window/size/viewport_width",
                "value": 1920,
            }
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

        handler_task = asyncio.create_task(mock_handler())
        result = await client.send(
            "set_project_setting",
            {"key": "display/window/size/viewport_width", "value": 1920},
        )
        await handler_task

        assert result["key"] == "display/window/size/viewport_width"
        assert result["value"] == 1920
        assert result["old_value"] == 1152
        await plugin.close()


class TestFilesystemSearch:
    async def test_search_by_name(self, harness):
        plugin = await harness.connect_plugin()
        client = GodotClient(harness.server, harness.registry)

        async def mock_handler():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "search_filesystem"
            assert cmd["params"] == {"name": "main"}
            await plugin.send_response(
                cmd["request_id"],
                {
                    "files": [
                        {"path": "res://main.tscn", "type": "PackedScene"},
                        {"path": "res://main.gd", "type": "GDScript"},
                    ],
                    "count": 2,
                },
            )

        handler_task = asyncio.create_task(mock_handler())
        result = await client.send("search_filesystem", {"name": "main"})
        await handler_task

        assert result["count"] == 2
        assert len(result["files"]) == 2
        await plugin.close()

    async def test_search_by_type(self, harness):
        plugin = await harness.connect_plugin()
        client = GodotClient(harness.server, harness.registry)

        async def mock_handler():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "search_filesystem"
            assert cmd["params"] == {"type": "PackedScene"}
            await plugin.send_response(
                cmd["request_id"],
                {
                    "files": [{"path": "res://main.tscn", "type": "PackedScene"}],
                    "count": 1,
                },
            )

        handler_task = asyncio.create_task(mock_handler())
        result = await client.send("search_filesystem", {"type": "PackedScene"})
        await handler_task

        assert result["count"] == 1
        assert result["files"][0]["type"] == "PackedScene"
        await plugin.close()

    async def test_search_by_path(self, harness):
        plugin = await harness.connect_plugin()
        client = GodotClient(harness.server, harness.registry)

        async def mock_handler():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "search_filesystem"
            assert cmd["params"] == {"path": "tests/"}
            await plugin.send_response(
                cmd["request_id"],
                {
                    "files": [{"path": "res://tests/test_scene.gd", "type": "GDScript"}],
                    "count": 1,
                },
            )

        handler_task = asyncio.create_task(mock_handler())
        result = await client.send("search_filesystem", {"path": "tests/"})
        await handler_task

        assert result["count"] == 1
        await plugin.close()

    async def test_search_missing_filter_error(self, harness):
        plugin = await harness.connect_plugin()
        client = GodotClient(harness.server, harness.registry)

        async def mock_handler():
            cmd = await plugin.recv_command()
            await plugin.send_error(
                cmd["request_id"],
                "INVALID_PARAMS",
                "At least one filter (name, type, path) is required",
            )

        handler_task = asyncio.create_task(mock_handler())
        with pytest.raises(GodotCommandError) as exc_info:
            await client.send("search_filesystem", {})
        await handler_task

        assert exc_info.value.code == "INVALID_PARAMS"
        await plugin.close()

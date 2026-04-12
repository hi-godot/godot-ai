"""Integration tests: pagination in tools via mock Godot plugin."""

from __future__ import annotations

import asyncio

from godot_ai.godot_client.client import GodotClient


def _make_nodes(count: int) -> list[dict]:
    return [
        {"name": f"Node{i}", "type": "Node3D", "path": f"/Root/Node{i}"}
        for i in range(count)
    ]


def _make_files(count: int) -> list[dict]:
    return [
        {"path": f"res://file_{i}.gd", "type": "GDScript"}
        for i in range(count)
    ]


class TestSceneHierarchyPagination:
    async def test_default_pagination(self, harness):
        plugin = await harness.connect_plugin()
        client = GodotClient(harness.server, harness.registry)
        nodes = _make_nodes(5)

        async def mock_handler():
            cmd = await plugin.recv_command()
            await plugin.send_response(
                cmd["request_id"],
                {"root": "Root", "nodes": nodes},
            )

        handler_task = asyncio.create_task(mock_handler())
        # Call the raw command — pagination is in the tool layer, not client.send
        result = await client.send("get_scene_tree", {"depth": 10})
        await handler_task

        assert len(result["nodes"]) == 5
        await plugin.close()

    async def test_paginate_scene_nodes(self, harness):
        """Verify the pagination helper produces correct slices."""
        from godot_ai.tools.scene import _paginate

        nodes = _make_nodes(10)
        page = _paginate(nodes, offset=2, limit=3)

        assert len(page["items"]) == 3
        assert page["items"][0]["name"] == "Node2"
        assert page["total_count"] == 10
        assert page["has_more"] is True

    async def test_paginate_last_page(self, harness):
        from godot_ai.tools.scene import _paginate

        nodes = _make_nodes(10)
        page = _paginate(nodes, offset=8, limit=5)

        assert len(page["items"]) == 2
        assert page["total_count"] == 10
        assert page["has_more"] is False


class TestNodeFindPagination:
    async def test_find_nodes_paginated(self, harness):
        plugin = await harness.connect_plugin()
        client = GodotClient(harness.server, harness.registry)
        nodes = _make_nodes(15)

        async def mock_handler():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "find_nodes"
            await plugin.send_response(
                cmd["request_id"],
                {"nodes": nodes},
            )

        handler_task = asyncio.create_task(mock_handler())
        result = await client.send("find_nodes", {"name": "Node", "type": "", "group": ""})
        await handler_task

        # Raw result returns all nodes — pagination is at tool layer
        assert len(result["nodes"]) == 15
        await plugin.close()


class TestFilesystemSearchPagination:
    async def test_search_returns_all_files(self, harness):
        plugin = await harness.connect_plugin()
        client = GodotClient(harness.server, harness.registry)
        files = _make_files(8)

        async def mock_handler():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "search_filesystem"
            await plugin.send_response(
                cmd["request_id"],
                {"files": files, "count": 8},
            )

        handler_task = asyncio.create_task(mock_handler())
        result = await client.send("search_filesystem", {"name": "file"})
        await handler_task

        assert len(result["files"]) == 8
        await plugin.close()


class TestLogsPagination:
    async def test_logs_with_offset(self, harness):
        plugin = await harness.connect_plugin()
        client = GodotClient(harness.server, harness.registry)
        lines = [f"log line {i}" for i in range(20)]

        async def mock_handler():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "get_logs"
            await plugin.send_response(
                cmd["request_id"],
                {"lines": lines},
            )

        handler_task = asyncio.create_task(mock_handler())
        result = await client.send("get_logs", {"count": 20})
        await handler_task

        assert len(result["lines"]) == 20
        assert result["lines"][0] == "log line 0"
        await plugin.close()

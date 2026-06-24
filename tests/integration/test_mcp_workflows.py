"""Deterministic MCP contract checks that mirror agent verification loops.

These tests do not involve an LLM or a live editor; the integration fixture
uses a mock Godot plugin. They pin the server-side request/response contract
we want agents to lean on: capture visual feedback, mutate through a tool,
then issue a read-back request.
"""

from __future__ import annotations

import asyncio

ONE_PX_PNG_B64 = (
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4"
    "nGP4DwABAQEBYY2JxQAAAABJRU5ErkJggg=="
)


def _content_type(block: object) -> str:
    return str(getattr(block, "type", "") or getattr(block, "kind", ""))


async def _bounded(awaitable):
    return await asyncio.wait_for(awaitable, timeout=5)


class TestMcpVerificationWorkflows:
    async def test_editor_screenshot_returns_consumable_image_content(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            cmd = await plugin.recv_command()
            assert cmd["command"] == "take_screenshot"
            assert cmd["params"].get("include_image", True) is True
            await plugin.send_response(
                cmd["request_id"],
                {
                    "source": "viewport",
                    "width": 1,
                    "height": 1,
                    "original_width": 1,
                    "original_height": 1,
                    "format": "png",
                    "image_base64": ONE_PX_PNG_B64,
                },
        )

        task = asyncio.create_task(respond())
        result = await _bounded(
            client.call_tool("editor_screenshot", {"include_image": True})
        )
        await _bounded(task)

        assert not result.is_error
        assert any(_content_type(block) == "image" for block in result.content), (
            "include_image=true must expose a real image content block, not only "
            "metadata text"
        )

    async def test_property_write_can_be_verified_by_readback(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            set_cmd = await plugin.recv_command()
            assert set_cmd["command"] == "set_property"
            assert set_cmd["params"] == {
                "path": "/Main/Marker",
                "property": "visible",
                "value": False,
            }
            await plugin.send_response(
                set_cmd["request_id"],
                {
                    "path": "/Main/Marker",
                    "property": "visible",
                    "value": False,
                    "old_value": True,
                    "undoable": True,
                },
            )

            read_cmd = await plugin.recv_command()
            assert read_cmd["command"] == "get_node_properties"
            assert read_cmd["params"]["path"] == "/Main/Marker"
            await plugin.send_response(
                read_cmd["request_id"],
                {
                    "properties": [
                        {"name": "visible", "type": "bool", "value": False},
                        {"name": "name", "type": "String", "value": "Marker"},
                    ]
                },
        )

        task = asyncio.create_task(respond())
        write = await _bounded(
            client.call_tool(
                "node_set_property",
                {"path": "/Main/Marker", "property": "visible", "value": False},
            )
        )
        read = await _bounded(
            client.call_tool("node_get_properties", {"path": "/Main/Marker"})
        )
        await _bounded(task)

        assert write.data["value"] is False
        visible = next(
            prop for prop in read.data["properties"] if prop["name"] == "visible"
        )
        assert visible["value"] is False

    async def test_scene_open_can_be_verified_by_hierarchy_readback(self, mcp_stack):
        client, plugin = mcp_stack

        async def respond():
            open_cmd = await plugin.recv_command()
            assert open_cmd["command"] == "open_scene"
            assert open_cmd["params"]["path"] == "res://levels/arena.tscn"
            await plugin.send_response(
                open_cmd["request_id"],
                {"path": "res://levels/arena.tscn", "undoable": False},
            )

            hierarchy_cmd = await plugin.recv_command()
            assert hierarchy_cmd["command"] == "get_scene_tree"
            await plugin.send_response(
                hierarchy_cmd["request_id"],
                {
                    "root": "Arena",
                    "scene_path": "res://levels/arena.tscn",
                    "nodes": [
                        {"name": "Arena", "type": "Node3D", "path": "/Arena"},
                        {
                            "name": "PlayerSpawn",
                            "type": "Marker3D",
                            "path": "/Arena/PlayerSpawn",
                        },
                    ],
                },
        )

        task = asyncio.create_task(respond())
        opened = await _bounded(
            client.call_tool("scene_open", {"path": "res://levels/arena.tscn"})
        )
        hierarchy = await _bounded(
            client.call_tool("scene_get_hierarchy", {"depth": 3})
        )
        await _bounded(task)

        assert opened.data["path"] == "res://levels/arena.tscn"
        assert hierarchy.data["root"] == "Arena"
        assert any(node["name"] == "PlayerSpawn" for node in hierarchy.data["nodes"])

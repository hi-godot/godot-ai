"""Resource inspection through the MCP surface and session routing."""

import asyncio

import pytest
import websockets

from tests.conftest import MockGodotPlugin, perform_v4_handshake


async def test_resource_inspect_returns_graph(mcp_stack):
    client, plugin = mcp_stack
    graph = {
        "root": {"ref": "r1"},
        "resources": [
            {"id": "r1", "type": "BoxShape3D", "properties": {"size": {"x": 2, "y": 3, "z": 4}}}
        ],
        "truncations": [],
    }

    async def respond():
        command = await plugin.recv_command()
        assert command["command"] == "inspect_resource"
        assert command["params"] == {"node_path": "/Main/Collider", "property": "shape", "depth": 1}
        await plugin.send_response(command["request_id"], graph)

    task = asyncio.create_task(respond())
    result = await client.call_tool(
        "resource_manage",
        {
            "op": "inspect",
            "params": {"node_path": "/Main/Collider", "property": "shape", "depth": 1},
            "session_id": "mcp-test",
        },
    )
    await task
    assert result.data == graph


async def test_resource_inspect_pins_session_without_changing_active(mcp_stack, mcp_ws_port):
    client, first = mcp_stack
    async with websockets.connect(f"ws://127.0.0.1:{mcp_ws_port}") as ws:
        await perform_v4_handshake(
            ws, session_id="inspect-other", project_path="/tmp/inspect-other"
        )
        other = MockGodotPlugin(ws=ws, session_id="inspect-other")
        await client.call_tool("session_activate", {"session_id": "mcp-test"})

        async def respond():
            command = await other.recv_command()
            assert command["command"] == "inspect_resource"
            await other.send_response(
                command["request_id"],
                {
                    "root": {"ref": "r1"},
                    "resources": [
                        {"id": "r1", "type": "SphereShape3D", "properties": {"radius": 3.5}}
                    ],
                    "truncations": [],
                },
            )

        task = asyncio.create_task(respond())
        result = await client.call_tool(
            "resource_manage",
            {
                "op": "inspect",
                "params": {"node_path": "/Main/Collider", "property": "shape"},
                "session_id": "inspect-other",
            },
        )
        await task
        assert result.data["resources"][0]["properties"]["radius"] == 3.5
        with pytest.raises(TimeoutError):
            await asyncio.wait_for(first.recv_command(), 0.1)
        state = await client.call_tool("session_manage", {"op": "list"})
        assert [s["session_id"] for s in state.data["sessions"] if s["is_active"]] == ["mcp-test"]

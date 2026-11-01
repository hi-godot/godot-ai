"""Animation library operations use the existing MCP domain and preserve data."""

import asyncio

import pytest


@pytest.mark.parametrize(
    ("op", "params", "expected"),
    [
        (
            "library_add",
            {"resource_path": "res://shared.res"},
            {"resource_path": "res://shared.res", "library_name": ""},
        ),
        ("library_remove", {"library_name": "moves"}, {"library_name": "moves"}),
        ("library_list", {}, {}),
    ],
)
async def test_animation_library_operations(mcp_stack, op, params, expected):
    client, plugin = mcp_stack
    payload = {
        "libraries": [
            {"name": "moves", "resource_path": "res://shared.res", "animations": ["run"]}
        ],
        "autoplay": "moves/run",
    }

    async def respond():
        command = await plugin.recv_command()
        assert command["command"] == f"animation_{op}"
        assert command["params"] == {"player_path": "/Main/Mixer", **expected}
        await plugin.send_response(command["request_id"], payload)

    task = asyncio.create_task(respond())
    result = await client.call_tool(
        "animation_manage",
        {"op": op, "params": {"player_path": "/Main/Mixer", **params}},
    )
    await task
    assert result.data == payload


@pytest.mark.parametrize("op", ["library_add", "library_remove"])
async def test_animation_library_writes_are_blocked_while_playing(mcp_stack, op):
    client, plugin = mcp_stack
    await plugin.send_event("readiness_changed", {"readiness": "playing"})
    await asyncio.sleep(0.05)

    async def respond():
        command = await plugin.recv_command()
        assert command["command"] == "get_editor_state"
        await plugin.send_response(
            command["request_id"],
            {"readiness": "playing", "is_playing": True},
        )

    task = asyncio.create_task(respond())
    params = {"player_path": "/Main/Player", "library_name": "moves"}
    if op == "library_add":
        params["resource_path"] = "res://shared.tres"
    result = await client.call_tool(
        "animation_manage",
        {"op": op, "params": params},
        raise_on_error=False,
    )
    await task
    assert result.is_error
    assert "EDITOR_NOT_READY" in str(result.content)

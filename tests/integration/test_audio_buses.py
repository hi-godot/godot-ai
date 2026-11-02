"""Native audio operations share MCP routing and the editor write gate."""

import asyncio

import pytest

CASES = [
    ("bus_list", {}, {}),
    ("bus_add", {"name": "Music"}, {"name": "Music", "at_position": -1, "send": "Master"}),
    ("bus_remove", {"name": "Music"}, {"name": "Music"}),
    (
        "bus_set",
        {"name": "Music", "mute": False, "volume_db": 0},
        {"name": "Music", "mute": False, "volume_db": 0},
    ),
    (
        "bus_effect_add",
        {"bus": "Music", "effect_class": "AudioEffectReverb"},
        {
            "bus": "Music",
            "effect_class": "AudioEffectReverb",
            "properties": {},
            "at_position": -1,
            "enabled": True,
        },
    ),
    (
        "bus_effect_set",
        {"bus": "Music", "index": 0, "enabled": False},
        {"bus": "Music", "index": 0, "enabled": False, "properties": {}},
    ),
    ("bus_effect_remove", {"bus": "Music", "index": 0}, {"bus": "Music", "index": 0}),
    ("bus_layout_save", {}, {"path": "res://default_bus_layout.tres", "overwrite": False}),
]


@pytest.mark.parametrize(("op", "params", "expected"), CASES)
async def test_audio_bus_mcp_routing(mcp_stack, op, params, expected):
    client, plugin = mcp_stack
    payload = {"bus": {"name": "Music", "volume_db": -12.0, "mute": False, "effects": []}}

    async def respond():
        command = await plugin.recv_command()
        assert command["command"] == "audio_" + op
        assert command["params"] == expected
        await plugin.send_response(command["request_id"], payload)

    task = asyncio.create_task(respond())
    result = await client.call_tool("audio_manage", {"op": op, "params": params})
    await task
    assert result.data == payload


@pytest.mark.parametrize(("op", "params", "_expected"), CASES[1:])
async def test_audio_bus_writes_obey_readiness(mcp_stack, op, params, _expected):
    client, plugin = mcp_stack
    await plugin.send_event("readiness_changed", {"readiness": "playing"})
    await asyncio.sleep(0.05)

    async def respond():
        command = await plugin.recv_command()
        assert command["command"] == "get_editor_state"
        await plugin.send_response(
            command["request_id"], {"readiness": "playing", "is_playing": True}
        )

    task = asyncio.create_task(respond())
    result = await client.call_tool(
        "audio_manage", {"op": op, "params": params}, raise_on_error=False
    )
    await task
    assert result.is_error
    assert "EDITOR_NOT_READY" in str(result.content)

"""Animation graph ops use the normal MCP route and write readiness gate."""

import asyncio

import pytest

CASES = [
    (
        "tree_create",
        {"parent_path": "/Main", "player_path": "/Main/Player"},
        {
            "parent_path": "/Main",
            "player_path": "/Main/Player",
            "name": "AnimationTree",
            "root_type": "state_machine",
        },
    ),
    ("tree_get", {"tree_path": "/Main/Tree"}, {"tree_path": "/Main/Tree", "graph_path": ""}),
    (
        "tree_node_add",
        {"tree_path": "/Main/Tree", "name": "Idle"},
        {
            "tree_path": "/Main/Tree",
            "name": "Idle",
            "node_type": "AnimationNodeAnimation",
            "properties": {},
            "position": {"x": 0, "y": 0},
            "graph_path": "",
        },
    ),
    (
        "tree_node_remove",
        {"tree_path": "/Main/Tree", "name": "Idle"},
        {"tree_path": "/Main/Tree", "name": "Idle", "graph_path": ""},
    ),
    (
        "tree_node_set",
        {"tree_path": "/Main/Tree", "graph_path": "Idle", "properties": {"animation": "idle"}},
        {"tree_path": "/Main/Tree", "graph_path": "Idle", "properties": {"animation": "idle"}},
    ),
    (
        "tree_connect",
        {
            "tree_path": "/Main/Tree",
            "input_node": "output",
            "input_index": 0,
            "output_node": "Idle",
        },
        {
            "tree_path": "/Main/Tree",
            "input_node": "output",
            "input_index": 0,
            "output_node": "Idle",
            "graph_path": "",
        },
    ),
    (
        "tree_disconnect",
        {"tree_path": "/Main/Tree", "input_node": "output", "input_index": 0},
        {"tree_path": "/Main/Tree", "input_node": "output", "input_index": 0, "graph_path": ""},
    ),
]
for op in ("tree_transition_add", "tree_transition_remove", "tree_transition_set"):
    params = {"tree_path": "/Main/Tree", "from_state": "Start", "to_state": "Idle"}
    expected = {**params, "graph_path": ""}
    if op != "tree_transition_remove":
        expected["properties"] = {}
    CASES.append((op, params, expected))


CASES.extend(
    [
        (
            "tree_point_add",
            {"tree_path": "/Main/Tree", "name": "Idle", "position": 0.5},
            {
                "tree_path": "/Main/Tree",
                "name": "Idle",
                "position": 0.5,
                "node_type": "AnimationNodeAnimation",
                "properties": {},
                "at_index": -1,
                "graph_path": "",
            },
        ),
        (
            "tree_point_set",
            {"tree_path": "/Main/Tree", "name": "Idle", "position": {"x": 1, "y": 2}},
            {
                "tree_path": "/Main/Tree",
                "name": "Idle",
                "position": {"x": 1, "y": 2},
                "graph_path": "",
            },
        ),
        (
            "tree_point_remove",
            {"tree_path": "/Main/Tree", "name": "Idle"},
            {"tree_path": "/Main/Tree", "name": "Idle", "graph_path": ""},
        ),
    ]
)


@pytest.mark.parametrize(("op", "params", "expected"), CASES)
async def test_animation_tree_route(mcp_stack, op, params, expected):
    client, plugin = mcp_stack
    payload = {"graph": {"class": "AnimationNodeStateMachine", "nodes": [{"name": "Idle"}]}}

    async def respond():
        command = await plugin.recv_command()
        assert command["command"] == "animation_" + op
        assert command["params"] == expected
        await plugin.send_response(command["request_id"], payload)

    task = asyncio.create_task(respond())
    result = await client.call_tool("animation_manage", {"op": op, "params": params})
    await task
    assert result.data == payload


@pytest.mark.parametrize(
    ("op", "params", "_expected"), [row for row in CASES if row[0] != "tree_get"]
)
async def test_animation_tree_write_readiness(mcp_stack, op, params, _expected):
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
        "animation_manage", {"op": op, "params": params}, raise_on_error=False
    )
    await task
    assert result.is_error
    assert "EDITOR_NOT_READY" in str(result.content)

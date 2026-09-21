"""VisualShader orchestration and readiness contract."""

from unittest.mock import AsyncMock

import pytest

from godot_ai.handlers import visual_shader


async def test_graph_forwards_stages_and_defaults_after_readiness(monkeypatch):
    events = []

    async def ready(runtime):
        events.append("ready")

    async def send(command, params, *, timeout):
        events.append("send")
        assert command == "visual_shader_create_graph"
        assert timeout == visual_shader.VISUAL_SHADER_CREATE_TIMEOUT_SECONDS
        assert params == {
            "resource_path": "res://graph.tres",
            "stages": [{"stage": "vertex", "nodes": [], "connections": []}],
            "shader_type": "spatial",
            "overwrite": False,
        }
        return {"resource_path": params["resource_path"], "undoable": False}

    runtime = AsyncMock()
    runtime.send_command.side_effect = send
    monkeypatch.setattr(visual_shader, "require_writable_async", ready)
    result = await visual_shader.create_graph(
        runtime, "res://graph.tres", [{"stage": "vertex", "nodes": [], "connections": []}]
    )
    assert result == {"resource_path": "res://graph.tres", "undoable": False}
    assert events == ["ready", "send"]


async def test_graph_cannot_dispatch_when_not_writable(monkeypatch):
    runtime = AsyncMock()
    gate = AsyncMock(side_effect=RuntimeError("editor importing"))
    monkeypatch.setattr(visual_shader, "require_writable_async", gate)
    with pytest.raises(RuntimeError, match="editor importing"):
        await visual_shader.create_graph(runtime, "res://graph.tres", [])
    runtime.send_command.assert_not_called()


async def test_graph_forwards_mode_overwrite_and_errors(monkeypatch):
    runtime = AsyncMock()
    runtime.send_command.side_effect = RuntimeError("invalid graph")
    monkeypatch.setattr(visual_shader, "require_writable_async", AsyncMock())
    with pytest.raises(RuntimeError, match="invalid graph"):
        await visual_shader.create_graph(runtime, "res://graph.tres", [], "particles", True)
    assert runtime.send_command.call_args.args[1]["overwrite"] is True
    assert runtime.send_command.call_args.args[1]["shader_type"] == "particles"


async def test_graph_forwards_varyings(monkeypatch):
    runtime = AsyncMock()
    runtime.send_command.return_value = {"resource_path": "res://graph.tres"}
    monkeypatch.setattr(visual_shader, "require_writable_async", AsyncMock())
    await visual_shader.create_graph(
        runtime,
        "res://graph.tres",
        [{"stage": "fragment", "nodes": [], "connections": []}],
        varyings=[{"name": "v", "mode": "frag_to_light", "type": "float"}],
    )
    assert runtime.send_command.call_args.args[1]["varyings"] == [
        {"name": "v", "mode": "frag_to_light", "type": "float"}
    ]


async def test_get_graph_is_read_only_and_forwards_path(monkeypatch):
    runtime = AsyncMock()
    runtime.send_command.return_value = {"path": "res://graph.tres"}
    gate = AsyncMock(side_effect=AssertionError("get must not gate on readiness"))
    monkeypatch.setattr(visual_shader, "require_writable_async", gate)
    result = await visual_shader.get_graph(runtime, "res://graph.tres")
    assert result["path"] == "res://graph.tres"
    assert runtime.send_command.call_args.args == (
        "visual_shader_get",
        {"path": "res://graph.tres"},
    )


async def test_node_catalog_forwards_paging_and_filter():
    runtime = AsyncMock()
    runtime.send_command.return_value = {"nodes": []}
    await visual_shader.node_catalog(runtime, filter="Float", offset=5, limit=10)
    command, params = runtime.send_command.call_args.args
    assert command == "visual_shader_node_catalog"
    assert params == {"filter": "Float", "offset": 5, "limit": 10}


async def test_node_catalog_omits_empty_filter():
    runtime = AsyncMock()
    runtime.send_command.return_value = {"nodes": []}
    await visual_shader.node_catalog(runtime)
    assert runtime.send_command.call_args.args[1] == {"offset": 0, "limit": 100}


async def test_edit_graph_gates_and_forwards_operations(monkeypatch):
    events = []

    async def ready(runtime):
        events.append("ready")

    async def send(command, params, *, timeout):
        events.append("send")
        assert command == "visual_shader_edit"
        assert timeout == visual_shader.VISUAL_SHADER_EDIT_TIMEOUT_SECONDS
        assert params["resource_path"] == "res://graph.tres"
        assert params["operations"] == [
            {"op": "remove_node", "stage": "fragment", "id": 2}
        ]
        return {"resource_path": params["resource_path"], "undoable": False}

    runtime = AsyncMock()
    runtime.send_command.side_effect = send
    monkeypatch.setattr(visual_shader, "require_writable_async", ready)
    result = await visual_shader.edit_graph(
        runtime,
        "res://graph.tres",
        [{"op": "remove_node", "stage": "fragment", "id": 2}],
    )
    assert result["resource_path"] == "res://graph.tres"
    assert events == ["ready", "send"]


async def test_edit_graph_blocks_when_not_writable(monkeypatch):
    runtime = AsyncMock()
    monkeypatch.setattr(
        visual_shader,
        "require_writable_async",
        AsyncMock(side_effect=RuntimeError("editor playing")),
    )
    with pytest.raises(RuntimeError, match="editor playing"):
        await visual_shader.edit_graph(runtime, "res://graph.tres", [])
    runtime.send_command.assert_not_called()

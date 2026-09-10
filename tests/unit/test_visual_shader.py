"""VisualShader orchestration and readiness contract."""

from unittest.mock import AsyncMock

import pytest

from godot_ai.handlers import visual_shader


async def test_graph_forwards_stages_and_defaults_after_readiness(monkeypatch):
    events = []

    async def ready(runtime):
        events.append("ready")

    async def send(command, params):
        events.append("send")
        assert command == "visual_shader_create_graph"
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

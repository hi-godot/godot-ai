"""Raw shader handler orchestration and readiness contract."""

from unittest.mock import AsyncMock

import pytest

from godot_ai.handlers import material as material_handlers
from godot_ai.handlers import shader


async def test_shader_create_gates_then_forwards(monkeypatch):
    events = []

    async def ready(runtime):
        events.append("ready")

    async def send(command, params, **_kwargs):
        events.append("send")
        assert command == "shader_create"
        assert params == {
            "resource_path": "res://shaders/pulse.gdshader",
            "code": "shader_type spatial;\n",
            "overwrite": False,
            "shader_type": "spatial",
        }
        return {"path": params["resource_path"], "undoable": False}

    runtime = AsyncMock()
    runtime.send_command.side_effect = send
    monkeypatch.setattr(shader, "require_writable_async", ready)
    result = await shader.shader_create(
        runtime, "res://shaders/pulse.gdshader", "shader_type spatial;\n"
    )
    assert result["path"] == "res://shaders/pulse.gdshader"
    assert events == ["ready", "send"]


async def test_shader_create_blocks_when_not_writable(monkeypatch):
    runtime = AsyncMock()
    monkeypatch.setattr(
        shader,
        "require_writable_async",
        AsyncMock(side_effect=RuntimeError("editor playing")),
    )
    with pytest.raises(RuntimeError, match="editor playing"):
        await shader.shader_create(runtime, "res://a.gdshader", "shader_type spatial;")
    runtime.send_command.assert_not_called()


async def test_shader_create_forwards_overwrite_and_type(monkeypatch):
    runtime = AsyncMock()
    runtime.send_command.return_value = {"path": "res://a.gdshaderinc"}
    monkeypatch.setattr(shader, "require_writable_async", AsyncMock())
    await shader.shader_create(
        runtime,
        "res://a.gdshaderinc",
        "uniform float x;",
        overwrite=True,
        shader_type="canvas_item",
    )
    params = runtime.send_command.call_args.args[1]
    assert params["overwrite"] is True
    assert params["shader_type"] == "canvas_item"


async def test_shader_patch_gates_and_forwards_replace_all(monkeypatch):
    runtime = AsyncMock()
    runtime.send_command.return_value = {"path": "res://a.gdshader", "replacements": 2}
    monkeypatch.setattr(shader, "require_writable_async", AsyncMock())
    result = await shader.shader_patch(
        runtime, "res://a.gdshader", "old", "new", replace_all=True
    )
    assert result["replacements"] == 2
    assert runtime.send_command.call_args.args[0] == "shader_patch"
    assert runtime.send_command.call_args.args[1]["replace_all"] is True


async def test_shader_validate_is_read_only(monkeypatch):
    runtime = AsyncMock()
    runtime.send_command.return_value = {"valid": False, "errors": [{"line": 5}]}
    gate = AsyncMock(side_effect=AssertionError("validate must not gate on readiness"))
    monkeypatch.setattr(shader, "require_writable_async", gate)
    result = await shader.shader_validate(runtime, "shader_type spatial;")
    assert result["valid"] is False
    assert runtime.send_command.call_args.args[1]["kind"] == "shader"


async def test_shader_get_forwards_path():
    runtime = AsyncMock()
    runtime.send_command.return_value = {"path": "res://a.gdshader"}
    await shader.shader_get(runtime, "res://a.gdshader")
    assert runtime.send_command.call_args.args == (
        "shader_get",
        {"path": "res://a.gdshader"},
    )


async def test_shader_list_forwards_root():
    runtime = AsyncMock()
    runtime.send_command.return_value = {"count": 0}
    await shader.shader_list(runtime, "res://shaders")
    assert runtime.send_command.call_args.args == (
        "shader_list",
        {"root": "res://shaders"},
    )


async def test_material_create_forwards_inline_code(monkeypatch):
    runtime = AsyncMock()
    runtime.send_command.return_value = {"path": "res://m.tres"}
    monkeypatch.setattr(material_handlers, "require_writable_async", AsyncMock())
    await material_handlers.material_create(
        runtime,
        path="res://m.tres",
        type="shader",
        code="shader_type spatial;",
    )
    params = runtime.send_command.call_args.args[1]
    assert params["code"] == "shader_type spatial;"
    assert "shader_path" not in params

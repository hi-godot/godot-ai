"""Public scene_manage routing with an in-process MCP client."""

from __future__ import annotations

from contextlib import asynccontextmanager
from types import SimpleNamespace
from unittest.mock import AsyncMock

import pytest
from fastmcp import Client, FastMCP

from godot_ai.middleware import PreserveGodotCommandErrorData
from godot_ai.sessions.registry import Session, SessionRegistry
from godot_ai.tools.scene import register_scene_tools


@pytest.fixture
def scene_server():
    registry = SessionRegistry()
    for session_id in ("active", "pinned"):
        registry.register(
            Session(
                session_id=session_id,
                godot_version="4.7.0",
                project_path=f"/projects/{session_id}",
                plugin_version="4.0.0",
            )
        )
    registry.set_active("active")
    send = AsyncMock()

    @asynccontextmanager
    async def lifespan(_server):
        yield SimpleNamespace(registry=registry, client=SimpleNamespace(send=send))

    server = FastMCP("scene-authoring", lifespan=lifespan)
    server.add_middleware(PreserveGodotCommandErrorData())
    register_scene_tools(server)
    return server, registry, send


async def test_scene_inherit_routes_paths_to_writable_pinned_session(scene_server):
    server, registry, send = scene_server
    registry.record_readiness("active", "playing")
    registry.record_readiness("pinned", "no_scene")
    params = {"base_path": "res://base.tscn", "path": "res://derived.tscn"}
    send.return_value = {**params, "undoable": False}

    async with Client(server) as client:
        result = await client.call_tool(
            "scene_manage", {"op": "inherit", "params": params, "session_id": "pinned"}
        )

    assert result.data == {**params, "undoable": False}
    send.assert_awaited_once()
    assert send.await_args.kwargs["command"] == "inherit_scene"
    assert send.await_args.kwargs["params"] == params
    assert send.await_args.kwargs["session_id"] == "pinned"
    assert registry.active_session_id == "active"


async def test_scene_inherit_refuses_playing_pinned_session_before_write(scene_server):
    server, registry, send = scene_server
    registry.record_readiness("pinned", "playing")
    send.return_value = {"readiness": "playing"}

    async with Client(server) as client:
        result = await client.call_tool(
            "scene_manage",
            {
                "op": "inherit",
                "params": {"base_path": "res://base.tscn", "path": "res://derived.tscn"},
                "session_id": "pinned",
            },
            raise_on_error=False,
        )

    assert result.is_error
    assert result.structured_content is not None
    error = result.structured_content["error"]
    assert error["code"] == "EDITOR_NOT_READY"
    assert error["data"]["sub_code"] == "EDITOR_PLAYING"
    send.assert_awaited_once()
    assert send.await_args.kwargs["command"] == "get_editor_state"
    assert send.await_args.kwargs["session_id"] == "pinned"


@pytest.mark.parametrize("missing", ["base_path", "path"])
async def test_scene_inherit_requires_both_paths(scene_server, missing):
    server, _, send = scene_server
    params = {"base_path": "res://base.tscn", "path": "res://derived.tscn"}
    del params[missing]

    async with Client(server) as client:
        result = await client.call_tool(
            "scene_manage", {"op": "inherit", "params": params}, raise_on_error=False
        )

    assert result.is_error
    assert result.structured_content is not None
    error = result.structured_content["error"]
    assert error["code"] == "INVALID_PARAMS"
    assert error["data"]["missing"] == [missing]
    send.assert_not_awaited()

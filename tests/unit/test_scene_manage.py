"""Public scene_manage routing with an in-process MCP client."""

from __future__ import annotations

import errno
import hashlib
from contextlib import asynccontextmanager
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import AsyncMock

import pytest
from fastmcp import Client, FastMCP

from godot_ai.godot_client.client import GodotCommandError
from godot_ai.handlers import scene_inheritance
from godot_ai.middleware import PreserveGodotCommandErrorData
from godot_ai.sessions.registry import Session, SessionRegistry
from godot_ai.tools.scene import register_scene_tools

BASE = "res://base.tscn"
DESTINATION = "res://derived.tscn"
SCENE_BYTES = b'[gd_scene]\n\n[node name="Derived" instance=ExtResource("base")]\n'


@pytest.fixture
def scene_server(tmp_path):
    registry = SessionRegistry()
    for session_id in ("active", "pinned"):
        root = tmp_path / session_id
        root.mkdir()
        (root / "project.godot").write_text("config_version=5\n", encoding="utf-8")
        (root / "base.tscn").write_bytes(b"saved base")
        registry.register(
            Session(
                session_id=session_id,
                godot_version="4.7.0",
                project_path=str(root),
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


def _prepare_scene(root, params):
    stage = root / params["stage_path"].removeprefix("res://")
    assert stage.parent.parent == root
    assert stage.parent.name.startswith(".godot-ai-inherit-")
    assert stage.name == "scene.tscn"
    assert stage.parent.is_dir() and not stage.exists()
    stage.write_bytes(SCENE_BYTES)
    return stage


def _prepare_receipt(params):
    return {**params, "stage_sha256": hashlib.sha256(SCENE_BYTES).hexdigest()}


@pytest.mark.parametrize("explicit", [True, False], ids=["explicit", "active-switch"])
async def test_scene_inherit_routes_both_phases_to_the_same_editor(scene_server, explicit):
    server, registry, send = scene_server
    registry.record_readiness("active", "playing")
    registry.record_readiness("pinned", "no_scene")
    if not explicit:
        registry.set_active("pinned")
    root = Path(registry.get("pinned").project_path)
    params = {"base_path": BASE, "path": DESTINATION}

    async def reply(*, command, params, **_):
        if command == "inherit_scene_prepare":
            _prepare_scene(root, params)
            registry.set_active("active")
            return _prepare_receipt(params)
        assert command == "inherit_scene_open"
        assert (root / "derived.tscn").read_bytes() == SCENE_BYTES
        assert not list(root.glob(".godot-ai-inherit-*"))
        return {**params, "undoable": False}

    send.side_effect = reply
    arguments = {"op": "inherit", "params": params}
    if explicit:
        arguments["session_id"] = "pinned"

    async with Client(server) as client:
        result = await client.call_tool("scene_manage", arguments)

    assert result.data == {**params, "undoable": False}
    prepare, activate = [call.kwargs for call in send.await_args_list]
    assert prepare["command"] == "inherit_scene_prepare"
    assert prepare["params"]["base_path"] == BASE
    assert prepare["params"]["path"] == DESTINATION
    assert activate["command"] == "inherit_scene_open"
    assert activate["params"] == params
    assert prepare["session_id"] == activate["session_id"] == "pinned"
    assert prepare["hint_policy"] == "retain"
    assert registry.active_session_id == "active"
    assert not (Path(registry.get("active").project_path) / "derived.tscn").exists()


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


async def _inherit_result(server, *, base_path=BASE, path=DESTINATION):
    async with Client(server) as client:
        return await client.call_tool(
            "scene_manage",
            {
                "op": "inherit",
                "params": {"base_path": base_path, "path": path},
                "session_id": "pinned",
            },
            raise_on_error=False,
        )


@pytest.mark.parametrize("path", ["res://../derived.tscn", "res://file:stream.tscn"])
async def test_scene_inherit_rejects_unsafe_destinations_before_staging(scene_server, path):
    server, registry, send = scene_server
    root = Path(registry.get("pinned").project_path)

    result = await _inherit_result(server, path=path)

    assert result.is_error
    assert result.structured_content["error"]["code"] == "VALUE_OUT_OF_RANGE"
    assert not list(root.glob(".godot-ai-inherit-*"))
    send.assert_not_awaited()


async def test_scene_inherit_requires_the_pinned_project_root(scene_server):
    server, registry, send = scene_server
    root = Path(registry.get("pinned").project_path)
    (root / "project.godot").unlink()

    result = await _inherit_result(server)

    assert result.is_error
    error = result.structured_content["error"]
    assert error["code"] == "RESOURCE_NOT_FOUND"
    assert error["data"]["reason"] == "project_root_unavailable"
    assert not list(root.glob(".godot-ai-inherit-*"))
    send.assert_not_awaited()


async def test_scene_inherit_does_not_stage_through_a_linked_directory(scene_server, tmp_path):
    server, registry, send = scene_server
    root = Path(registry.get("pinned").project_path)
    outside = tmp_path / "outside"
    outside.mkdir()
    try:
        (root / "linked").symlink_to(outside, target_is_directory=True)
    except OSError as exc:
        if getattr(exc, "winerror", None) == 1314:
            pytest.skip("Windows requires Developer Mode or privilege to create a symlink")
        raise

    result = await _inherit_result(server, path="res://linked/derived.tscn")

    assert result.is_error
    error = result.structured_content["error"]
    assert error["code"] == "VALUE_OUT_OF_RANGE"
    assert error["data"]["reason"] == "linked_project_path"
    assert not list(outside.iterdir())
    send.assert_not_awaited()


async def test_scene_inherit_does_not_replace_a_concurrent_writer(scene_server):
    server, registry, send = scene_server
    root = Path(registry.get("pinned").project_path)
    destination = root / "derived.tscn"

    async def reply(*, command, params, **_):
        assert command == "inherit_scene_prepare"
        _prepare_scene(root, params)
        destination.write_bytes(b"competing scene")
        return _prepare_receipt(params)

    send.side_effect = reply
    result = await _inherit_result(server)

    assert result.is_error
    error = result.structured_content["error"]
    assert error["code"] == "INVALID_PARAMS"
    assert error["data"]["reason"] == "destination_exists"
    assert error["data"]["disk_committed"] is False
    assert destination.read_bytes() == b"competing scene"
    assert not list(root.glob(".godot-ai-inherit-*"))
    send.assert_awaited_once()


async def test_scene_inherit_refuses_unsupported_atomic_publication(scene_server, monkeypatch):
    server, registry, send = scene_server
    root = Path(registry.get("pinned").project_path)

    async def reply(*, params, **_):
        _prepare_scene(root, params)
        return _prepare_receipt(params)

    def unsupported(stage, destination):
        raise OSError(errno.ENOTSUP, "cannot publish atomically")

    send.side_effect = reply
    monkeypatch.setattr(scene_inheritance, "_publish_scene", unsupported)
    result = await _inherit_result(server)

    assert result.is_error
    error = result.structured_content["error"]
    assert error["data"]["reason"] == "atomic_publish_unsupported"
    assert error["data"]["disk_committed"] is False
    assert not (root / "derived.tscn").exists()
    assert not list(root.glob(".godot-ai-inherit-*"))
    send.assert_awaited_once()


async def test_scene_inherit_does_not_publish_after_editor_session_changes(scene_server):
    server, registry, send = scene_server
    root = Path(registry.get("pinned").project_path)

    async def reply(*, params, **_):
        _prepare_scene(root, params)
        registry.unregister("pinned")
        return _prepare_receipt(params)

    send.side_effect = reply
    result = await _inherit_result(server)

    assert result.is_error
    error = result.structured_content["error"]
    assert error["code"] == "PLUGIN_DISCONNECTED"
    assert error["data"]["reason"] == "session_changed"
    assert not (root / "derived.tscn").exists()
    assert not list(root.glob(".godot-ai-inherit-*"))
    send.assert_awaited_once()


@pytest.mark.parametrize("tampered", ["path", "bytes"])
async def test_scene_inherit_requires_the_expected_stage_receipt(scene_server, tampered):
    server, registry, send = scene_server
    root = Path(registry.get("pinned").project_path)

    async def reply(*, params, **_):
        stage = _prepare_scene(root, params)
        (stage.parent / "unowned.txt").write_bytes(b"keep")
        receipt = _prepare_receipt(params)
        if tampered == "path":
            receipt["stage_path"] = "res://base.tscn"
        else:
            stage.write_bytes(b"different contents")
        return receipt

    send.side_effect = reply
    result = await _inherit_result(server)

    assert result.is_error
    error = result.structured_content["error"]
    assert error["data"]["reason"] == "stage_verification_failed"
    assert not (root / "derived.tscn").exists()
    assert (root / "base.tscn").read_bytes() == b"saved base"
    (remaining,) = root.glob(".godot-ai-inherit-*/*")
    assert remaining.name == "unowned.txt" and remaining.read_bytes() == b"keep"
    send.assert_awaited_once()


@pytest.mark.parametrize("known", [True, False], ids=["refusal", "lost-response"])
async def test_scene_inherit_reports_committed_file_when_open_fails(scene_server, known):
    server, registry, send = scene_server
    root = Path(registry.get("pinned").project_path)

    async def reply(*, command, params, **_):
        if command == "inherit_scene_prepare":
            _prepare_scene(root, params)
            return _prepare_receipt(params)
        if known:
            raise GodotCommandError(
                "EDITED_SCENE_MISMATCH", "Could not open", {"tab_opened": False}
            )
        raise TimeoutError

    send.side_effect = reply
    result = await _inherit_result(server)

    assert result.is_error
    error = result.structured_content["error"]
    assert error["data"]["disk_committed"] is True
    assert error["data"]["path"] == DESTINATION
    if known:
        assert error["code"] == "EDITED_SCENE_MISMATCH"
        assert error["data"]["tab_opened"] is False
    else:
        assert error["code"] == "TRANSPORT_OUTCOME_UNKNOWN"
        assert "tab_opened" not in error["data"]
    assert (root / "derived.tscn").read_bytes() == SCENE_BYTES
    assert not list(root.glob(".godot-ai-inherit-*"))

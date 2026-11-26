from __future__ import annotations

import re
from pathlib import Path
from unittest.mock import AsyncMock, patch

import pytest

from godot_ai.godot_client.client import GodotCommandError
from godot_ai.handlers import csg as csg_handlers
from godot_ai.handlers import gridmap as gridmap_handlers
from godot_ai.protocol.errors import ErrorCode
from godot_ai.runtime.direct import DirectRuntime
from godot_ai.sessions.registry import Session, SessionRegistry


class StubClient:
    def __init__(self) -> None:
        self.calls: list[dict] = []

    async def send(
        self,
        command,
        params=None,
        session_id=None,
        timeout=5.0,
        hint_policy=None,
    ):
        self.calls.append(
            {
                "command": command,
                "params": params or {},
                "session_id": session_id,
                "timeout": timeout,
                "hint_policy": hint_policy,
            }
        )
        return {"ok": True}


async def test_gridmap_set_item_forwards_command_and_params():
    client = StubClient()
    runtime = DirectRuntime(registry=SessionRegistry(), client=client)

    await gridmap_handlers.gridmap_set_item(
        runtime,
        path="/Main/Terrain",
        item=3,
        map_x=1,
        map_y=2,
        map_z=-1,
        orientation=9,
    )

    assert client.calls[-1]["command"] == "gridmap_set_item"
    assert client.calls[-1]["params"] == {
        "path": "/Main/Terrain",
        "item": 3,
        "map_x": 1,
        "map_y": 2,
        "map_z": -1,
        "orientation": 9,
    }


async def test_gridmap_set_item_defaults_orientation_to_zero():
    client = StubClient()
    runtime = DirectRuntime(registry=SessionRegistry(), client=client)

    await gridmap_handlers.gridmap_set_item(
        runtime,
        path="/Main/Terrain",
        item=3,
        map_x=1,
        map_y=2,
        map_z=0,
    )

    assert client.calls[-1]["params"]["orientation"] == 0


async def test_gridmap_set_item_requires_writable_async():
    client = StubClient()
    runtime = DirectRuntime(registry=SessionRegistry(), client=client)

    with patch(
        "godot_ai.handlers.gridmap.require_writable_async",
        new_callable=AsyncMock,
    ) as mock_require_writable:
        await gridmap_handlers.gridmap_set_item(
            runtime,
            path="/Main/Terrain",
            item=1,
            map_x=0,
            map_y=0,
            map_z=0,
        )

    mock_require_writable.assert_awaited_once_with(runtime)


async def test_gridmap_fill_forwards_command_and_params():
    client = StubClient()
    runtime = DirectRuntime(registry=SessionRegistry(), client=client)

    await gridmap_handlers.gridmap_fill(
        runtime,
        path="/Main/Terrain",
        item=2,
        rect_x=1,
        rect_y=2,
        rect_z=3,
        rect_w=4,
        rect_h=5,
        rect_d=6,
        orientation=0,
    )

    assert client.calls[-1]["command"] == "gridmap_fill"
    assert client.calls[-1]["params"] == {
        "path": "/Main/Terrain",
        "item": 2,
        "rect_x": 1,
        "rect_y": 2,
        "rect_z": 3,
        "rect_w": 4,
        "rect_h": 5,
        "rect_d": 6,
        "orientation": 0,
    }


async def test_gridmap_fill_requires_writable_async():
    client = StubClient()
    runtime = DirectRuntime(registry=SessionRegistry(), client=client)

    with patch(
        "godot_ai.handlers.gridmap.require_writable_async",
        new_callable=AsyncMock,
    ) as mock_require_writable:
        await gridmap_handlers.gridmap_fill(
            runtime,
            path="/Main/Terrain",
            item=1,
            rect_x=0,
            rect_y=0,
            rect_z=0,
            rect_w=1,
            rect_h=1,
            rect_d=1,
        )

    mock_require_writable.assert_awaited_once_with(runtime)


async def test_gridmap_clear_forwards_command_and_params():
    client = StubClient()
    runtime = DirectRuntime(registry=SessionRegistry(), client=client)

    await gridmap_handlers.gridmap_clear(runtime, path="/Main/Terrain")

    assert client.calls[-1]["command"] == "gridmap_clear"
    assert client.calls[-1]["params"] == {"path": "/Main/Terrain"}


async def test_gridmap_clear_requires_writable_async():
    client = StubClient()
    runtime = DirectRuntime(registry=SessionRegistry(), client=client)

    with patch(
        "godot_ai.handlers.gridmap.require_writable_async",
        new_callable=AsyncMock,
    ) as mock_require_writable:
        await gridmap_handlers.gridmap_clear(runtime, path="/Main/Terrain")

    mock_require_writable.assert_awaited_once_with(runtime)


async def test_gridmap_get_used_cells_forwards_command_and_params():
    client = StubClient()
    runtime = DirectRuntime(registry=SessionRegistry(), client=client)

    await gridmap_handlers.gridmap_get_used_cells(runtime, path="/Main/Terrain")

    assert client.calls[-1]["command"] == "gridmap_get_used_cells"
    assert client.calls[-1]["params"] == {"path": "/Main/Terrain"}


async def test_gridmap_get_used_cells_does_not_call_require_writable():
    client = StubClient()
    runtime = DirectRuntime(registry=SessionRegistry(), client=client)

    with patch(
        "godot_ai.handlers.gridmap.require_writable_async",
        new_callable=AsyncMock,
    ) as mock_require_writable:
        await gridmap_handlers.gridmap_get_used_cells(runtime, path="/Main/Terrain")

    mock_require_writable.assert_not_called()


async def test_gridmap_list_library_items_forwards_command_and_params():
    client = StubClient()
    runtime = DirectRuntime(registry=SessionRegistry(), client=client)

    await gridmap_handlers.gridmap_list_library_items(runtime, path="/Main/Terrain")

    assert client.calls[-1]["command"] == "gridmap_list_library_items"
    assert client.calls[-1]["params"] == {"path": "/Main/Terrain"}


async def test_gridmap_list_library_items_does_not_call_require_writable():
    client = StubClient()
    runtime = DirectRuntime(registry=SessionRegistry(), client=client)

    with patch(
        "godot_ai.handlers.gridmap.require_writable_async",
        new_callable=AsyncMock,
    ) as mock_require_writable:
        await gridmap_handlers.gridmap_list_library_items(runtime, path="/Main/Terrain")

    mock_require_writable.assert_not_called()


async def test_csg_create_forwards_command_and_params():
    client = StubClient()
    runtime = DirectRuntime(registry=SessionRegistry(), client=client)

    await csg_handlers.csg_create(
        runtime,
        parent_path="/Main",
        name="Cave",
        shape="sphere",
        operation="subtraction",
    )

    assert client.calls[-1]["command"] == "csg_create"
    assert client.calls[-1]["params"] == {
        "parent_path": "/Main",
        "name": "Cave",
        "shape": "sphere",
        "operation": "subtraction",
    }


async def test_csg_bake_mesh_requests_native_materials_by_default(tmp_path):
    (tmp_path / "project.godot").touch()
    registry = SessionRegistry()
    registry.register(Session("pinned", "4.7.2", str(tmp_path), "4.0.0"))
    client = StubClient()
    runtime = DirectRuntime(registry=registry, client=client, session_id="pinned")
    with pytest.raises(GodotCommandError) as error:
        await csg_handlers.csg_bake_mesh(runtime, "/Main/Door", "res://assets/door.res")
    assert error.value.code == ErrorCode.INTERNAL_ERROR
    assert error.value.data["disk_committed"] is False
    assert len(client.calls) == 1
    request = client.calls[0]
    assert request["command"] == "csg_bake_mesh"
    assert request["timeout"] == csg_handlers.CSG_BAKE_TIMEOUT_SEC
    assert request["session_id"] == "pinned"
    params = request["params"]
    assert params["stage_path"].startswith("res://.godot-ai-csg-")
    assert params["stage_path"].endswith("/mesh.res")
    assert params["path"] == "/Main/Door"
    assert params["resource_path"] == "res://assets/door.res"
    assert "apply_material_override" not in params
    assert not (tmp_path / "assets").exists()
    assert list(tmp_path.glob(".godot-ai-csg-*")) == []


def test_csg_bake_mesh_timeout_allows_for_editor_and_transport():
    native = Path(__file__).resolve().parents[2] / "plugin/addons/godot_ai/handlers/csg_handler.gd"
    budget = re.search(
        r"^const _BAKE_DEFERRED_TIMEOUT_MS := (\d+)$", native.read_text(encoding="utf-8"), re.M
    )
    assert budget and int(budget.group(1)) == csg_handlers.CSG_BAKE_PLUGIN_TIMEOUT_MS
    assert csg_handlers.CSG_BAKE_TIMEOUT_SEC == int(budget.group(1)) / 1000 + 2


async def test_csg_create_defaults_shape_and_operation():
    client = StubClient()
    runtime = DirectRuntime(registry=SessionRegistry(), client=client)

    await csg_handlers.csg_create(runtime, parent_path="/Main")

    assert client.calls[-1]["params"] == {
        "parent_path": "/Main",
        "name": "",
        "shape": "box",
        "operation": "union",
    }


async def test_csg_create_requires_writable_async():
    client = StubClient()
    runtime = DirectRuntime(registry=SessionRegistry(), client=client)

    with patch(
        "godot_ai.handlers.csg.require_writable_async",
        new_callable=AsyncMock,
    ) as mock_require_writable:
        await csg_handlers.csg_create(runtime, parent_path="/Main")

    mock_require_writable.assert_awaited_once_with(runtime)


async def test_csg_set_operation_forwards_command_and_params():
    client = StubClient()
    runtime = DirectRuntime(registry=SessionRegistry(), client=client)

    await csg_handlers.csg_set_operation(
        runtime,
        path="/Main/Cave",
        operation="subtraction",
    )

    assert client.calls[-1]["command"] == "csg_set_operation"
    assert client.calls[-1]["params"] == {
        "path": "/Main/Cave",
        "operation": "subtraction",
    }


async def test_csg_set_operation_requires_writable_async():
    client = StubClient()
    runtime = DirectRuntime(registry=SessionRegistry(), client=client)

    with patch(
        "godot_ai.handlers.csg.require_writable_async",
        new_callable=AsyncMock,
    ) as mock_require_writable:
        await csg_handlers.csg_set_operation(
            runtime,
            path="/Main/Cave",
            operation="intersection",
        )

    mock_require_writable.assert_awaited_once_with(runtime)

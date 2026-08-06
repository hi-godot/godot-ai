from __future__ import annotations

from unittest.mock import AsyncMock, patch

from godot_ai.handlers import csg as csg_handlers
from godot_ai.handlers import gridmap as gridmap_handlers
from godot_ai.runtime.direct import DirectRuntime
from godot_ai.sessions.registry import SessionRegistry


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

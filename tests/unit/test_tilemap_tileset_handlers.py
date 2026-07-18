from __future__ import annotations

from godot_ai.handlers import editor as editor_handlers
from godot_ai.handlers import tilemap as tilemap_handlers
from godot_ai.handlers import tileset as tileset_handlers
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
        if command == "take_screenshot":
            source = (params or {}).get("source", "viewport")
            return {
                "source": source,
                "width": 1,
                "height": 1,
                "original_width": 100,
                "original_height": 100,
                "format": "png",
                "image_base64": (
                    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR4nGNgYAAA"
                    "AAAMAASsJTYQAAAAASUVORK5CYII="
                ),
            }
        return {"ok": True}


async def test_editor_screenshot_handler_passes_viewport_2d_source():
    client = StubClient()
    runtime = DirectRuntime(registry=SessionRegistry(), client=client)

    result = await editor_handlers.editor_screenshot(
        runtime,
        source="viewport_2d",
        include_image=False,
    )

    assert client.calls[-1]["command"] == "take_screenshot"
    assert client.calls[-1]["params"]["source"] == "viewport_2d"
    assert result["source"] == "viewport_2d"


async def test_tilemap_set_cell_handler_forwards_command_and_params():
    client = StubClient()
    runtime = DirectRuntime(registry=SessionRegistry(), client=client)

    await tilemap_handlers.tilemap_set_cell(
        runtime,
        path="/Main/Ground",
        source_id=2,
        atlas_col=1,
        atlas_row=3,
        map_x=8,
        map_y=9,
    )

    assert client.calls[-1]["command"] == "tilemap_set_cell"
    assert client.calls[-1]["params"] == {
        "path": "/Main/Ground",
        "source_id": 2,
        "atlas_col": 1,
        "atlas_row": 3,
        "map_x": 8,
        "map_y": 9,
    }


async def test_tilemap_set_cell_requires_writable_async():
    from unittest.mock import AsyncMock, patch

    client = StubClient()
    runtime = DirectRuntime(registry=SessionRegistry(), client=client)

    with patch(
        "godot_ai.handlers.tilemap.require_writable_async",
        new_callable=AsyncMock,
    ) as mock_require_writable:
        await tilemap_handlers.tilemap_set_cell(
            runtime,
            path="/Main/Ground",
            source_id=2,
            atlas_col=1,
            atlas_row=3,
            map_x=8,
            map_y=9,
        )

    mock_require_writable.assert_awaited_once_with(runtime)


async def test_tilemap_set_cells_rect_handler_forwards_command_and_params():
    client = StubClient()
    runtime = DirectRuntime(registry=SessionRegistry(), client=client)

    await tilemap_handlers.tilemap_set_cells_rect(
        runtime,
        path="/Main/Ground",
        source_id=5,
        atlas_col=0,
        atlas_row=0,
        rect_x=1,
        rect_y=2,
        rect_w=3,
        rect_h=4,
    )

    assert client.calls[-1]["command"] == "tilemap_set_cells_rect"
    assert client.calls[-1]["params"] == {
        "path": "/Main/Ground",
        "source_id": 5,
        "atlas_col": 0,
        "atlas_row": 0,
        "rect_x": 1,
        "rect_y": 2,
        "rect_w": 3,
        "rect_h": 4,
    }


async def test_tilemap_set_cells_rect_requires_writable_async():
    from unittest.mock import AsyncMock, patch

    client = StubClient()
    runtime = DirectRuntime(registry=SessionRegistry(), client=client)

    with patch(
        "godot_ai.handlers.tilemap.require_writable_async",
        new_callable=AsyncMock,
    ) as mock_require_writable:
        await tilemap_handlers.tilemap_set_cells_rect(
            runtime,
            path="/Main/Ground",
            source_id=5,
            atlas_col=0,
            atlas_row=0,
            rect_x=1,
            rect_y=2,
            rect_w=3,
            rect_h=4,
        )

    mock_require_writable.assert_awaited_once_with(runtime)


async def test_tilemap_clear_handler_forwards_command_and_params():
    client = StubClient()
    runtime = DirectRuntime(registry=SessionRegistry(), client=client)

    await tilemap_handlers.tilemap_clear(runtime, path="/Main/Ground")

    assert client.calls[-1]["command"] == "tilemap_clear"
    assert client.calls[-1]["params"] == {"path": "/Main/Ground"}


async def test_tilemap_clear_requires_writable_async():
    from unittest.mock import AsyncMock, patch

    client = StubClient()
    runtime = DirectRuntime(registry=SessionRegistry(), client=client)

    with patch(
        "godot_ai.handlers.tilemap.require_writable_async",
        new_callable=AsyncMock,
    ) as mock_require_writable:
        await tilemap_handlers.tilemap_clear(runtime, path="/Main/Ground")

    mock_require_writable.assert_awaited_once_with(runtime)


async def test_tilemap_get_cells_handler_forwards_command_and_params():
    client = StubClient()
    runtime = DirectRuntime(registry=SessionRegistry(), client=client)

    await tilemap_handlers.tilemap_get_cells(runtime, path="/Main/Ground")

    assert client.calls[-1]["command"] == "tilemap_get_cells"
    assert client.calls[-1]["params"] == {"path": "/Main/Ground"}


async def test_tileset_get_atlas_tiles_calls_send_command():
    client = StubClient()
    runtime = DirectRuntime(registry=SessionRegistry(), client=client)

    await tileset_handlers.tileset_get_atlas_tiles(
        runtime,
        tileset_path="res://tilesets/my_biome/my_biome.tres",
        source_id=8,
    )

    assert client.calls[-1]["command"] == "tileset_get_atlas_tiles"
    assert client.calls[-1]["params"] == {
        "tileset_path": "res://tilesets/my_biome/my_biome.tres",
        "source_id": 8,
    }


async def test_tileset_get_atlas_tiles_returns_result_unchanged():
    expected = {"data": {"tiles": [{"col": 0, "row": 0}], "count": 1}}

    class FixedClient(StubClient):
        async def send(
            self,
            command,
            params=None,
            session_id=None,
            timeout=5.0,
            hint_policy=None,
        ):
            await super().send(command, params, session_id, timeout, hint_policy)
            return expected

    client = FixedClient()
    runtime = DirectRuntime(registry=SessionRegistry(), client=client)

    result = await tileset_handlers.tileset_get_atlas_tiles(
        runtime,
        tileset_path="res://some.tres",
        source_id=0,
    )

    assert result is expected


async def test_tileset_get_atlas_tiles_does_not_call_require_writable():
    from unittest.mock import AsyncMock, patch

    client = StubClient()
    runtime = DirectRuntime(registry=SessionRegistry(), client=client)

    with patch(
        "godot_ai.handlers.tileset.require_writable_async",
        new_callable=AsyncMock,
        create=True,
    ) as mock_require_writable:
        await tileset_handlers.tileset_get_atlas_tiles(
            runtime,
            tileset_path="res://some.tres",
            source_id=0,
        )

    mock_require_writable.assert_not_called()


async def test_tileset_get_atlas_image_calls_send_command_with_default_max_size():
    client = StubClient()
    runtime = DirectRuntime(registry=SessionRegistry(), client=client)

    await tileset_handlers.tileset_get_atlas_image(
        runtime,
        tileset_path="res://tilesets/atlas.tres",
        source_id=3,
    )

    assert client.calls[-1]["command"] == "tileset_get_atlas_image"
    assert client.calls[-1]["params"] == {
        "tileset_path": "res://tilesets/atlas.tres",
        "source_id": 3,
        "max_size": 0,
    }


async def test_tileset_get_atlas_image_returns_result_unchanged():
    expected = {
        "data": {
            "image_base64": (
                "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR4nGNgYAAA"
                "AAMAASsJTYQAAAAASUVORK5CYII="
            ),
            "width": 1,
            "height": 1,
            "original_width": 1,
            "original_height": 1,
            "format": "png",
        }
    }

    class FixedClient(StubClient):
        async def send(
            self,
            command,
            params=None,
            session_id=None,
            timeout=5.0,
            hint_policy=None,
        ):
            await super().send(command, params, session_id, timeout, hint_policy)
            return expected

    client = FixedClient()
    runtime = DirectRuntime(registry=SessionRegistry(), client=client)

    result = await tileset_handlers.tileset_get_atlas_image(
        runtime,
        tileset_path="res://some.tres",
        source_id=0,
        max_size=64,
    )

    assert result is expected


async def test_tileset_get_atlas_image_does_not_call_require_writable():
    from unittest.mock import AsyncMock, patch

    client = StubClient()
    runtime = DirectRuntime(registry=SessionRegistry(), client=client)

    with patch(
        "godot_ai.handlers.tileset.require_writable_async",
        new_callable=AsyncMock,
        create=True,
    ) as mock_require_writable:
        await tileset_handlers.tileset_get_atlas_image(
            runtime,
            tileset_path="res://some.tres",
            source_id=0,
        )

    mock_require_writable.assert_not_called()

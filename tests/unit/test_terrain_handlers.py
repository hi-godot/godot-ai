from __future__ import annotations

from unittest.mock import AsyncMock, patch

from godot_ai.handlers import terrain as terrain_handlers
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


async def test_terrain_create_forwards_command_and_params():
    client = StubClient()
    runtime = DirectRuntime(registry=SessionRegistry(), client=client)

    await terrain_handlers.terrain_create(
        runtime,
        parent_path="/Main",
        name="Hills",
        size=64,
        cell_size=3.0,
        seed=42,
        noise_type="ridged",
        frequency=0.02,
        octaves=4,
        height_scale=12.0,
        base_height=1.0,
        generate_collision=False,
    )

    assert client.calls[-1]["command"] == "terrain_create"
    assert client.calls[-1]["params"] == {
        "parent_path": "/Main",
        "name": "Hills",
        "size": 64,
        "cell_size": 3.0,
        "seed": 42,
        "noise_type": "ridged",
        "frequency": 0.02,
        "octaves": 4,
        "height_scale": 12.0,
        "base_height": 1.0,
        "generate_collision": False,
    }


async def test_terrain_create_defaults():
    client = StubClient()
    runtime = DirectRuntime(registry=SessionRegistry(), client=client)

    await terrain_handlers.terrain_create(runtime, parent_path="/Main")

    assert client.calls[-1]["params"] == {
        "parent_path": "/Main",
        "name": "",
        "size": 48,
        "cell_size": 2.0,
        "seed": 1337,
        "noise_type": "simplex",
        "frequency": 0.05,
        "octaves": 3,
        "height_scale": 8.0,
        "base_height": 0.0,
        "generate_collision": True,
    }


async def test_terrain_create_requires_writable_async():
    client = StubClient()
    runtime = DirectRuntime(registry=SessionRegistry(), client=client)

    with patch(
        "godot_ai.handlers.terrain.require_writable_async",
        new_callable=AsyncMock,
    ) as mock_require_writable:
        await terrain_handlers.terrain_create(runtime, parent_path="/Main")

    mock_require_writable.assert_awaited_once_with(runtime)


async def test_terrain_regenerate_forwards_command_and_params():
    client = StubClient()
    runtime = DirectRuntime(registry=SessionRegistry(), client=client)

    await terrain_handlers.terrain_regenerate(
        runtime,
        path="/Main/Hills",
        seed=999,
        height_scale=20.0,
    )

    assert client.calls[-1]["command"] == "terrain_regenerate"
    assert client.calls[-1]["params"] == {
        "path": "/Main/Hills",
        "size": 48,
        "cell_size": 2.0,
        "seed": 999,
        "noise_type": "simplex",
        "frequency": 0.05,
        "octaves": 3,
        "height_scale": 20.0,
        "base_height": 0.0,
        "generate_collision": True,
    }


async def test_terrain_regenerate_requires_writable_async():
    client = StubClient()
    runtime = DirectRuntime(registry=SessionRegistry(), client=client)

    with patch(
        "godot_ai.handlers.terrain.require_writable_async",
        new_callable=AsyncMock,
    ) as mock_require_writable:
        await terrain_handlers.terrain_regenerate(runtime, path="/Main/Hills")

    mock_require_writable.assert_awaited_once_with(runtime)

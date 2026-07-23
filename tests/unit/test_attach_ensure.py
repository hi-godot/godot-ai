"""Unit contracts for attach backend ensure/startup coordination."""

from __future__ import annotations

import asyncio
from pathlib import Path

import pytest

from godot_ai import __version__
from godot_ai.attach.ensure import (
    AttachStartupError,
    BackendEnsurer,
    BackendStatus,
    SpawnedBackend,
    _backend_spawn_env,
    detached_spawn_kwargs,
)
from godot_ai.protocol.attach import (
    ATTACH_PROTOCOL_VERSION,
    ATTACH_SPAWNED_ENV,
    DEV_TRANSPORT_ENV,
)


class FakeProcess:
    def __init__(self, exit_code: int | None = None) -> None:
        self.exit_code = exit_code

    def poll(self) -> int | None:
        return self.exit_code


def status(*, version: str = __version__, instance_id: str = "instance-a") -> BackendStatus:
    return BackendStatus(
        instance_id=instance_id,
        server_version=version,
        attach_protocol_version=ATTACH_PROTOCOL_VERSION,
        ws_port=9500,
        exclude_domains=(),
        owner_type="attach",
        tool_catalog_hash="a" * 64,
        package_path="/tmp/godot_ai",
    )


async def test_compatible_backend_is_adopted_without_spawn(tmp_path: Path) -> None:
    spawns: list[bool] = []

    async def probe(_port: int) -> BackendStatus:
        return status()

    ensurer = BackendEnsurer(
        probe=probe,
        spawn=lambda *_args: spawns.append(True),  # type: ignore[arg-type,return-value]
        runtime_dir=tmp_path,
    )

    result = await ensurer.ensure()

    assert result.instance_id == "instance-a"
    assert spawns == []


async def test_lock_is_held_until_health_and_two_callers_spawn_once(tmp_path: Path) -> None:
    state = {"spawned": False, "healthy": False, "spawns": 0}

    async def probe(_port: int) -> BackendStatus | None:
        if not state["spawned"]:
            return None
        if not state["healthy"]:
            await asyncio.sleep(0.02)
            state["healthy"] = True
            return None
        return status()

    def spawn(_port: int, _ws_port: int, _domains: tuple[str, ...]) -> SpawnedBackend:
        state["spawned"] = True
        state["spawns"] += 1
        return SpawnedBackend(FakeProcess(), tmp_path / "backend.log")

    ensurer = BackendEnsurer(
        probe=probe,
        spawn=spawn,
        port_check=lambda _port: True,
        runtime_dir=tmp_path,
        poll_seconds=0.001,
    )

    first, second = await asyncio.gather(ensurer.ensure(), ensurer.ensure())

    assert first.instance_id == second.instance_id
    assert state["spawns"] == 1


async def test_version_skew_is_terminal_without_spawn_or_kill(tmp_path: Path) -> None:
    spawns: list[bool] = []

    async def probe(_port: int) -> BackendStatus:
        return status(version="0.0.0")

    ensurer = BackendEnsurer(
        probe=probe,
        spawn=lambda *_args: spawns.append(True),  # type: ignore[arg-type,return-value]
        runtime_dir=tmp_path,
    )

    with pytest.raises(AttachStartupError) as exc_info:
        await ensurer.ensure()

    assert exc_info.value.code == "NEW_CLIENT_SESSION_REQUIRED"
    assert "server_version" in exc_info.value.data["differences"]
    assert spawns == []


async def test_three_concurrent_bridges_with_two_version_pins_choose_one_backend(
    tmp_path: Path,
) -> None:
    state = {"spawned": False, "spawns": 0}

    async def probe(_port: int) -> BackendStatus | None:
        return status() if state["spawned"] else None

    def spawn(_port: int, _ws_port: int, _domains: tuple[str, ...]) -> SpawnedBackend:
        state["spawned"] = True
        state["spawns"] += 1
        return SpawnedBackend(FakeProcess(), tmp_path / "backend.log")

    common = {
        "probe": probe,
        "spawn": spawn,
        "port_check": lambda _port: True,
        "runtime_dir": tmp_path,
        "poll_seconds": 0.001,
    }
    bridges = [
        BackendEnsurer(required_version=__version__, **common),
        BackendEnsurer(required_version=__version__, **common),
        BackendEnsurer(required_version="older-client-pin", **common),
    ]

    results = await asyncio.gather(*(bridge.ensure() for bridge in bridges), return_exceptions=True)

    compatible = [result for result in results if isinstance(result, BackendStatus)]
    incompatible = [result for result in results if isinstance(result, AttachStartupError)]
    assert state["spawns"] == 1
    assert len(compatible) == 2
    assert len(incompatible) == 1
    assert incompatible[0].code == "NEW_CLIENT_SESSION_REQUIRED"
    assert "cannot be repaired" in incompatible[0].hint


async def test_foreign_http_occupant_never_spawns(tmp_path: Path) -> None:
    spawns: list[bool] = []

    async def probe(_port: int) -> None:
        return None

    ensurer = BackendEnsurer(
        probe=probe,
        spawn=lambda *_args: spawns.append(True),  # type: ignore[arg-type,return-value]
        port_check=lambda port: port != 8000,
        runtime_dir=tmp_path,
    )

    with pytest.raises(AttachStartupError) as exc_info:
        await ensurer.ensure()

    assert exc_info.value.code == "PORT_OCCUPIED"
    assert spawns == []


def test_detached_spawn_arguments_isolate_stdio_on_windows() -> None:
    kwargs = detached_spawn_kwargs(platform="nt")
    assert kwargs["stdin"] is not None
    assert kwargs["close_fds"] is True
    assert kwargs["creationflags"] != 0
    assert "start_new_session" not in kwargs


def test_detached_spawn_arguments_isolate_stdio_on_posix() -> None:
    kwargs = detached_spawn_kwargs(platform="posix")
    assert kwargs["stdin"] is not None
    assert kwargs["close_fds"] is True
    assert kwargs["start_new_session"] is True
    assert "creationflags" not in kwargs


def test_backend_spawn_environment_removes_parent_process_markers(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("GODOT_AI_PLUGIN_SPAWNED", "1")
    monkeypatch.setenv("GODOT_AI_OWNER_PID", "123")
    monkeypatch.setenv("GODOT_AI_WS_TOKEN", "secret")
    monkeypatch.setenv(DEV_TRANSPORT_ENV, "streamable-http")
    monkeypatch.setenv("GODOT_AI_UNRELATED", "preserved")

    env = _backend_spawn_env()

    assert env[ATTACH_SPAWNED_ENV] == "1"
    assert env["GODOT_AI_UNRELATED"] == "preserved"
    assert "GODOT_AI_PLUGIN_SPAWNED" not in env
    assert "GODOT_AI_OWNER_PID" not in env
    assert "GODOT_AI_WS_TOKEN" not in env
    assert DEV_TRANSPORT_ENV not in env

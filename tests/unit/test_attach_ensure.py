"""Unit contracts for attach backend ensure/startup coordination."""

from __future__ import annotations

import asyncio
import os
import socket
import sys
from pathlib import Path
from types import SimpleNamespace

import httpx
import pytest

from godot_ai import __version__
from godot_ai.attach import ensure as ensure_module
from godot_ai.attach.ensure import (
    AdvisoryFileLock,
    AttachStartupError,
    BackendEnsurer,
    BackendStatus,
    SpawnedBackend,
    _backend_spawn_env,
    detached_spawn_kwargs,
    port_available,
    probe_backend,
    spawn_backend,
    user_runtime_dir,
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


def status_payload(**overrides: object) -> dict[str, object]:
    payload: dict[str, object] = {
        "name": "godot-ai",
        "instance_id": "instance-a",
        "server_version": __version__,
        "attach_protocol_version": ATTACH_PROTOCOL_VERSION,
        "ws_port": 9500,
        "exclude_domains": [],
        "owner_type": "attach",
        "tool_catalog_hash": "a" * 64,
        "package_path": "/tmp/godot_ai",
    }
    payload.update(overrides)
    return payload


def install_probe_response(
    monkeypatch: pytest.MonkeyPatch,
    *,
    response: httpx.Response | None = None,
    error: Exception | None = None,
) -> None:
    class FakeClient:
        def __init__(self, *, timeout: float, trust_env: bool) -> None:
            self.timeout = timeout
            assert trust_env is False

        async def __aenter__(self):
            return self

        async def __aexit__(self, *_args):
            return None

        async def get(self, _url: str) -> httpx.Response:
            if error is not None:
                raise error
            assert response is not None
            return response

    monkeypatch.setattr(ensure_module.httpx, "AsyncClient", FakeClient)


def test_backend_status_validates_brand_fields_and_domains() -> None:
    parsed = BackendStatus.from_payload(status_payload(exclude_domains=["theme", "audio"]))
    assert parsed.exclude_domains == ("audio", "theme")

    with pytest.raises(ValueError, match="identify itself"):
        BackendStatus.from_payload({"name": "other"})
    with pytest.raises(ValueError, match="instance_id"):
        BackendStatus.from_payload(status_payload(instance_id=42))
    with pytest.raises(ValueError, match="excluded domains"):
        BackendStatus.from_payload(status_payload(exclude_domains=["audio", 42]))


def test_attach_startup_error_carries_source_retryability() -> None:
    transient = AttachStartupError(
        "ATTACH_LOCK_TIMEOUT",
        "lock busy",
        hint="retry",
        retryable=True,
        data={"path": "attach.lock"},
    )
    terminal = AttachStartupError(
        "BACKEND_START_FAILED",
        "child exited",
        hint="inspect log",
    )

    assert transient.data == {
        "retryable": True,
        "hint": "retry",
        "path": "attach.lock",
    }
    assert terminal.data["retryable"] is False


def test_user_runtime_dir_covers_override_and_platform_fallbacks(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    override = tmp_path / "override"
    monkeypatch.setenv(ensure_module.RUNTIME_DIR_ENV, str(override))
    assert user_runtime_dir() == override.resolve()

    monkeypatch.delenv(ensure_module.RUNTIME_DIR_ENV)
    monkeypatch.setattr(ensure_module.tempfile, "gettempdir", lambda: str(tmp_path))
    if os.name == "nt":
        monkeypatch.setenv("LOCALAPPDATA", str(tmp_path / "local"))
        assert user_runtime_dir() == (tmp_path / "local" / "godot-ai" / "runtime").resolve()
        monkeypatch.delenv("LOCALAPPDATA")
        assert user_runtime_dir() == (tmp_path / "godot-ai-runtime").resolve()
    else:
        monkeypatch.setattr(ensure_module.os, "getuid", lambda: 42)
        monkeypatch.setenv("XDG_RUNTIME_DIR", str(tmp_path / "xdg"))
        assert user_runtime_dir() == (tmp_path / "xdg" / "godot-ai").resolve()
        monkeypatch.delenv("XDG_RUNTIME_DIR")
        assert user_runtime_dir() == (tmp_path / "godot-ai-42").resolve()


def test_user_runtime_dir_tolerates_chmod_failure(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    if os.name == "nt":
        pytest.skip("chmod hardening is POSIX-only")
    monkeypatch.setenv(ensure_module.RUNTIME_DIR_ENV, str(tmp_path / "runtime"))

    def fail_chmod(_path: Path, _mode: int) -> None:
        raise OSError("unsupported")

    monkeypatch.setattr(Path, "chmod", fail_chmod)
    assert user_runtime_dir().name == "runtime"


def test_user_runtime_dir_selects_windows_paths_without_host_path_semantics(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    class FakePath:
        def __init__(self, value: object) -> None:
            self.value = str(value)

        def __truediv__(self, child: str):
            return FakePath(f"{self.value}/{child}")

        def expanduser(self):
            return self

        def mkdir(self, **_kwargs) -> None:
            return None

        def resolve(self):
            return self

    monkeypatch.delenv(ensure_module.RUNTIME_DIR_ENV, raising=False)
    monkeypatch.setattr(ensure_module.os, "name", "nt")
    monkeypatch.setattr(ensure_module, "Path", FakePath)
    monkeypatch.setenv("LOCALAPPDATA", "C:/runtime-base")
    assert user_runtime_dir().value == "C:/runtime-base/godot-ai/runtime"

    monkeypatch.delenv("LOCALAPPDATA")
    monkeypatch.setattr(ensure_module.tempfile, "gettempdir", lambda: "C:/temp")
    assert user_runtime_dir().value == "C:/temp/godot-ai-runtime"


async def test_advisory_lock_times_out_and_release_without_handle_is_safe(tmp_path: Path) -> None:
    path = tmp_path / "attach.lock"
    first = AdvisoryFileLock(path)
    await first.__aenter__()
    try:
        contender = AdvisoryFileLock(path, timeout_seconds=0.01, poll_seconds=0.001)
        with pytest.raises(AttachStartupError, match="Timed out") as exc_info:
            await contender.__aenter__()
        assert exc_info.value.code == "ATTACH_LOCK_TIMEOUT"
        assert exc_info.value.data["retryable"] is True
        contender._release()
    finally:
        await first.__aexit__(None, None, None)


def test_advisory_lock_windows_backend_is_exercised(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    calls: list[int] = []
    fake_msvcrt = SimpleNamespace(
        LK_NBLCK=1,
        LK_UNLCK=2,
        locking=lambda _fd, operation, _size: calls.append(operation),
    )
    monkeypatch.setitem(sys.modules, "msvcrt", fake_msvcrt)
    monkeypatch.setattr(ensure_module.os, "name", "nt")
    lock = AdvisoryFileLock(tmp_path / "windows.lock")

    lock._acquire()
    lock._release()

    assert calls == [fake_msvcrt.LK_NBLCK, fake_msvcrt.LK_UNLCK]


async def test_probe_backend_handles_transport_and_foreign_responses(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    request = httpx.Request("GET", "http://127.0.0.1:8000/godot-ai/status")
    install_probe_response(
        monkeypatch,
        error=httpx.ConnectError("refused", request=request),
    )
    assert await probe_backend(8000) is None

    install_probe_response(monkeypatch, response=httpx.Response(503))
    with pytest.raises(AttachStartupError) as non_200:
        await probe_backend(8000)
    assert non_200.value.code == "PORT_OCCUPIED"

    install_probe_response(monkeypatch, response=httpx.Response(200, content=b"not-json"))
    with pytest.raises(AttachStartupError) as invalid_json:
        await probe_backend(8000)
    assert invalid_json.value.code == "PORT_OCCUPIED"

    install_probe_response(monkeypatch, response=httpx.Response(200, json={"name": "other"}))
    with pytest.raises(AttachStartupError) as foreign:
        await probe_backend(8000)
    assert foreign.value.code == "PORT_OCCUPIED"


async def test_probe_backend_accepts_valid_status_and_rejects_malformed_brand(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    install_probe_response(monkeypatch, response=httpx.Response(200, json=status_payload()))
    assert (await probe_backend(8000)).instance_id == "instance-a"  # type: ignore[union-attr]

    install_probe_response(
        monkeypatch,
        response=httpx.Response(200, json=status_payload(instance_id=42)),
    )
    with pytest.raises(AttachStartupError) as malformed:
        await probe_backend(8000)
    assert malformed.value.code == "NEW_CLIENT_SESSION_REQUIRED"


def test_port_available_reports_free_and_bound_ports() -> None:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
        listener.bind(("127.0.0.1", 0))
        port = listener.getsockname()[1]
        assert port_available(port) is False
    assert port_available(port) is True


def test_spawn_backend_builds_detached_command_and_log(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    captured: dict[str, object] = {}

    def fake_popen(args, **kwargs):
        captured["args"] = args
        captured["kwargs"] = kwargs
        return FakeProcess()

    monkeypatch.setattr(ensure_module, "user_runtime_dir", lambda: tmp_path)
    monkeypatch.setattr(ensure_module.subprocess, "Popen", fake_popen)

    spawned = spawn_backend(8123, 9567, ("audio", "theme"))

    assert captured["args"][-2:] == ["--exclude-domains", "audio,theme"]  # type: ignore[index]
    kwargs = captured["kwargs"]
    assert kwargs["stdin"] is ensure_module.subprocess.DEVNULL  # type: ignore[index]
    assert kwargs["env"][ATTACH_SPAWNED_ENV] == "1"  # type: ignore[index]
    assert spawned.log_path == tmp_path / "backend-8123.log"
    assert spawned.log_path.exists()


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


async def test_foreign_websocket_occupant_never_spawns(tmp_path: Path) -> None:
    async def probe(_port: int) -> None:
        return None

    ensurer = BackendEnsurer(
        probe=probe,
        spawn=lambda *_args: pytest.fail("must not spawn"),
        port_check=lambda port: port != 9500,
        runtime_dir=tmp_path,
    )

    with pytest.raises(AttachStartupError) as exc_info:
        await ensurer.ensure()

    assert exc_info.value.code == "PORT_OCCUPIED"
    assert exc_info.value.data["port"] == 9500


async def test_spawned_backend_early_exit_reports_log(tmp_path: Path) -> None:
    async def probe(_port: int) -> None:
        return None

    log_path = tmp_path / "backend.log"
    ensurer = BackendEnsurer(
        probe=probe,
        spawn=lambda *_args: SpawnedBackend(FakeProcess(7), log_path),
        port_check=lambda _port: True,
        runtime_dir=tmp_path,
        health_timeout_seconds=1,
    )

    with pytest.raises(AttachStartupError) as exc_info:
        await ensurer.ensure()

    assert exc_info.value.code == "BACKEND_START_FAILED"
    assert exc_info.value.data == {
        "retryable": False,
        "hint": f"Inspect the backend log at {log_path}.",
        "log_path": str(log_path),
        "exit_code": 7,
    }


async def test_spawned_backend_health_timeout_reports_log(tmp_path: Path) -> None:
    async def probe(_port: int) -> None:
        return None

    log_path = tmp_path / "backend.log"
    ensurer = BackendEnsurer(
        probe=probe,
        spawn=lambda *_args: SpawnedBackend(FakeProcess(), log_path),
        port_check=lambda _port: True,
        runtime_dir=tmp_path,
        health_timeout_seconds=0,
    )

    with pytest.raises(AttachStartupError) as exc_info:
        await ensurer.ensure()

    assert exc_info.value.code == "BACKEND_START_TIMEOUT"
    assert exc_info.value.data["log_path"] == str(log_path)
    assert exc_info.value.data["retryable"] is True


@pytest.mark.parametrize(
    ("candidate", "difference"),
    [
        (
            BackendStatus(
                **{**status().__dict__, "attach_protocol_version": ATTACH_PROTOCOL_VERSION + 1}
            ),
            "attach_protocol_version",
        ),
        (BackendStatus(**{**status().__dict__, "ws_port": 9999}), "ws_port"),
        (
            BackendStatus(**{**status().__dict__, "exclude_domains": ("audio",)}),
            "exclude_domains",
        ),
    ],
)
async def test_backend_compatibility_checks_every_gate(
    tmp_path: Path,
    candidate: BackendStatus,
    difference: str,
) -> None:
    async def probe(_port: int) -> BackendStatus:
        return candidate

    ensurer = BackendEnsurer(probe=probe, runtime_dir=tmp_path)

    with pytest.raises(AttachStartupError) as exc_info:
        await ensurer.ensure()

    assert difference in exc_info.value.data["differences"]


def test_ensurer_urls_reflect_configured_port(tmp_path: Path) -> None:
    ensurer = BackendEnsurer(port=8123, runtime_dir=tmp_path)
    assert ensurer.base_url == "http://127.0.0.1:8123"
    assert ensurer.mcp_url == "http://127.0.0.1:8123/mcp"


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

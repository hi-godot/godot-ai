"""Unit contracts for attach backend ensure/startup coordination."""

from __future__ import annotations

import asyncio
import errno
import os
import socket
import subprocess
import sys
import threading
from pathlib import Path
from types import SimpleNamespace

import httpx
import pytest

from godot_ai import __version__, orphan_reaper
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
from godot_ai.protocol import attach as attach_protocol
from godot_ai.protocol.attach import (
    ATTACH_PROTOCOL_VERSION,
    ATTACH_SPAWNED_ENV,
    DEV_TRANSPORT_ENV,
    PLUGIN_SPAWNED_ENV,
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
    with pytest.raises(ValueError, match="attach_protocol_version"):
        BackendStatus.from_payload(status_payload(attach_protocol_version=True))
    with pytest.raises(ValueError, match="ws_port"):
        BackendStatus.from_payload(status_payload(ws_port=False))
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
        current_uid = os.getuid()
        monkeypatch.setenv("XDG_RUNTIME_DIR", str(tmp_path / "xdg"))
        assert user_runtime_dir() == (tmp_path / "xdg" / "godot-ai").resolve()
        monkeypatch.delenv("XDG_RUNTIME_DIR")
        assert user_runtime_dir() == (tmp_path / f"godot-ai-{current_uid}").resolve()


def test_user_runtime_dir_rejects_chmod_failure(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    if os.name == "nt":
        pytest.skip("chmod hardening is POSIX-only")
    monkeypatch.setenv(ensure_module.RUNTIME_DIR_ENV, str(tmp_path / "runtime"))

    def fail_chmod(_path: Path, _mode: int) -> None:
        raise OSError("unsupported")

    monkeypatch.setattr(Path, "chmod", fail_chmod)
    with pytest.raises(AttachStartupError) as exc_info:
        user_runtime_dir()
    assert exc_info.value.code == "ATTACH_RUNTIME_DIR_ERROR"
    assert exc_info.value.data["path"] == str(tmp_path / "runtime")


def test_user_runtime_dir_rejects_posix_symlink(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    if os.name == "nt":
        pytest.skip("symlink ownership hardening is POSIX-only")
    target = tmp_path / "target"
    target.mkdir()
    link = tmp_path / "runtime"
    link.symlink_to(target, target_is_directory=True)
    monkeypatch.setenv(ensure_module.RUNTIME_DIR_ENV, str(link))

    with pytest.raises(AttachStartupError) as exc_info:
        user_runtime_dir()

    assert exc_info.value.code == "ATTACH_RUNTIME_DIR_ERROR"
    assert exc_info.value.data["path"] == str(link)


def test_user_runtime_dir_enforces_posix_mode_0700(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    if os.name == "nt":
        pytest.skip("mode hardening is POSIX-only")
    runtime = tmp_path / "runtime"
    runtime.mkdir(mode=0o777)
    runtime.chmod(0o755)
    monkeypatch.setenv(ensure_module.RUNTIME_DIR_ENV, str(runtime))

    assert user_runtime_dir() == runtime.resolve()
    assert runtime.stat().st_mode & 0o777 == 0o700


def test_user_runtime_dir_rejects_wrong_posix_owner(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    if os.name == "nt":
        pytest.skip("ownership hardening is POSIX-only")
    runtime = tmp_path / "runtime"
    runtime.mkdir()
    real_info = runtime.lstat()
    monkeypatch.setenv(ensure_module.RUNTIME_DIR_ENV, str(runtime))
    monkeypatch.setattr(
        Path,
        "lstat",
        lambda _path: SimpleNamespace(st_mode=real_info.st_mode, st_uid=os.getuid() + 1),
    )

    with pytest.raises(AttachStartupError) as exc_info:
        user_runtime_dir()

    assert exc_info.value.code == "ATTACH_RUNTIME_DIR_ERROR"
    assert exc_info.value.data["errno"] == errno.EACCES


def test_user_runtime_dir_rejects_posix_non_directory(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    if os.name == "nt":
        pytest.skip("directory-type hardening is POSIX-only")
    runtime = tmp_path / "runtime"
    runtime.mkdir()
    monkeypatch.setenv(ensure_module.RUNTIME_DIR_ENV, str(runtime))
    monkeypatch.setattr(
        Path,
        "lstat",
        lambda _path: SimpleNamespace(st_mode=0o100600, st_uid=os.getuid()),
    )

    with pytest.raises(AttachStartupError) as exc_info:
        user_runtime_dir()

    assert exc_info.value.code == "ATTACH_RUNTIME_DIR_ERROR"
    assert exc_info.value.data["errno"] == errno.ENOTDIR


def test_user_runtime_dir_rejects_mode_that_cannot_be_enforced(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    if os.name == "nt":
        pytest.skip("mode hardening is POSIX-only")
    runtime = tmp_path / "runtime"
    runtime.mkdir()
    runtime.chmod(0o755)
    monkeypatch.setenv(ensure_module.RUNTIME_DIR_ENV, str(runtime))
    monkeypatch.setattr(Path, "chmod", lambda *_args, **_kwargs: None)

    with pytest.raises(AttachStartupError) as exc_info:
        user_runtime_dir()

    assert exc_info.value.code == "ATTACH_RUNTIME_DIR_ERROR"
    assert exc_info.value.data["errno"] == errno.EACCES


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


def test_lock_error_taxonomy_is_platform_specific() -> None:
    assert ensure_module._is_lock_held_error(OSError(errno.EACCES, "busy"), platform="nt")
    assert not ensure_module._is_lock_held_error(OSError(errno.EAGAIN, "busy"), platform="nt")
    assert ensure_module._is_lock_held_error(OSError(errno.EWOULDBLOCK, "busy"), platform="posix")
    assert not ensure_module._is_lock_held_error(
        OSError(errno.EACCES, "permission denied"), platform="posix"
    )


async def test_advisory_lock_wraps_open_failure(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    path = tmp_path / "attach.lock"

    def fail_open(*_args, **_kwargs):
        raise PermissionError(errno.EACCES, "denied", str(path))

    monkeypatch.setattr(Path, "open", fail_open)
    with pytest.raises(AttachStartupError) as exc_info:
        await AdvisoryFileLock(path).__aenter__()

    assert exc_info.value.code == "ATTACH_LOCK_ERROR"
    assert exc_info.value.data == {
        "retryable": False,
        "hint": (
            "Check the runtime directory permissions and filesystem lock support, then retry."
        ),
        "path": str(path),
        "errno": errno.EACCES,
        "operation": "open",
    }


def test_advisory_lock_wraps_lock_file_preparation_failure(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    class FailingHandle:
        closed = False

        def seek(self, *_args) -> None:
            raise OSError(errno.EIO, "write failed")

        def close(self) -> None:
            self.closed = True

    handle = FailingHandle()
    monkeypatch.setattr(Path, "open", lambda *_args, **_kwargs: handle)
    lock = AdvisoryFileLock(tmp_path / "prepare-error.lock")

    with pytest.raises(AttachStartupError) as exc_info:
        lock._acquire()

    assert handle.closed
    assert exc_info.value.code == "ATTACH_LOCK_ERROR"
    assert exc_info.value.data["operation"] == "prepare"
    assert exc_info.value.data["errno"] == errno.EIO


async def test_cancelled_acquire_releases_lock_if_worker_wins(tmp_path: Path) -> None:
    lock = AdvisoryFileLock(tmp_path / "cancelled.lock")
    worker_started = threading.Event()
    allow_acquire = threading.Event()
    released = threading.Event()

    def delayed_acquire() -> None:
        worker_started.set()
        assert allow_acquire.wait(timeout=5)
        lock._handle = object()

    def record_release() -> None:
        lock._handle = None
        released.set()

    lock._acquire = delayed_acquire  # type: ignore[method-assign]
    lock._release = record_release  # type: ignore[method-assign]
    acquire = asyncio.create_task(lock.__aenter__())
    assert await asyncio.to_thread(worker_started.wait, 2)

    acquire.cancel()
    with pytest.raises(asyncio.CancelledError):
        await acquire
    allow_acquire.set()

    assert await asyncio.to_thread(released.wait, 2)
    assert lock._handle is None


async def test_cancelled_acquire_ignores_worker_failure(tmp_path: Path) -> None:
    lock = AdvisoryFileLock(tmp_path / "cancelled-error.lock")
    worker_started = threading.Event()
    allow_failure = threading.Event()
    released = threading.Event()

    def delayed_failure() -> None:
        worker_started.set()
        assert allow_failure.wait(timeout=5)
        raise AttachStartupError("ATTACH_LOCK_ERROR", "failed", hint="fix permissions")

    lock._acquire = delayed_failure  # type: ignore[method-assign]
    lock._release = released.set  # type: ignore[method-assign]
    acquire = asyncio.create_task(lock.__aenter__())
    assert await asyncio.to_thread(worker_started.wait, 2)

    acquire.cancel()
    with pytest.raises(asyncio.CancelledError):
        await acquire
    allow_failure.set()
    await asyncio.sleep(0.05)

    assert not released.is_set()


async def test_advisory_lock_is_cross_process(tmp_path: Path) -> None:
    lock_path = tmp_path / "cross-process.lock"
    ready_path = tmp_path / "holder.ready"
    release_path = tmp_path / "holder.release"
    script = """
import asyncio
import sys
from pathlib import Path
from godot_ai.attach.ensure import AdvisoryFileLock

async def main():
    async with AdvisoryFileLock(Path(sys.argv[1]), timeout_seconds=5):
        Path(sys.argv[2]).write_text("ready", encoding="utf-8")
        while not Path(sys.argv[3]).exists():
            await asyncio.sleep(0.01)

asyncio.run(main())
"""
    holder = subprocess.Popen(
        [sys.executable, "-c", script, str(lock_path), str(ready_path), str(release_path)],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    try:
        deadline = asyncio.get_running_loop().time() + 5
        while not ready_path.exists() and asyncio.get_running_loop().time() < deadline:
            if holder.poll() is not None:
                break
            await asyncio.sleep(0.02)
        if not ready_path.exists():
            holder.terminate()
            _stdout, stderr = await asyncio.to_thread(holder.communicate, timeout=5)
            pytest.fail(f"lock holder did not become ready: {stderr.decode(errors='replace')}")

        contender = AdvisoryFileLock(lock_path, timeout_seconds=0.1, poll_seconds=0.01)
        with pytest.raises(AttachStartupError) as exc_info:
            await contender.__aenter__()
        assert exc_info.value.code == "ATTACH_LOCK_TIMEOUT"

        release_path.write_text("release", encoding="utf-8")
        await asyncio.to_thread(holder.wait, 5)
        async with AdvisoryFileLock(lock_path, timeout_seconds=1):
            pass
    finally:
        if holder.poll() is None:
            holder.terminate()
            holder.wait(timeout=5)


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


def test_advisory_lock_permanent_platform_error_fails_immediately(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    fake_msvcrt = SimpleNamespace(
        LK_NBLCK=1,
        LK_UNLCK=2,
        locking=lambda *_args: (_ for _ in ()).throw(OSError(errno.EBADF, "bad fd")),
    )
    monkeypatch.setitem(sys.modules, "msvcrt", fake_msvcrt)
    monkeypatch.setattr(ensure_module.os, "name", "nt")
    lock = AdvisoryFileLock(tmp_path / "permanent-error.lock", timeout_seconds=10)

    started = ensure_module.time.monotonic()
    with pytest.raises(AttachStartupError) as exc_info:
        lock._acquire()

    assert ensure_module.time.monotonic() - started < 1
    assert exc_info.value.code == "ATTACH_LOCK_ERROR"
    assert exc_info.value.data["errno"] == errno.EBADF
    assert exc_info.value.data["operation"] == "acquire"


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
    (tmp_path / "backend-8123.log").write_text("latest generation", encoding="utf-8")
    (tmp_path / "backend-8123.log.old").write_text("stale generation", encoding="utf-8")

    spawned = spawn_backend(8123, 9567, ("audio", "theme"))

    assert captured["args"][-2:] == ["--exclude-domains", "audio,theme"]  # type: ignore[index]
    kwargs = captured["kwargs"]
    assert kwargs["stdin"] is ensure_module.subprocess.DEVNULL  # type: ignore[index]
    assert kwargs["env"][ATTACH_SPAWNED_ENV] == "1"  # type: ignore[index]
    assert spawned.log_path == tmp_path / "backend-8123.log"
    assert spawned.log_path.exists()
    assert spawned.log_path.read_bytes() == b""
    assert (tmp_path / "backend-8123.log.old").read_text(encoding="utf-8") == ("latest generation")


def test_spawn_backend_reports_log_rotation_failure(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    log_path = tmp_path / "backend-8123.log"
    monkeypatch.setattr(ensure_module, "user_runtime_dir", lambda: tmp_path)
    monkeypatch.setattr(
        Path,
        "open",
        lambda *_args, **_kwargs: (_ for _ in ()).throw(
            PermissionError(errno.EACCES, "denied", str(log_path))
        ),
    )

    with pytest.raises(AttachStartupError) as exc_info:
        spawn_backend(8123, 9567, ())

    assert exc_info.value.code == "BACKEND_START_FAILED"
    assert exc_info.value.data["log_path"] == str(log_path)
    assert exc_info.value.data["errno"] == errno.EACCES
    assert "orphaned Godot AI backend" in exc_info.value.hint
    assert "runtime directory is writable" in exc_info.value.hint


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


def test_ensurer_derives_lock_timeout_from_its_health_budget(tmp_path: Path) -> None:
    derived = BackendEnsurer(
        runtime_dir=tmp_path,
        health_timeout_seconds=47,
        lock_timeout_margin_seconds=8,
    )
    overridden = BackendEnsurer(
        runtime_dir=tmp_path,
        health_timeout_seconds=47,
        lock_timeout_seconds=3,
    )

    assert derived._lock_timeout_seconds == 55
    assert overridden._lock_timeout_seconds == 3


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
    monkeypatch.setenv(PLUGIN_SPAWNED_ENV, "1")
    monkeypatch.setenv("GODOT_AI_OWNER_PID", "123")
    monkeypatch.setenv("GODOT_AI_WS_TOKEN", "secret")
    monkeypatch.setenv(DEV_TRANSPORT_ENV, "streamable-http")
    monkeypatch.setenv("GODOT_AI_UNRELATED", "preserved")

    env = _backend_spawn_env()

    assert env[ATTACH_SPAWNED_ENV] == "1"
    assert env["GODOT_AI_UNRELATED"] == "preserved"
    assert PLUGIN_SPAWNED_ENV not in env
    assert "GODOT_AI_OWNER_PID" not in env
    assert "GODOT_AI_WS_TOKEN" not in env
    assert DEV_TRANSPORT_ENV not in env


def test_spawn_marker_constants_have_one_shared_definition() -> None:
    assert ensure_module.ATTACH_SPAWNED_ENV == attach_protocol.ATTACH_SPAWNED_ENV
    assert ensure_module.PLUGIN_SPAWNED_ENV == attach_protocol.PLUGIN_SPAWNED_ENV
    assert orphan_reaper.ATTACH_SPAWNED_ENV == attach_protocol.ATTACH_SPAWNED_ENV
    assert orphan_reaper.PLUGIN_SPAWNED_ENV == attach_protocol.PLUGIN_SPAWNED_ENV


def test_orphan_reaper_import_does_not_require_fastmcp() -> None:
    script = """
import builtins
real_import = builtins.__import__

def guarded_import(name, *args, **kwargs):
    if name == "fastmcp" or name.startswith("fastmcp."):
        raise AssertionError(f"unexpected FastMCP import: {name}")
    return real_import(name, *args, **kwargs)

builtins.__import__ = guarded_import
import godot_ai.orphan_reaper
"""
    completed = subprocess.run(
        [sys.executable, "-c", script],
        capture_output=True,
        text=True,
        check=False,
    )
    assert completed.returncode == 0, completed.stderr

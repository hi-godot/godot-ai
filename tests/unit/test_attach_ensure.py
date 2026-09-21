"""Unit contracts for attach backend ensure/startup coordination."""

from __future__ import annotations

import asyncio
import errno
import json
import os
import socket
import subprocess
import sys
import threading
import time
from dataclasses import replace
from pathlib import Path
from types import SimpleNamespace

import httpx
import pytest

from godot_ai import __version__, orphan_reaper
from godot_ai.attach import ensure as ensure_module
from godot_ai.attach.ensure import (
    MAX_STATUS_RESPONSE_BYTES,
    AdvisoryFileLock,
    AttachStartupError,
    BackendEnsurer,
    BackendStatus,
    SpawnedBackend,
    _backend_spawn_env,
    compatible_server_version,
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
from godot_ai.transport.capability import CapabilityRecord
from tests.conftest import TEST_TRANSPORT_CAPABILITIES

_HTTPX_ASYNC_CLIENT = httpx.AsyncClient
TEST_CAPABILITY_RECORD = CapabilityRecord(
    TEST_TRANSPORT_CAPABILITIES.http,
    TEST_TRANSPORT_CAPABILITIES.websocket,
    attach_protocol.SERVER_INSTANCE_ID,
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
        "instance_id": TEST_CAPABILITY_RECORD.instance_nonce,
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
    class StaticStream(httpx.AsyncByteStream):
        async def __aiter__(self):
            assert response is not None
            yield response.content

    def handler(request: httpx.Request) -> httpx.Response:
        assert request.headers["authorization"] == (f"Bearer {TEST_TRANSPORT_CAPABILITIES.http}")
        if error is not None:
            raise error
        assert response is not None
        return httpx.Response(
            response.status_code,
            headers=response.headers,
            stream=StaticStream(),
        )

    def client_factory(**kwargs):
        assert kwargs.pop("trust_env") is False
        return _HTTPX_ASYNC_CLIENT(transport=httpx.MockTransport(handler), **kwargs)

    monkeypatch.setattr(
        ensure_module,
        "read_capabilities",
        lambda _port: TEST_CAPABILITY_RECORD,
    )
    monkeypatch.setattr(ensure_module.httpx, "AsyncClient", client_factory)


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


def test_advisory_lock_wraps_seek_failure(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    class FailingHandle:
        closed = False

        def seek(self, *_args) -> None:
            raise OSError(errno.EIO, "seek failed")

        def close(self) -> None:
            self.closed = True

    handle = FailingHandle()
    monkeypatch.setattr(Path, "open", lambda *_args, **_kwargs: handle)
    lock = AdvisoryFileLock(tmp_path / "seek-error.lock")

    with pytest.raises(AttachStartupError) as exc_info:
        lock._acquire()

    assert handle.closed
    assert exc_info.value.code == "ATTACH_LOCK_ERROR"
    assert exc_info.value.data["operation"] == "acquire"
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


@pytest.mark.parametrize("empty_file", [False, True])
async def test_advisory_lock_is_cross_process(tmp_path: Path, empty_file: bool) -> None:
    lock_path = tmp_path / "cross-process.lock"
    ready_path = tmp_path / "holder.ready"
    release_path = tmp_path / "holder.release"
    script = """
import asyncio
import os
import sys
from pathlib import Path
from godot_ai.attach.ensure import AdvisoryFileLock

async def main():
    if sys.argv[4] == "empty":
        # Exercise the native lock independently of AdvisoryFileLock, before
        # any writer has initialized the file (the first-opener race).
        with open(sys.argv[1], "a+b") as handle:
            if os.name == "nt":
                import msvcrt
                msvcrt.locking(handle.fileno(), msvcrt.LK_NBLCK, 1)
            else:
                import fcntl
                fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
            Path(sys.argv[2]).write_text("ready", encoding="utf-8")
            while not Path(sys.argv[3]).exists():
                await asyncio.sleep(0.01)
        return
    async with AdvisoryFileLock(Path(sys.argv[1]), timeout_seconds=5):
        Path(sys.argv[2]).write_text("ready", encoding="utf-8")
        while not Path(sys.argv[3]).exists():
            await asyncio.sleep(0.01)

asyncio.run(main())
"""
    holder = subprocess.Popen(
        [
            sys.executable, "-c", script, str(lock_path), str(ready_path),
            str(release_path), "empty" if empty_file else "normal",
        ],
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

        if empty_file and os.name == "nt":
            # Prove that the old pre-lock initialization write is rejected by
            # Windows, while the contender below must report ordinary contention.
            assert lock_path.stat().st_size == 0
            with lock_path.open("a+b", buffering=0) as handle:
                with pytest.raises(PermissionError):
                    handle.write(b"\0")

        contender = AdvisoryFileLock(lock_path, timeout_seconds=0.1, poll_seconds=0.01)
        with pytest.raises(AttachStartupError) as exc_info:
            await contender.__aenter__()
        assert exc_info.value.code == "ATTACH_LOCK_TIMEOUT", exc_info.value

        release_path.write_text("release", encoding="utf-8")
        assert await asyncio.to_thread(holder.wait, 5) == 0
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
    assert (await probe_backend(8000)).instance_id == (  # type: ignore[union-attr]
        TEST_CAPABILITY_RECORD.instance_nonce
    )

    install_probe_response(
        monkeypatch,
        response=httpx.Response(200, json=status_payload(instance_id=42)),
    )
    with pytest.raises(AttachStartupError) as malformed:
        await probe_backend(8000)
    assert malformed.value.code == "NEW_CLIENT_SESSION_REQUIRED"


async def test_probe_retries_once_only_when_the_atomic_record_rotates(monkeypatch) -> None:
    first = TEST_CAPABILITY_RECORD
    second = replace(
        first,
        http="s" * 32,
        websocket="c" * 64,
        instance_nonce="d" * 32,
    )
    records = iter((first, second, second))
    capabilities_seen: list[str] = []

    async def request(_client, _url, capability):
        capabilities_seen.append(capability)
        if len(capabilities_seen) == 1:
            return httpx.Response(401), b""
        return httpx.Response(200), json.dumps(
            status_payload(instance_id=second.instance_nonce)
        ).encode()

    monkeypatch.setattr(ensure_module, "read_capabilities", lambda _port: next(records))
    monkeypatch.setattr(ensure_module, "_bounded_status_request", request)

    result = await probe_backend(8000)

    assert result is not None
    assert result.instance_id == second.instance_nonce
    assert capabilities_seen == [first.http, second.http]


async def test_probe_does_not_retry_an_unchanged_record(monkeypatch) -> None:
    calls = 0

    async def request(_client, _url, _capability):
        nonlocal calls
        calls += 1
        return httpx.Response(401), b""

    monkeypatch.setattr(
        ensure_module,
        "read_capabilities",
        lambda _port: TEST_CAPABILITY_RECORD,
    )
    monkeypatch.setattr(ensure_module, "_bounded_status_request", request)

    with pytest.raises(AttachStartupError, match="HTTP 401"):
        await probe_backend(8000)
    assert calls == 1


@pytest.mark.parametrize(
    "body",
    [
        b"x" * (MAX_STATUS_RESPONSE_BYTES + 1),
        (
            b'{"name":"godot-ai","instance_id":"'
            + TEST_CAPABILITY_RECORD.instance_nonce.encode()
            + b'","instance_id":"'
            + TEST_CAPABILITY_RECORD.instance_nonce.encode()
            + b'"}'
        ),
    ],
    ids=("oversized", "duplicate-key"),
)
async def test_probe_rejects_oversized_or_ambiguous_status(
    monkeypatch,
    body: bytes,
) -> None:
    install_probe_response(monkeypatch, response=httpx.Response(200, content=body))
    with pytest.raises(AttachStartupError) as exc_info:
        await probe_backend(8000)
    assert exc_info.value.code == "PORT_OCCUPIED"


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

    spawned = spawn_backend(
        8123,
        9567,
        ("audio", "theme"),
        TEST_TRANSPORT_CAPABILITIES,
    )

    assert captured["args"][-2:] == ["--exclude-domains", "audio,theme"]  # type: ignore[index]
    kwargs = captured["kwargs"]
    assert kwargs["stdin"] is ensure_module.subprocess.DEVNULL  # type: ignore[index]
    assert kwargs["env"][ATTACH_SPAWNED_ENV] == "1"  # type: ignore[index]
    assert spawned.log_path == tmp_path / "backend-8123.log"
    assert spawned.log_path.exists()
    assert spawned.log_path.read_bytes() == b""
    assert (tmp_path / "backend-8123.log.old").read_text(encoding="utf-8") == ("latest generation")


def test_backend_python_uses_sibling_pythonw_on_windows(tmp_path: Path) -> None:
    python = tmp_path / "Scripts" / "python.exe"
    pythonw = python.with_name("pythonw.exe")
    pythonw.parent.mkdir()
    python.write_bytes(b"")
    pythonw.write_bytes(b"")

    assert ensure_module.backend_python_executable(python, platform="nt") == str(pythonw)


def test_backend_python_falls_back_when_pythonw_is_missing(tmp_path: Path) -> None:
    python = tmp_path / "Scripts" / "python.exe"
    python.parent.mkdir()
    python.write_bytes(b"")

    assert ensure_module.backend_python_executable(python, platform="nt") == str(python)
    assert ensure_module.backend_python_executable(python, platform="posix") == str(python)


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
        spawn_backend(8123, 9567, (), TEST_TRANSPORT_CAPABILITIES)

    assert exc_info.value.code == "BACKEND_START_FAILED"
    assert exc_info.value.data["log_path"] == str(log_path)
    assert exc_info.value.data["errno"] == errno.EACCES
    assert "orphaned Godot AI backend" in exc_info.value.hint
    assert "runtime directory is writable" in exc_info.value.hint


async def test_compatible_backend_is_adopted_without_spawn(tmp_path: Path) -> None:
    spawns: list[bool] = []

    async def probe(_port: int, *_args) -> BackendStatus:
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

    async def probe(_port: int, *_args) -> BackendStatus | None:
        if not state["spawned"]:
            return None
        if not state["healthy"]:
            await asyncio.sleep(0.02)
            state["healthy"] = True
            return None
        return status()

    def spawn(
        _port: int,
        _ws_port: int,
        _domains: tuple[str, ...],
        _capabilities,
    ) -> SpawnedBackend:
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


@pytest.mark.parametrize(
    ("running", "required", "compatible"),
    [
        ("4.0.3", "4.0.2", True),
        ("4.0.2", "4.0.3", True),
        ("4.1.0", "4.0.3", True),
        ("4.0.3", "4.1.0", True),
        ("4.2.0+local.1", "4.0.3", True),
        ("4.0.3", "4.0.3", True),
        ("5.0.0", "4.0.3", False),
        ("3.2.5", "4.0.3", False),
        ("0.0.0", "4.0.3", False),
        ("older-client-pin", "4.0.3", False),
        ("4.0.3+", "4.0.3", False),
        ("4.0.3.", "4.0.3", False),
        ("4.0.3-", "4.0.3", False),
        ("4.0.3.post1", "4.0.3", True),
        ("4.0", "4.0.3", False),
        ("4.0.3", "0+unknown", False),
        ("weird", "weird", True),
    ],
)
def test_bridge_tolerates_a_backend_of_the_same_major_version(
    running: str, required: str, compatible: bool
) -> None:
    """A bridge is a proxy; the backend owns the catalog. Same major is the
    contract, exact equality the fallback for anything that does not parse."""
    assert compatible_server_version(running, required) is compatible


async def test_patch_and_minor_skew_adopt_without_spawn(tmp_path: Path) -> None:
    """The updated server on the port keeps serving the client's old bridge."""
    spawns: list[bool] = []

    async def probe(_port: int, *_args) -> BackendStatus:
        return status(version="4.1.0")

    ensurer = BackendEnsurer(
        probe=probe,
        spawn=lambda *_args: spawns.append(True),  # type: ignore[arg-type,return-value]
        runtime_dir=tmp_path,
        required_version="4.0.3",
    )

    adopted = await ensurer.ensure()

    assert adopted.server_version == "4.1.0"
    assert spawns == []


async def test_version_skew_is_terminal_without_spawn_or_kill(tmp_path: Path) -> None:
    spawns: list[bool] = []

    async def probe(_port: int, *_args) -> BackendStatus:
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

    async def probe(_port: int, *_args) -> BackendStatus | None:
        return status() if state["spawned"] else None

    def spawn(
        _port: int,
        _ws_port: int,
        _domains: tuple[str, ...],
        _capabilities,
    ) -> SpawnedBackend:
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
    assert len(compatible) == 2, results
    assert len(incompatible) == 1
    assert incompatible[0].code == "NEW_CLIENT_SESSION_REQUIRED"
    assert "cannot be repaired" in incompatible[0].hint


async def test_foreign_http_occupant_never_spawns(tmp_path: Path) -> None:
    spawns: list[bool] = []

    async def probe(_port: int, *_args) -> None:
        return None

    ensurer = BackendEnsurer(
        probe=probe,
        spawn=lambda *_args: spawns.append(True),  # type: ignore[arg-type,return-value]
        port_check=lambda port: port != 8000,
        runtime_dir=tmp_path,
        health_timeout_seconds=0.05,
        poll_seconds=0.001,
    )

    with pytest.raises(AttachStartupError) as exc_info:
        await ensurer.ensure()

    assert exc_info.value.code == "PORT_OCCUPIED"
    assert spawns == []


async def test_slow_backend_is_adopted_after_retry(tmp_path: Path) -> None:
    calls = {"n": 0}
    spawns: list[bool] = []

    async def probe(_port: int, *_args) -> BackendStatus | None:
        calls["n"] += 1
        if calls["n"] == 1:
            return None
        return status()

    ensurer = BackendEnsurer(
        probe=probe,
        spawn=lambda *_args: spawns.append(True),  # type: ignore[arg-type,return-value]
        port_check=lambda _port: False,
        runtime_dir=tmp_path,
        health_timeout_seconds=1,
        poll_seconds=0.001,
    )

    result = await ensurer.ensure()

    assert result.instance_id == "instance-a"
    assert calls["n"] == 2
    assert spawns == []


async def test_answered_foreign_occupant_is_not_retried(tmp_path: Path) -> None:
    calls = {"n": 0}
    spawns: list[bool] = []

    async def probe(_port: int, *_args) -> BackendStatus | None:
        calls["n"] += 1
        raise ensure_module._foreign_occupant(_port, "status probe returned HTTP 503")

    ensurer = BackendEnsurer(
        probe=probe,
        spawn=lambda *_args: spawns.append(True),  # type: ignore[arg-type,return-value]
        port_check=lambda _port: False,
        runtime_dir=tmp_path,
        health_timeout_seconds=1,
        poll_seconds=0.001,
    )

    with pytest.raises(AttachStartupError) as exc_info:
        await ensurer.ensure()

    assert exc_info.value.code == "PORT_OCCUPIED"
    assert calls["n"] == 1
    assert spawns == []


async def test_bound_http_port_that_frees_falls_through_to_spawn(tmp_path: Path) -> None:
    calls = {"n": 0}
    spawns = {"n": 0}

    async def probe(_port: int, *_args) -> BackendStatus | None:
        calls["n"] += 1
        if calls["n"] < 3:
            return None
        return status()

    def port_check(port: int) -> bool:
        if port != 8000:
            return True
        return calls["n"] >= 2

    def spawn(
        _port: int,
        _ws_port: int,
        _domains: tuple[str, ...],
        _capabilities,
    ) -> SpawnedBackend:
        spawns["n"] += 1
        return SpawnedBackend(FakeProcess(), tmp_path / "backend.log")

    ensurer = BackendEnsurer(
        probe=probe,
        spawn=spawn,
        port_check=port_check,
        runtime_dir=tmp_path,
        health_timeout_seconds=1,
        poll_seconds=0.001,
    )

    result = await ensurer.ensure()

    assert result.instance_id == "instance-a"
    assert calls["n"] == 3
    assert spawns["n"] == 1


async def test_foreign_websocket_occupant_never_spawns(tmp_path: Path) -> None:
    async def probe(_port: int, *_args) -> None:
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
    async def probe(_port: int, *_args) -> None:
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
    async def probe(_port: int, *_args) -> None:
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
    async def probe(_port: int, *_args) -> BackendStatus:
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
    flags = kwargs["creationflags"]
    assert flags & getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0x00000200)
    assert flags & getattr(subprocess, "CREATE_NO_WINDOW", 0x08000000)
    assert not flags & getattr(subprocess, "DETACHED_PROCESS", 0x00000008)
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
    monkeypatch.setenv("GODOT_AI_WAIT_FOR_PORT_MS", "15000")
    monkeypatch.setenv("GODOT_AI_LAUNCH_ID", "launch-3")
    monkeypatch.setenv("GODOT_AI_WS_TOKEN", "secret")
    monkeypatch.setenv(DEV_TRANSPORT_ENV, "streamable-http")
    monkeypatch.setenv("GODOT_AI_UNRELATED", "preserved")

    env = _backend_spawn_env(TEST_TRANSPORT_CAPABILITIES)

    assert env[ATTACH_SPAWNED_ENV] == "1"
    assert env["GODOT_AI_UNRELATED"] == "preserved"
    assert PLUGIN_SPAWNED_ENV not in env
    assert "GODOT_AI_OWNER_PID" not in env
    assert "GODOT_AI_WAIT_FOR_PORT_MS" not in env
    assert "GODOT_AI_LAUNCH_ID" not in env
    assert env["GODOT_AI_HTTP_CAPABILITY"] == TEST_TRANSPORT_CAPABILITIES.http
    assert env["GODOT_AI_WS_TOKEN"] == TEST_TRANSPORT_CAPABILITIES.websocket
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


async def test_unanswered_listener_names_an_inaccessible_capability_directory(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """#988: a bound port whose record this account cannot read is not a foreign process."""
    monkeypatch.setattr(
        ensure_module, "directory_access_error", lambda: "check directory permissions"
    )

    async def probe(_port: int, *_args) -> BackendStatus | None:
        return None

    ensurer = BackendEnsurer(
        probe=probe,
        spawn=lambda *_args: pytest.fail("must not spawn"),  # type: ignore[arg-type,return-value]
        port_check=lambda _port: False,
        runtime_dir=tmp_path,
        health_timeout_seconds=0.01,
        poll_seconds=0.001,
    )

    with pytest.raises(AttachStartupError) as exc_info:
        await ensurer.ensure()

    assert exc_info.value.code == "CAPABILITY_DIR_INACCESSIBLE"
    assert exc_info.value.hint == "check directory permissions"
    assert exc_info.value.exit_code == 98


async def test_unanswered_listener_with_a_usable_directory_stays_port_occupied(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(ensure_module, "directory_access_error", lambda: None)

    async def probe(_port: int, *_args) -> BackendStatus | None:
        return None

    ensurer = BackendEnsurer(
        probe=probe,
        spawn=lambda *_args: pytest.fail("must not spawn"),  # type: ignore[arg-type,return-value]
        port_check=lambda _port: False,
        runtime_dir=tmp_path,
        health_timeout_seconds=0.01,
        poll_seconds=0.001,
    )

    with pytest.raises(AttachStartupError) as exc_info:
        await ensurer.ensure()

    assert exc_info.value.code == "PORT_OCCUPIED"


@pytest.mark.skipif(os.name != "nt", reason="Windows repair hint; faking os.name breaks pathlib")
def test_user_runtime_dir_windows_permission_error_carries_the_repair_hint(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    runtime = tmp_path / "godot-ai" / "runtime"
    monkeypatch.setenv(ensure_module.RUNTIME_DIR_ENV, str(runtime))

    def deny(self, *_args, **_kwargs):
        raise PermissionError(13, "denied", str(self))

    monkeypatch.setattr(Path, "mkdir", deny)

    with pytest.raises(AttachStartupError) as exc_info:
        user_runtime_dir()

    assert exc_info.value.code == "ATTACH_RUNTIME_DIR_ERROR"
    ## An override names the user's own directory: never suggest deleting it.
    assert "Remove-Item" not in exc_info.value.hint
    assert ensure_module.RUNTIME_DIR_ENV in exc_info.value.hint


@pytest.mark.skipif(os.name != "nt", reason="Windows repair hint")
def test_default_runtime_dir_permission_error_carries_directory_permission_guidance(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.delenv(ensure_module.RUNTIME_DIR_ENV, raising=False)
    monkeypatch.setenv("LOCALAPPDATA", str(tmp_path))

    def deny(self, *_args, **_kwargs):
        raise PermissionError(13, "denied", str(self))

    monkeypatch.setattr(Path, "mkdir", deny)

    with pytest.raises(AttachStartupError) as exc_info:
        user_runtime_dir()

    assert exc_info.value.code == "ATTACH_RUNTIME_DIR_ERROR"
    assert "Remove-Item" not in exc_info.value.hint
    assert "permissions" in exc_info.value.hint
    assert str(tmp_path / "godot-ai" / "runtime") in exc_info.value.hint


@pytest.mark.asyncio
async def test_lost_backend_waits_for_its_replacement_before_spawning(tmp_path: Path) -> None:
    """After serving a backend, a free port means an editor is replacing it.

    The bridge gives the replacement a grace to answer instead of spawning a
    backend of its own into the gap (the Ubuntu qualification rows of 4.0.4).
    """
    probes = {"n": 0}
    spawns = {"n": 0}
    statuses = [status(instance_id="instance-a")] + [None] * 4 + [status(instance_id="instance-b")]

    async def probe(_port: int, *_args) -> BackendStatus | None:
        index = min(probes["n"], len(statuses) - 1)
        probes["n"] += 1
        return statuses[index]

    def port_check(port: int) -> bool:
        ## Free while the old backend is gone and the replacement is not up.
        return port != 8000 or 1 <= probes["n"] <= 4

    def spawn(*_args) -> SpawnedBackend:
        spawns["n"] += 1
        return SpawnedBackend(FakeProcess(), tmp_path / "backend.log")

    ensurer = BackendEnsurer(
        probe=probe,
        spawn=spawn,
        port_check=port_check,
        runtime_dir=tmp_path,
        health_timeout_seconds=1,
        poll_seconds=0.001,
        replacement_grace_seconds=1.0,
    )

    first = await ensurer.ensure()
    second = await ensurer.ensure()

    assert first.instance_id == "instance-a"
    assert second.instance_id == "instance-b"
    assert spawns["n"] == 0


@pytest.mark.asyncio
async def test_lost_backend_is_respawned_once_the_grace_passes(tmp_path: Path) -> None:
    probes = {"n": 0}
    spawns = {"n": 0}

    async def probe(_port: int, *_args) -> BackendStatus | None:
        probes["n"] += 1
        if probes["n"] == 1:
            return status(instance_id="instance-a")
        if spawns["n"]:
            return status(instance_id="instance-spawned")
        return None

    def port_check(port: int) -> bool:
        return port != 8000 or probes["n"] >= 1

    def spawn(*_args) -> SpawnedBackend:
        spawns["n"] += 1
        return SpawnedBackend(FakeProcess(), tmp_path / "backend.log")

    ensurer = BackendEnsurer(
        probe=probe,
        spawn=spawn,
        port_check=port_check,
        runtime_dir=tmp_path,
        health_timeout_seconds=1,
        poll_seconds=0.001,
        replacement_grace_seconds=0.05,
    )

    assert (await ensurer.ensure()).instance_id == "instance-a"
    started = time.monotonic()
    second = await ensurer.ensure()

    assert second.instance_id == "instance-spawned"
    assert spawns["n"] == 1
    assert time.monotonic() - started >= 0.05


@pytest.mark.asyncio
async def test_first_ensure_never_waits_for_a_replacement(tmp_path: Path) -> None:
    spawns = {"n": 0}

    async def probe(_port: int, *_args) -> BackendStatus | None:
        return status() if spawns["n"] else None

    def spawn(*_args) -> SpawnedBackend:
        spawns["n"] += 1
        return SpawnedBackend(FakeProcess(), tmp_path / "backend.log")

    ensurer = BackendEnsurer(
        probe=probe,
        spawn=spawn,
        port_check=lambda _port: True,
        runtime_dir=tmp_path,
        health_timeout_seconds=1,
        poll_seconds=0.001,
        replacement_grace_seconds=5.0,
    )

    started = time.monotonic()
    assert (await ensurer.ensure()).instance_id == "instance-a"
    assert spawns["n"] == 1
    assert time.monotonic() - started < 1.0

"""Start-or-adopt coordination for the shared Godot AI HTTP/WS backend."""

from __future__ import annotations

import asyncio
import json
import os
import socket
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Awaitable, Callable, Protocol

import httpx

from godot_ai import __version__
from godot_ai.protocol.attach import (
    ATTACH_PROTOCOL_VERSION,
    ATTACH_SPAWNED_ENV,
    DEV_TRANSPORT_ENV,
)
from godot_ai.protocol.errors import ErrorCode

DEFAULT_HTTP_PORT = 8000
DEFAULT_WS_PORT = 9500
DEFAULT_LOCK_TIMEOUT_SECONDS = 30.0
DEFAULT_HEALTH_TIMEOUT_SECONDS = 30.0
DEFAULT_PROBE_TIMEOUT_SECONDS = 1.0
RUNTIME_DIR_ENV = "GODOT_AI_RUNTIME_DIR"


class ProcessHandle(Protocol):
    def poll(self) -> int | None: ...


@dataclass(frozen=True)
class BackendStatus:
    instance_id: str
    server_version: str
    attach_protocol_version: int
    ws_port: int
    exclude_domains: tuple[str, ...]
    owner_type: str
    tool_catalog_hash: str
    package_path: str

    @classmethod
    def from_payload(cls, payload: Any) -> BackendStatus:
        if not isinstance(payload, dict) or payload.get("name") != "godot-ai":
            raise ValueError("listener did not identify itself as godot-ai")
        required = {
            "instance_id": str,
            "server_version": str,
            "attach_protocol_version": int,
            "ws_port": int,
            "exclude_domains": list,
            "owner_type": str,
            "tool_catalog_hash": str,
        }
        for key, expected_type in required.items():
            if not isinstance(payload.get(key), expected_type):
                raise ValueError(f"godot-ai status is missing valid {key!r}")
        domains = payload["exclude_domains"]
        if not all(isinstance(item, str) for item in domains):
            raise ValueError("godot-ai status has invalid excluded domains")
        return cls(
            instance_id=payload["instance_id"],
            server_version=payload["server_version"],
            attach_protocol_version=payload["attach_protocol_version"],
            ws_port=payload["ws_port"],
            exclude_domains=tuple(sorted(domains)),
            owner_type=payload["owner_type"],
            tool_catalog_hash=payload["tool_catalog_hash"],
            package_path=str(payload.get("package_path", "")),
        )


class AttachStartupError(RuntimeError):
    """Terminal attach startup failure written to stderr, never stdout."""

    def __init__(
        self,
        code: str,
        message: str,
        *,
        hint: str,
        exit_code: int = 1,
        data: dict[str, Any] | None = None,
    ) -> None:
        super().__init__(f"[{code}] {message} Hint: {hint}")
        self.code = code
        self.message = message
        self.hint = hint
        self.exit_code = exit_code
        self.data = {"retryable": False, "hint": hint, **(data or {})}

    def stderr_text(self) -> str:
        details = json.dumps(self.data, ensure_ascii=False, sort_keys=True)
        return (
            f"godot-ai attach [{self.code}]: {self.message}\nHint: {self.hint}\nDetails: {details}"
        )


def user_runtime_dir() -> Path:
    """Return a private, per-user directory for locks and backend logs."""

    override = os.environ.get(RUNTIME_DIR_ENV, "").strip()
    if override:
        path = Path(override).expanduser()
    elif os.name == "nt":
        base = os.environ.get("LOCALAPPDATA", "").strip()
        path = (
            Path(base) / "godot-ai" / "runtime"
            if base
            else Path(tempfile.gettempdir()) / "godot-ai-runtime"
        )
    else:
        xdg_runtime = os.environ.get("XDG_RUNTIME_DIR", "").strip()
        path = (
            Path(xdg_runtime) / "godot-ai"
            if xdg_runtime
            else Path(tempfile.gettempdir()) / f"godot-ai-{os.getuid()}"
        )
    path.mkdir(parents=True, exist_ok=True)
    if os.name != "nt":
        try:
            path.chmod(0o700)
        except OSError:
            pass
    return path.resolve()


class AdvisoryFileLock:
    """Bounded cross-process advisory lock backed by one persistent file."""

    def __init__(
        self,
        path: Path,
        *,
        timeout_seconds: float = DEFAULT_LOCK_TIMEOUT_SECONDS,
        poll_seconds: float = 0.05,
    ) -> None:
        self.path = path
        self.timeout_seconds = timeout_seconds
        self.poll_seconds = poll_seconds
        self._handle: Any = None

    async def __aenter__(self) -> AdvisoryFileLock:
        await asyncio.to_thread(self._acquire)
        return self

    async def __aexit__(self, _exc_type: Any, _exc: Any, _tb: Any) -> None:
        await asyncio.to_thread(self._release)

    def _acquire(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        handle = self.path.open("a+b")
        handle.seek(0, os.SEEK_END)
        if handle.tell() == 0:
            handle.write(b"\0")
            handle.flush()
        deadline = time.monotonic() + self.timeout_seconds
        while True:
            try:
                handle.seek(0)
                if os.name == "nt":
                    import msvcrt

                    msvcrt.locking(handle.fileno(), msvcrt.LK_NBLCK, 1)
                else:
                    import fcntl

                    fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                self._handle = handle
                return
            except OSError as exc:
                if time.monotonic() >= deadline:
                    handle.close()
                    raise AttachStartupError(
                        "ATTACH_LOCK_TIMEOUT",
                        f"Timed out waiting for backend startup lock {self.path}.",
                        hint=(
                            "Close stale godot-ai attach processes or retry after "
                            "they finish starting."
                        ),
                    ) from exc
                time.sleep(self.poll_seconds)

    def _release(self) -> None:
        handle = self._handle
        self._handle = None
        if handle is None:
            return
        try:
            handle.seek(0)
            if os.name == "nt":
                import msvcrt

                msvcrt.locking(handle.fileno(), msvcrt.LK_UNLCK, 1)
            else:
                import fcntl

                fcntl.flock(handle.fileno(), fcntl.LOCK_UN)
        finally:
            handle.close()


async def probe_backend(
    port: int, *, timeout: float = DEFAULT_PROBE_TIMEOUT_SECONDS
) -> BackendStatus | None:
    """Return branded status, None for connection failure, or reject a foreign listener."""

    url = f"http://127.0.0.1:{port}/godot-ai/status"
    try:
        async with httpx.AsyncClient(timeout=timeout) as client:
            response = await client.get(url)
    except httpx.TransportError:
        return None
    if response.status_code != 200:
        raise _foreign_occupant(port, f"status probe returned HTTP {response.status_code}")
    try:
        payload = response.json()
    except ValueError as exc:
        raise _foreign_occupant(port, "status probe did not return JSON") from exc
    try:
        return BackendStatus.from_payload(payload)
    except ValueError as exc:
        if isinstance(payload, dict) and payload.get("name") == "godot-ai":
            raise _incompatible_backend(str(exc), payload=payload) from exc
        raise _foreign_occupant(port, str(exc)) from exc


def port_available(port: int) -> bool:
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        if os.name != "nt":
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            sock.bind(("127.0.0.1", port))
        except OSError:
            return False
        return True
    finally:
        sock.close()


def detached_spawn_kwargs(*, platform: str | None = None) -> dict[str, Any]:
    """Subprocess arguments that cannot contaminate the bridge's MCP stdio."""

    platform = os.name if platform is None else platform
    kwargs: dict[str, Any] = {"stdin": subprocess.DEVNULL, "close_fds": True}
    if platform == "nt":
        kwargs["creationflags"] = (
            getattr(subprocess, "DETACHED_PROCESS", 0x00000008)
            | getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0x00000200)
            | getattr(subprocess, "CREATE_NO_WINDOW", 0x08000000)
        )
    else:
        kwargs["start_new_session"] = True
    return kwargs


@dataclass(frozen=True)
class SpawnedBackend:
    process: ProcessHandle
    log_path: Path


def spawn_backend(port: int, ws_port: int, exclude_domains: tuple[str, ...]) -> SpawnedBackend:
    runtime_dir = user_runtime_dir()
    log_path = runtime_dir / f"backend-{port}.log"
    args = [
        sys.executable,
        "-m",
        "godot_ai",
        "--transport",
        "streamable-http",
        "--port",
        str(port),
        "--ws-port",
        str(ws_port),
    ]
    if exclude_domains:
        args.extend(("--exclude-domains", ",".join(exclude_domains)))
    env = _backend_spawn_env()

    with log_path.open("ab", buffering=0) as log:
        process = subprocess.Popen(
            args,
            stdout=log,
            stderr=log,
            env=env,
            **detached_spawn_kwargs(),
        )
    return SpawnedBackend(process=process, log_path=log_path)


def _backend_spawn_env() -> dict[str, str]:
    """Build a clean environment for the independent attach-owned backend."""

    env = os.environ.copy()
    env[ATTACH_SPAWNED_ENV] = "1"
    for inherited_process_key in (
        "GODOT_AI_PLUGIN_SPAWNED",
        "GODOT_AI_OWNER_PID",
        "GODOT_AI_WS_TOKEN",
        # A bridge launched from a reload worker must not make its independent
        # child look like another reload worker; that marker disables reaping.
        DEV_TRANSPORT_ENV,
    ):
        env.pop(inherited_process_key, None)
    return env


Probe = Callable[[int], Awaitable[BackendStatus | None]]
Spawn = Callable[[int, int, tuple[str, ...]], SpawnedBackend]
PortCheck = Callable[[int], bool]


class BackendEnsurer:
    """Serialize backend adoption/spawn and retain the lock until health."""

    def __init__(
        self,
        port: int = DEFAULT_HTTP_PORT,
        ws_port: int = DEFAULT_WS_PORT,
        exclude_domains: tuple[str, ...] = (),
        *,
        probe: Probe = probe_backend,
        spawn: Spawn = spawn_backend,
        port_check: PortCheck = port_available,
        runtime_dir: Path | None = None,
        health_timeout_seconds: float = DEFAULT_HEALTH_TIMEOUT_SECONDS,
        poll_seconds: float = 0.1,
        required_version: str = __version__,
    ) -> None:
        self.port = port
        self.ws_port = ws_port
        self.exclude_domains = tuple(sorted(exclude_domains))
        self._probe = probe
        self._spawn = spawn
        self._port_check = port_check
        self._runtime_dir = runtime_dir
        self._health_timeout_seconds = health_timeout_seconds
        self._poll_seconds = poll_seconds
        self._required_version = required_version

    @property
    def base_url(self) -> str:
        return f"http://127.0.0.1:{self.port}"

    @property
    def mcp_url(self) -> str:
        return f"{self.base_url}/mcp"

    async def ensure(self) -> BackendStatus:
        runtime_dir = self._runtime_dir or user_runtime_dir()
        lock = AdvisoryFileLock(runtime_dir / f"attach-http-{self.port}.lock")
        async with lock:
            status = await self._probe(self.port)
            if status is not None:
                return self._validate(status)
            if not self._port_check(self.port):
                raise _foreign_occupant(
                    self.port, "listener did not answer the godot-ai status probe"
                )
            if not self._port_check(self.ws_port):
                raise _foreign_occupant(self.ws_port, "WebSocket port is already occupied")

            spawned = self._spawn(self.port, self.ws_port, self.exclude_domains)
            deadline = time.monotonic() + self._health_timeout_seconds
            while time.monotonic() < deadline:
                status = await self._probe(self.port)
                if status is not None:
                    return self._validate(status)
                exit_code = spawned.process.poll()
                if exit_code is not None:
                    raise AttachStartupError(
                        "BACKEND_START_FAILED",
                        f"Backend exited with code {exit_code} before becoming healthy.",
                        hint=f"Inspect the backend log at {spawned.log_path}.",
                        data={"log_path": str(spawned.log_path), "exit_code": exit_code},
                    )
                await asyncio.sleep(self._poll_seconds)
            raise AttachStartupError(
                "BACKEND_START_TIMEOUT",
                "Backend did not become healthy before the startup deadline.",
                hint=(
                    f"Inspect {spawned.log_path}. The bridge did not kill the child; "
                    "its boot-grace reaper will clean it up if it remains idle."
                ),
                data={"log_path": str(spawned.log_path)},
            )

    def _validate(self, status: BackendStatus) -> BackendStatus:
        differences: dict[str, Any] = {}
        if status.server_version != self._required_version:
            differences["server_version"] = {
                "running": status.server_version,
                "required": self._required_version,
            }
        if status.attach_protocol_version != ATTACH_PROTOCOL_VERSION:
            differences["attach_protocol_version"] = {
                "running": status.attach_protocol_version,
                "required": ATTACH_PROTOCOL_VERSION,
            }
        if status.ws_port != self.ws_port:
            differences["ws_port"] = {"running": status.ws_port, "required": self.ws_port}
        if status.exclude_domains != self.exclude_domains:
            differences["exclude_domains"] = {
                "running": list(status.exclude_domains),
                "required": list(self.exclude_domains),
            }
        if differences:
            raise _incompatible_backend(
                "running backend is incompatible with this attach bridge",
                payload={
                    "instance_id": status.instance_id,
                    "owner_type": status.owner_type,
                    "package_path": status.package_path,
                    "differences": differences,
                },
            )
        return status


def _foreign_occupant(port: int, detail: str) -> AttachStartupError:
    return AttachStartupError(
        "PORT_OCCUPIED",
        f"Port {port} is occupied by a process the bridge cannot adopt: {detail}.",
        hint=(
            "Stop that process or configure Godot AI and the MCP client to use free matching ports."
        ),
        exit_code=98,
        data={"port": port},
    )


def _incompatible_backend(detail: str, *, payload: dict[str, Any]) -> AttachStartupError:
    return AttachStartupError(
        ErrorCode.NEW_CLIENT_SESSION_REQUIRED.value,
        f"A different Godot AI backend is already running: {detail}.",
        hint=(
            "This running MCP client session cannot be repaired. Reconfigure every Godot AI "
            "MCP client to the same package version and ports, then start a new MCP client "
            "session. The bridge will not replace the running backend."
        ),
        data=payload,
    )

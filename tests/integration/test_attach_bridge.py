"""End-to-end contracts for the client-owned stdio attach bridge."""

from __future__ import annotations

import asyncio
import contextlib
import os
import re
import signal
import socket
import subprocess
import sys
import time
from pathlib import Path

import httpx
import pytest
from fastmcp import Client
from fastmcp.client.transports import StdioTransport

from godot_ai import __version__
from godot_ai.attach.ensure import BackendStatus, probe_backend
from godot_ai.attach.lease import LeaseClient
from godot_ai.attach.proxy import create_attach_proxy
from godot_ai.orphan_reaper import (
    BOOT_GRACE_ENV,
    IDLE_GRACE_ENV,
    NO_IDLE_EXIT_ENV,
    POLL_SECONDS_ENV,
)
from godot_ai.protocol.attach import (
    ATTACH_PROTOCOL_VERSION,
    ATTACH_SPAWNED_ENV,
    DEV_TRANSPORT_ENV,
    PLUGIN_SPAWNED_ENV,
)
from tests.conftest import allocate_free_ports


def _port_open(port: int) -> bool:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
        probe.settimeout(0.2)
        return probe.connect_ex(("127.0.0.1", port)) == 0


async def _wait_port_closed(port: int, timeout: float = 20.0) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if not _port_open(port):
            return True
        await asyncio.sleep(0.1)
    return not _port_open(port)


async def _wait_backend_pid(log_path: Path, timeout: float = 10.0) -> int:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if log_path.exists():
            match = re.search(
                r"Started server process \[(\d+)\]",
                log_path.read_text(encoding="utf-8", errors="replace"),
            )
            if match:
                return int(match.group(1))
        await asyncio.sleep(0.05)
    raise AssertionError(f"backend PID did not appear in {log_path}")


async def _wait_port_open(port: int, timeout: float = 15.0) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if _port_open(port):
            return
        await asyncio.sleep(0.05)
    raise AssertionError(f"port {port} did not open within {timeout}s")


def _external_status(instance_id: str = "integration-backend") -> BackendStatus:
    return BackendStatus(
        instance_id=instance_id,
        server_version=__version__,
        attach_protocol_version=ATTACH_PROTOCOL_VERSION,
        ws_port=9500,
        exclude_domains=(),
        owner_type="external",
        tool_catalog_hash="0" * 64,
        package_path="test",
    )


def _bridge_transport(
    http_port: int,
    ws_port: int,
    runtime_dir: Path,
    stderr_log: Path,
) -> StdioTransport:
    repo_root = Path(__file__).resolve().parents[2]
    env = dict(os.environ)
    for inherited_reaper_key in (
        NO_IDLE_EXIT_ENV,
        POLL_SECONDS_ENV,
        BOOT_GRACE_ENV,
        IDLE_GRACE_ENV,
        ATTACH_SPAWNED_ENV,
        PLUGIN_SPAWNED_ENV,
        DEV_TRANSPORT_ENV,
        "GODOT_AI_OWNER_PID",
    ):
        env.pop(inherited_reaper_key, None)
    existing_pythonpath = env.get("PYTHONPATH", "")
    env["PYTHONPATH"] = os.pathsep.join(
        part for part in (str(repo_root / "src"), existing_pythonpath) if part
    )
    env["GODOT_AI_RUNTIME_DIR"] = str(runtime_dir)
    env["GODOT_AI_DISABLE_TELEMETRY"] = "true"
    env[POLL_SECONDS_ENV] = "0.05"
    env[BOOT_GRACE_ENV] = "2"
    env[IDLE_GRACE_ENV] = "0.2"
    return StdioTransport(
        sys.executable,
        [
            "-m",
            "godot_ai",
            "attach",
            "--port",
            str(http_port),
            "--ws-port",
            str(ws_port),
        ],
        env=env,
        cwd=str(repo_root),
        keep_alive=False,
        log_file=stderr_log,
    )


def _terminate_test_process(process: subprocess.Popen[bytes]) -> None:
    if process.poll() is not None:
        return
    process.terminate()
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=5)


def _terminate_pid(pid: int) -> None:
    try:
        os.kill(pid, signal.SIGTERM)
    except OSError:
        return


def test_bridge_transport_sanitizes_inherited_reaper_environment(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv(NO_IDLE_EXIT_ENV, "1")
    monkeypatch.setenv(ATTACH_SPAWNED_ENV, "inherited")
    monkeypatch.setenv(PLUGIN_SPAWNED_ENV, "inherited")
    monkeypatch.setenv(DEV_TRANSPORT_ENV, "inherited")
    transport = _bridge_transport(8123, 9567, tmp_path / "runtime", tmp_path / "stderr")

    assert transport.env is not None
    assert NO_IDLE_EXIT_ENV not in transport.env
    assert ATTACH_SPAWNED_ENV not in transport.env
    assert PLUGIN_SPAWNED_ENV not in transport.env
    assert DEV_TRANSPORT_ENV not in transport.env
    assert transport.env[POLL_SECONDS_ENV] == "0.05"
    assert transport.env[BOOT_GRACE_ENV] == "2"
    assert transport.env[IDLE_GRACE_ENV] == "0.2"


async def test_cold_start_discovers_tools_and_explains_how_to_open_editor(
    tmp_path: Path,
) -> None:
    """Client-first startup succeeds without an editor and leaves stdout MCP-clean."""

    http_port, ws_port = allocate_free_ports(2)
    stderr_log = tmp_path / "attach-stderr.log"
    transport = _bridge_transport(
        http_port,
        ws_port,
        tmp_path / "runtime",
        stderr_log,
    )
    backend_log = tmp_path / "runtime" / f"backend-{http_port}.log"

    backend_pid: int | None = None
    failure: BaseException | None = None
    try:
        async with Client(transport, timeout=20, init_timeout=30) as client:
            tools = await client.list_tools()
            names = {tool.name for tool in tools}
            assert {"editor_state", "test_run", "session_manage"} <= names

            async with httpx.AsyncClient(timeout=5) as http:
                status = (await http.get(f"http://127.0.0.1:{http_port}/godot-ai/status")).json()
            assert status["name"] == "godot-ai"
            assert status["owner_type"] == "attach"
            assert status["instance_id"]
            backend_pid = await _wait_backend_pid(backend_log)

            result = await client.call_tool("editor_state", {}, raise_on_error=False)
            assert result.is_error
            error = result.structured_content["error"]
            assert error["code"] == "PLUGIN_DISCONNECTED"
            assert error["data"]["reason"] == "no_active_session"
            assert "open this project in the godot editor" in error["data"]["hint"].lower()
            assert "restarting the mcp client is not required" in error["data"]["hint"].lower()

            # A safe operation after backend loss must start a replacement,
            # re-register the instance-bound lease, and remain invisible to
            # the upstream stdio client.
            first_instance = status["instance_id"]
            os.kill(backend_pid, signal.SIGTERM)
            assert await _wait_port_closed(http_port)
            assert await _wait_port_closed(ws_port)
            backend_pid = None

            recovered_tools = await client.list_tools()
            assert {tool.name for tool in recovered_tools} == names
            async with httpx.AsyncClient(timeout=5) as http:
                recovered_status = (
                    await http.get(f"http://127.0.0.1:{http_port}/godot-ai/status")
                ).json()
            assert recovered_status["instance_id"] != first_instance
            backend_pid = await _wait_backend_pid(backend_log)

            # Give the backend reaper a poll in which to observe the active
            # bridge lease before graceful release exercises the idle grace.
            await asyncio.sleep(0.15)
    except BaseException as exc:
        failure = exc

    stderr_text = (
        stderr_log.read_text(encoding="utf-8", errors="replace")
        if stderr_log.exists()
        else "<missing>"
    )
    if failure is not None:
        if backend_log.exists():
            with contextlib.suppress(AssertionError):
                backend_pid = await _wait_backend_pid(backend_log, timeout=2)
        if backend_pid is not None:
            _terminate_pid(backend_pid)
        backend_closed = await _wait_port_closed(http_port, timeout=5)
        if not backend_closed:
            failure.add_note(
                "Cleanup could not confirm that the detached attach backend exited; "
                f"bridge stderr: {stderr_text}"
            )
    else:
        backend_closed = await _wait_port_closed(http_port)
    if not backend_closed and failure is None:
        failure = AssertionError(
            "attach-owned backend did not reap after the bridge released its lease; "
            f"bridge stderr: {stderr_text}"
        )
        if backend_pid is not None:
            _terminate_pid(backend_pid)
            await _wait_port_closed(http_port)
    if failure is not None:
        raise failure.with_traceback(failure.__traceback__)


async def test_slow_downstream_tool_has_no_bridge_read_deadline(tmp_path: Path) -> None:
    """A dispatched response may outlive HTTPX's 5s and MCP SDK's 30s defaults."""

    http_port = allocate_free_ports(1)[0]
    call_log = tmp_path / "slow-calls.log"
    backend_script = """
import asyncio
import sys
from pathlib import Path
from fastmcp import FastMCP

mcp = FastMCP("slow-backend")

@mcp.tool
async def slow_operation(delay: float = 35.0) -> dict:
    with Path(sys.argv[2]).open("a", encoding="utf-8") as calls:
        calls.write("called\\n")
    await asyncio.sleep(delay)
    return {"completed": True, "delay": delay}

mcp.run(transport="streamable-http", host="127.0.0.1", port=int(sys.argv[1]), show_banner=False)
"""
    backend_log = (tmp_path / "slow-backend.log").open("wb")
    process = subprocess.Popen(
        [sys.executable, "-c", backend_script, str(http_port), str(call_log)],
        stdin=subprocess.DEVNULL,
        stdout=backend_log,
        stderr=backend_log,
    )

    async def ensure_ready() -> BackendStatus:
        instance_id = (
            "slow-test-backend"
            if process.poll() is None and _port_open(http_port)
            else "replacement-test-backend"
        )
        return BackendStatus(
            instance_id=instance_id,
            server_version=__version__,
            attach_protocol_version=ATTACH_PROTOCOL_VERSION,
            ws_port=9500,
            exclude_domains=(),
            owner_type="external",
            tool_catalog_hash="0" * 64,
            package_path="test",
        )

    try:
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline and not _port_open(http_port):
            if process.poll() is not None:
                break
            await asyncio.sleep(0.05)
        assert _port_open(http_port), backend_log.name

        proxy = create_attach_proxy(
            f"http://127.0.0.1:{http_port}/mcp",
            ensure_ready,
            ensure_ready,
        )
        async with Client(proxy, timeout=60) as client:
            started = time.monotonic()
            result = await client.call_tool("slow_operation", {"delay": 35.0})
            elapsed = time.monotonic() - started

            interrupted = asyncio.create_task(
                client.call_tool(
                    "slow_operation",
                    {"delay": 10.0},
                    raise_on_error=False,
                )
            )
            try:
                dispatch_deadline = time.monotonic() + 5
                while time.monotonic() < dispatch_deadline:
                    calls = call_log.read_text(encoding="utf-8").splitlines()
                    if len(calls) >= 2:
                        break
                    await asyncio.sleep(0.05)
                else:
                    raise AssertionError("second slow operation was not dispatched")
            except BaseException:
                interrupted.cancel()
                with contextlib.suppress(asyncio.CancelledError):
                    await interrupted
                raise
            await asyncio.to_thread(_terminate_test_process, process)
            unknown = await interrupted

        assert result.data == {"completed": True, "delay": 35.0}
        assert elapsed >= 34.0
        assert unknown.is_error
        error = unknown.structured_content["error"]
        assert error["code"] == "TRANSPORT_OUTCOME_UNKNOWN"
        assert error["data"]["retryable"] is False
        assert call_log.read_text(encoding="utf-8").splitlines() == ["called", "called"]
    finally:
        _terminate_test_process(process)
        backend_log.close()


@pytest.mark.parametrize("failure_name", ["connect_error", "connect_timeout"])
@pytest.mark.parametrize("failure_phase", ["initialize", "tools/call"])
async def test_real_stack_connect_failure_replays_once_before_dispatch(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    failure_name: str,
    failure_phase: str,
) -> None:
    """The raw recorder survives FastMCP wrapping and never duplicates mutation."""

    http_port = allocate_free_ports(1)[0]
    call_log = tmp_path / f"{failure_name}-calls.log"
    backend_script = """
import sys
from pathlib import Path
from fastmcp import FastMCP

mcp = FastMCP("counting-backend")

@mcp.tool
def counted_mutation() -> dict:
    path = Path(sys.argv[2])
    count = len(path.read_text(encoding="utf-8").splitlines()) if path.exists() else 0
    count += 1
    with path.open("a", encoding="utf-8") as calls:
        calls.write(f"{count}\\n")
    return {"count": count}

mcp.run(transport="streamable-http", host="127.0.0.1", port=int(sys.argv[1]), show_banner=False)
"""
    backend_log = (tmp_path / f"{failure_name}-backend.log").open("wb")
    process = subprocess.Popen(
        [sys.executable, "-c", backend_script, str(http_port), str(call_log)],
        stdin=subprocess.DEVNULL,
        stdout=backend_log,
        stderr=backend_log,
    )
    original = httpx.AsyncHTTPTransport.handle_async_request
    armed = False
    refused = 0

    async def fail_first_tool_connect(self, request: httpx.Request) -> httpx.Response:
        nonlocal refused
        if armed and refused == 0 and failure_phase.encode() in request.content:
            refused += 1
            error_type = (
                httpx.ConnectError if failure_name == "connect_error" else httpx.ConnectTimeout
            )
            raise error_type("synthetic pre-dispatch failure", request=request)
        return await original(self, request)

    monkeypatch.setattr(
        httpx.AsyncHTTPTransport,
        "handle_async_request",
        fail_first_tool_connect,
    )

    async def ensure_ready() -> BackendStatus:
        return _external_status()

    try:
        await _wait_port_open(http_port)
        proxy = create_attach_proxy(
            f"http://127.0.0.1:{http_port}/mcp",
            ensure_ready,
            ensure_ready,
        )
        async with Client(proxy, timeout=20) as client:
            assert "counted_mutation" in {tool.name for tool in await client.list_tools()}
            armed = True
            result = await client.call_tool("counted_mutation", {})

        assert result.data == {"count": 1}
        assert refused == 1
        assert call_log.read_text(encoding="utf-8").splitlines() == ["1"]
    finally:
        _terminate_test_process(process)
        backend_log.close()


async def test_loopback_status_lease_and_mcp_ignore_proxy_environment(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    http_port, ws_port, bogus_proxy_port = allocate_free_ports(3)
    backend_log = (tmp_path / "loopback-backend.log").open("wb")
    env = dict(os.environ)
    env["GODOT_AI_DISABLE_TELEMETRY"] = "true"
    process = subprocess.Popen(
        [
            sys.executable,
            "-m",
            "godot_ai",
            "--transport",
            "streamable-http",
            "--port",
            str(http_port),
            "--ws-port",
            str(ws_port),
        ],
        cwd=str(Path(__file__).resolve().parents[2]),
        env=env,
        stdin=subprocess.DEVNULL,
        stdout=backend_log,
        stderr=backend_log,
    )

    for name in ("HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY"):
        monkeypatch.setenv(name, f"http://127.0.0.1:{bogus_proxy_port}")
    for name in ("NO_PROXY", "no_proxy"):
        monkeypatch.setenv(name, "")

    async def ensure_ready() -> BackendStatus:
        status = await probe_backend(http_port, timeout=5)
        assert status is not None
        return status

    try:
        await _wait_port_open(http_port)
        status = await ensure_ready()

        lease = LeaseClient(f"http://127.0.0.1:{http_port}", ensure_ready)
        await lease.start(status)
        try:
            proxy = create_attach_proxy(
                f"http://127.0.0.1:{http_port}/mcp",
                ensure_ready,
                ensure_ready,
            )
            async with Client(proxy, timeout=20) as client:
                names = {tool.name for tool in await client.list_tools()}
            assert {"editor_state", "test_run"} <= names
        finally:
            await lease.close()
    finally:
        _terminate_test_process(process)
        backend_log.close()

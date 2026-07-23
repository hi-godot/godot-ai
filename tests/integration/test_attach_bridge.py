"""End-to-end contracts for the client-owned stdio attach bridge."""

from __future__ import annotations

import asyncio
import os
import re
import signal
import socket
import subprocess
import sys
import time
from pathlib import Path

import httpx
from fastmcp import Client
from fastmcp.client.transports import StdioTransport

from godot_ai import __version__
from godot_ai.attach.ensure import BackendStatus
from godot_ai.attach.proxy import create_attach_proxy
from godot_ai.protocol.attach import ATTACH_PROTOCOL_VERSION
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


def _bridge_transport(
    http_port: int,
    ws_port: int,
    runtime_dir: Path,
    stderr_log: Path,
) -> StdioTransport:
    repo_root = Path(__file__).resolve().parents[2]
    env = dict(os.environ)
    existing_pythonpath = env.get("PYTHONPATH", "")
    env["PYTHONPATH"] = os.pathsep.join(
        part for part in (str(repo_root / "src"), existing_pythonpath) if part
    )
    env["GODOT_AI_RUNTIME_DIR"] = str(runtime_dir)
    env["GODOT_AI_DISABLE_TELEMETRY"] = "true"
    env["GODOT_AI_REAPER_POLL_SECONDS"] = "0.05"
    env["GODOT_AI_IDLE_BOOT_GRACE_SECONDS"] = "2"
    env["GODOT_AI_IDLE_GRACE_SECONDS"] = "0.2"
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
            backend_pid = await _wait_backend_pid(backend_log)
            os.kill(backend_pid, signal.SIGTERM)
            assert await _wait_port_closed(http_port)
            assert await _wait_port_closed(ws_port)

            recovered_tools = await client.list_tools()
            assert {tool.name for tool in recovered_tools} == names
            async with httpx.AsyncClient(timeout=5) as http:
                recovered_status = (
                    await http.get(f"http://127.0.0.1:{http_port}/godot-ai/status")
                ).json()
            assert recovered_status["instance_id"] != first_instance

            # Give the backend reaper a poll in which to observe the active
            # bridge lease before graceful release exercises the idle grace.
            await asyncio.sleep(0.15)
    finally:
        stderr_text = (
            stderr_log.read_text(encoding="utf-8", errors="replace")
            if stderr_log.exists()
            else "<missing>"
        )
        assert await _wait_port_closed(http_port), (
            "attach-owned backend did not reap after the bridge released its lease; "
            f"bridge stderr: {stderr_text}"
        )


async def test_slow_downstream_tool_has_no_bridge_read_deadline(tmp_path: Path) -> None:
    """A dispatched response may outlive ordinary HTTP defaults without timing out."""

    http_port = allocate_free_ports(1)[0]
    call_log = tmp_path / "slow-calls.log"
    backend_script = """
import asyncio
import sys
from pathlib import Path
from fastmcp import FastMCP

mcp = FastMCP("slow-backend")

@mcp.tool
async def slow_operation(delay: float = 1.2) -> dict:
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
        async with Client(proxy, timeout=20) as client:
            started = time.monotonic()
            result = await client.call_tool("slow_operation", {"delay": 1.2})
            elapsed = time.monotonic() - started

            interrupted = asyncio.create_task(
                client.call_tool(
                    "slow_operation",
                    {"delay": 10.0},
                    raise_on_error=False,
                )
            )
            dispatch_deadline = time.monotonic() + 5
            while time.monotonic() < dispatch_deadline:
                calls = call_log.read_text(encoding="utf-8").splitlines()
                if len(calls) >= 2:
                    break
                await asyncio.sleep(0.05)
            else:
                raise AssertionError("second slow operation was not dispatched")
            await asyncio.to_thread(_terminate_test_process, process)
            unknown = await interrupted

        assert result.data == {"completed": True, "delay": 1.2}
        assert elapsed >= 1.0
        assert unknown.is_error
        error = unknown.structured_content["error"]
        assert error["code"] == "TRANSPORT_OUTCOME_UNKNOWN"
        assert error["data"]["retryable"] is False
        assert call_log.read_text(encoding="utf-8").splitlines() == ["called", "called"]
    finally:
        _terminate_test_process(process)
        backend_log.close()

"""Shared fixtures for integration tests."""

from __future__ import annotations

## Disable telemetry by default for every pytest run, BEFORE any
## ``godot_ai`` import. Workflow-level ``env:`` blocks only catch CI
## branches that have adopted the gating; this conftest line also
## covers PRs that haven't merged the gating yet, contributors running
## the suite locally, and ad-hoc tox/uv invocations. Without it the
## ``mcp_stack`` fixture (which calls ``create_server``) fires one
## STARTUP / FIRST_STARTUP record per pytest run on a fresh data dir
## — observed as a per-CI-run trickle in BQ.
##
## ``setdefault`` preserves explicit overrides: tests that *want* the
## enabled code path (the telemetry fixtures in tests/unit/test_telemetry*.py)
## ``monkeypatch.delenv`` this var inside their fixture, and any caller
## can pass ``GODOT_AI_DISABLE_TELEMETRY=false`` (or unset it) before
## invoking pytest to bring the live path back.
import os

os.environ.setdefault("GODOT_AI_DISABLE_TELEMETRY", "true")

import asyncio
import hmac
import json
import secrets
import socket
from dataclasses import dataclass, field
from pathlib import Path

import pytest
import websockets

from godot_ai.protocol.envelope import WS_PROTOCOL_VERSION
from godot_ai.sessions.registry import SessionRegistry
from godot_ai.transport.capability import LaunchCapabilities
from godot_ai.transport.websocket import (
    GodotWebSocketServer,
    websocket_client_proof,
    websocket_server_proof,
)

TEST_WS_CAPABILITY = "0123456789abcdef" * 4
TEST_HTTP_CAPABILITY = "test-http-capability-0123456789abcdef"
TEST_TRANSPORT_CAPABILITIES = LaunchCapabilities(
    http=TEST_HTTP_CAPABILITY,
    websocket=TEST_WS_CAPABILITY,
)
TEST_HTTP_AUTH_HEADERS = {"Authorization": f"Bearer {TEST_HTTP_CAPABILITY}"}


def isolate_capability_directory(monkeypatch, root) -> Path:
    """Point capability records at test-owned storage on every platform."""

    root = Path(root)
    if os.name == "nt":
        monkeypatch.delenv("GODOT_AI_CAPABILITY_DIR", raising=False)
        monkeypatch.setenv("LOCALAPPDATA", str(root))
        return root / "godot-ai" / "capabilities"
    monkeypatch.setenv("GODOT_AI_CAPABILITY_DIR", str(root))
    return root


def create_test_server(**kwargs):
    """Build a server with the suite's explicit, instance-bound capabilities."""

    from godot_ai.server import create_server

    return create_server(capabilities=TEST_TRANSPORT_CAPABILITIES, **kwargs)


def allocate_free_ports(count: int) -> list[int]:
    """Grab ``count`` distinct free loopback ports, then release them.

    Hardcoded ports made two concurrent pytest runs (e.g. two worktrees of
    the same clone) collide: the second run's server either failed to bind
    or its mock plugin connected to the *other* run's server and died with
    "4001 session id already registered". All sockets stay open until every
    port is allocated so the OS can't hand the same port out twice (a caller
    that needs both an HTTP and a WS port must get two distinct values).
    Session claims prevent another worker from selecting a released port
    while a test deliberately stops and restarts its backend. They do not
    reserve ports against unrelated processes outside this test suite.
    """
    probes = [socket.socket(socket.AF_INET, socket.SOCK_STREAM) for _ in range(count)]
    try:
        claim_root = os.environ.get("GODOT_AI_TEST_PORT_CLAIMS")
        for index in range(count):
            for _attempt in range(1000):
                probe = probes[index]
                probe.bind(("127.0.0.1", 0))
                if claim_root is None:
                    break
                try:
                    (Path(claim_root) / str(probe.getsockname()[1])).touch(exist_ok=False)
                except FileExistsError:
                    probe.close()
                    probes[index] = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                else:
                    break
            else:
                raise RuntimeError("Could not allocate an unclaimed test port")
        return [probe.getsockname()[1] for probe in probes]
    finally:
        for probe in probes:
            probe.close()


@pytest.fixture(scope="session", autouse=True)
def _claim_test_ports(tmp_path_factory, request):
    root = tmp_path_factory.getbasetemp()
    if hasattr(request.config, "workerinput"):
        root = root.parent
    claims = root / "port-claims"
    claims.mkdir(exist_ok=True)
    previous = os.environ.get("GODOT_AI_TEST_PORT_CLAIMS")
    os.environ["GODOT_AI_TEST_PORT_CLAIMS"] = str(claims)
    try:
        yield
    finally:
        if previous is None:
            os.environ.pop("GODOT_AI_TEST_PORT_CLAIMS", None)
        else:
            os.environ["GODOT_AI_TEST_PORT_CLAIMS"] = previous


def allocate_free_port() -> int:
    """Single-port form of ``allocate_free_ports``."""
    return allocate_free_ports(1)[0]


@pytest.fixture(scope="session")
def mcp_ws_port() -> int:
    """WebSocket port for the ``mcp_stack`` server, allocated once per pytest
    session. Tests that dial the mcp_stack server directly must use this
    fixture instead of hardcoding a port."""
    return allocate_free_port()


async def drain_handshake_ack(ws) -> dict:
    """Receive and assert the server's mandatory handshake_ack.

    Drains the ack so it doesn't pollute the caller's first ``recv``. The
    ack is MANDATORY (#716): swallowing the timeout made the contract
    optional in every test but the one dedicated negative test, so a server
    that silently stopped acking would keep the whole suite green. Shared
    by every test-side handshake site (conftest fixtures, test_mcp_tools,
    test_websocket) so the timeout and assertion can't drift.
    """
    try:
        ack_raw = await asyncio.wait_for(ws.recv(), timeout=2.0)
    except asyncio.TimeoutError:
        pytest.fail("no handshake_ack within 2s — the ack contract is mandatory")
    ack = json.loads(ack_raw)
    assert set(ack) == {"type", "protocol_version", "server_version"}
    assert ack.get("type") == "handshake_ack", f"expected handshake_ack, got {ack!r}"
    assert ack.get("protocol_version") == WS_PROTOCOL_VERSION
    return ack


async def send_auth_hello(ws, *, client_nonce: str | None = None) -> str:
    """Send the metadata-free first v4 frame and return its client nonce."""

    nonce = client_nonce or secrets.token_hex(32)
    await ws.send(
        json.dumps(
            {
                "type": "auth_hello",
                "protocol_version": WS_PROTOCOL_VERSION,
                "client_nonce": nonce,
            }
        )
    )
    return nonce


async def receive_auth_challenge(ws, *, capability: str, client_nonce: str) -> dict:
    """Receive and verify the server before test code discloses metadata."""

    raw = await asyncio.wait_for(ws.recv(), timeout=2.0)
    challenge = json.loads(raw)
    assert set(challenge) == {
        "type",
        "protocol_version",
        "client_nonce",
        "server_nonce",
        "server_version",
        "server_proof",
    }
    assert challenge["type"] == "auth_challenge"
    assert challenge["protocol_version"] == WS_PROTOCOL_VERSION
    assert challenge["client_nonce"] == client_nonce
    expected = websocket_server_proof(
        capability,
        client_nonce=client_nonce,
        server_nonce=challenge["server_nonce"],
        server_version=challenge["server_version"],
    )
    assert hmac.compare_digest(challenge["server_proof"], expected)
    return challenge


def build_auth_response(
    challenge: dict,
    *,
    capability: str,
    session_id: str,
    godot_version: str = "4.7.0",
    project_path: str = "/tmp/test_project",
    plugin_version: str = "4.0.0",
    readiness: str = "ready",
    editor_pid: int = 0,
    server_launch_mode: str = "unknown",
) -> dict:
    """Build the one authenticated v4 metadata frame."""

    response = {
        "type": "auth_response",
        "protocol_version": WS_PROTOCOL_VERSION,
        "client_nonce": challenge["client_nonce"],
        "server_nonce": challenge["server_nonce"],
        "session_id": session_id,
        "godot_version": godot_version,
        "project_path": project_path,
        "plugin_version": plugin_version,
        "readiness": readiness,
        "editor_pid": editor_pid,
        "server_launch_mode": server_launch_mode,
    }
    response["client_proof"] = websocket_client_proof(
        capability,
        client_nonce=response["client_nonce"],
        server_nonce=response["server_nonce"],
        session_id=session_id,
        godot_version=godot_version,
        project_path=project_path,
        plugin_version=plugin_version,
        readiness=readiness,
        editor_pid=editor_pid,
        server_launch_mode=server_launch_mode,
        server_version=challenge["server_version"],
    )
    return response


async def perform_v4_handshake(
    ws,
    *,
    capability: str = TEST_WS_CAPABILITY,
    session_id: str = "test-session",
    godot_version: str = "4.7.0",
    project_path: str = "/tmp/test_project",
    plugin_version: str = "4.0.0",
    readiness: str = "ready",
    editor_pid: int = 0,
    server_launch_mode: str = "unknown",
) -> dict:
    """Perform and verify the complete v4 editor handshake."""

    client_nonce = await send_auth_hello(ws)
    challenge = await receive_auth_challenge(
        ws,
        capability=capability,
        client_nonce=client_nonce,
    )
    response = build_auth_response(
        challenge,
        capability=capability,
        session_id=session_id,
        godot_version=godot_version,
        project_path=project_path,
        plugin_version=plugin_version,
        readiness=readiness,
        editor_pid=editor_pid,
        server_launch_mode=server_launch_mode,
    )
    await ws.send(json.dumps(response))
    return await drain_handshake_ack(ws)


@dataclass
class MockGodotPlugin:
    """Simulates a Godot editor plugin connecting over WebSocket."""

    ws: websockets.ClientConnection
    session_id: str

    async def recv_command(self, timeout: float = 2.0) -> dict:
        raw = await asyncio.wait_for(self.ws.recv(), timeout=timeout)
        return json.loads(raw)

    async def send_response(
        self,
        request_id: str,
        data: dict,
        status: str = "ok",
        readiness: str = "ready",
        error_watermark: dict[str, int] | None = None,
    ) -> None:
        msg: dict = {"request_id": request_id, "status": status, "data": data}
        msg["readiness"] = readiness
        if error_watermark is not None:
            msg["error_watermark"] = error_watermark
        await self.ws.send(json.dumps(msg))

    async def send_error(
        self,
        request_id: str,
        code: str,
        message: str,
        data: dict | None = None,
        readiness: str = "ready",
        error_watermark: dict[str, int] | None = None,
    ) -> None:
        msg: dict = {
            "request_id": request_id,
            "status": "error",
            "data": {},
            "error": {"code": code, "message": message, "data": data or {}},
        }
        msg["readiness"] = readiness
        if error_watermark is not None:
            msg["error_watermark"] = error_watermark
        await self.ws.send(json.dumps(msg))

    async def send_event(self, event: str, data: dict) -> None:
        msg = {"type": "event", "event": event, "data": data}
        await self.ws.send(json.dumps(msg))

    async def close(self) -> None:
        await self.ws.close()


@dataclass
class ServerHarness:
    """Test harness wrapping a running WebSocket server + registry."""

    registry: SessionRegistry
    server: GodotWebSocketServer
    port: int
    capability: str = TEST_WS_CAPABILITY
    _task: asyncio.Task = field(repr=False, default=None)

    async def connect_plugin(
        self,
        session_id: str = "test-session",
        godot_version: str = "4.7.0",
        project_path: str = "/tmp/test_project",
        plugin_version: str = "4.0.0",
        readiness: str = "ready",
        editor_pid: int = 0,
        server_launch_mode: str = "unknown",
        capability: str | None = None,
    ) -> MockGodotPlugin:
        ws = await websockets.connect(f"ws://127.0.0.1:{self.port}")
        await perform_v4_handshake(
            ws,
            capability=self.capability if capability is None else capability,
            session_id=session_id,
            godot_version=godot_version,
            project_path=project_path,
            plugin_version=plugin_version,
            readiness=readiness,
            editor_pid=editor_pid,
            server_launch_mode=server_launch_mode,
        )
        return MockGodotPlugin(ws=ws, session_id=session_id)


@pytest.fixture
async def mcp_stack(mcp_ws_port, monkeypatch, tmp_path):
    """Full MCP server + mock Godot plugin connected via FastMCP Client."""
    from fastmcp import Client

    from godot_ai.server import create_server

    port = mcp_ws_port
    isolate_capability_directory(monkeypatch, tmp_path / "capabilities")
    mcp = create_server(
        ws_port=port,
        http_port=allocate_free_port(),
        capabilities=TEST_TRANSPORT_CAPABILITIES,
    )
    async with Client(mcp) as client:
        ws = await websockets.connect(f"ws://127.0.0.1:{port}")
        await perform_v4_handshake(ws, session_id="mcp-test")
        plugin = MockGodotPlugin(ws=ws, session_id="mcp-test")
        yield client, plugin
        await plugin.close()


@pytest.fixture
async def harness():
    """Spin up a GodotWebSocketServer on a free port, yield a ServerHarness, tear down."""
    registry = SessionRegistry()
    port = allocate_free_port()
    server = GodotWebSocketServer(registry, port=port, auth_token=TEST_WS_CAPABILITY)
    task = asyncio.create_task(server.start())
    await server.wait_until_ready()

    h = ServerHarness(
        registry=registry,
        server=server,
        port=port,
        capability=TEST_WS_CAPABILITY,
        _task=task,
    )
    yield h

    task.cancel()
    try:
        await task
    except (asyncio.CancelledError, OSError):
        pass

"""Shared fixtures for integration tests."""

from __future__ import annotations

import asyncio
import json
from dataclasses import dataclass, field

import pytest
import websockets

from godot_ai.sessions.registry import SessionRegistry
from godot_ai.transport.websocket import GodotWebSocketServer


@dataclass
class MockGodotPlugin:
    """Simulates a Godot editor plugin connecting over WebSocket."""

    ws: websockets.ClientConnection
    session_id: str

    async def recv_command(self, timeout: float = 2.0) -> dict:
        raw = await asyncio.wait_for(self.ws.recv(), timeout=timeout)
        return json.loads(raw)

    async def send_response(self, request_id: str, data: dict, status: str = "ok") -> None:
        msg = {"request_id": request_id, "status": status, "data": data}
        await self.ws.send(json.dumps(msg))

    async def send_error(self, request_id: str, code: str, message: str) -> None:
        msg = {
            "request_id": request_id,
            "status": "error",
            "data": {},
            "error": {"code": code, "message": message},
        }
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
    _task: asyncio.Task = field(repr=False, default=None)

    async def connect_plugin(
        self,
        session_id: str = "test-session",
        godot_version: str = "4.4.1",
        project_path: str = "/tmp/test_project",
        plugin_version: str = "0.0.1",
        readiness: str = "ready",
        editor_pid: int = 0,
        server_launch_mode: str | None = None,
    ) -> MockGodotPlugin:
        ws = await websockets.connect(f"ws://127.0.0.1:{self.port}")
        handshake = {
            "type": "handshake",
            "session_id": session_id,
            "godot_version": godot_version,
            "project_path": project_path,
            "plugin_version": plugin_version,
            "protocol_version": 1,
            "readiness": readiness,
            "editor_pid": editor_pid,
        }
        ## Older plugins don't send server_launch_mode at all; keep the field
        ## absent when caller passes None so tests can exercise both the
        ## legacy ("falls through to 'unknown'") and explicit paths.
        if server_launch_mode is not None:
            handshake["server_launch_mode"] = server_launch_mode
        await ws.send(json.dumps(handshake))
        # Give the server a moment to process the handshake
        await asyncio.sleep(0.05)
        ## Drain the server's handshake_ack so it doesn't pollute the first
        ## `recv_command()` call in tests that don't care about the ack.
        try:
            ack_raw = await asyncio.wait_for(ws.recv(), timeout=0.5)
            ack = json.loads(ack_raw)
            assert ack.get("type") == "handshake_ack", f"expected handshake_ack, got {ack!r}"
        except asyncio.TimeoutError:
            pass
        return MockGodotPlugin(ws=ws, session_id=session_id)


@pytest.fixture
async def mcp_stack():
    """Full MCP server + mock Godot plugin connected via FastMCP Client."""
    from fastmcp import Client

    from godot_ai.server import create_server

    port = 19502
    mcp = create_server(ws_port=port)
    async with Client(mcp) as client:
        ws = await websockets.connect(f"ws://127.0.0.1:{port}")
        handshake = {
            "type": "handshake",
            "session_id": "mcp-test",
            "godot_version": "4.4.1",
            "project_path": "/tmp/test_project",
            "plugin_version": "0.0.1",
            "protocol_version": 1,
        }
        await ws.send(json.dumps(handshake))
        await asyncio.sleep(0.05)
        ## Drain handshake_ack so it doesn't pollute tests' first recv.
        try:
            ack_raw = await asyncio.wait_for(ws.recv(), timeout=0.5)
            ack = json.loads(ack_raw)
            assert ack.get("type") == "handshake_ack", f"expected handshake_ack, got {ack!r}"
        except asyncio.TimeoutError:
            pass
        plugin = MockGodotPlugin(ws=ws, session_id="mcp-test")
        yield client, plugin
        await plugin.close()


@pytest.fixture
async def harness():
    """Spin up a GodotWebSocketServer on a random high port, yield a ServerHarness, tear down."""
    registry = SessionRegistry()
    # Use port 0 to let the OS pick a free port — but websockets.serve needs a fixed port.
    # Pick a high port unlikely to conflict.
    port = 19500
    server = GodotWebSocketServer(registry, port=port)
    task = asyncio.create_task(server.start())
    await asyncio.sleep(0.1)  # let server bind

    h = ServerHarness(registry=registry, server=server, port=port, _task=task)
    yield h

    task.cancel()
    try:
        await task
    except (asyncio.CancelledError, OSError):
        pass

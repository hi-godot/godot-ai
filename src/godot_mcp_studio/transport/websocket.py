"""WebSocket server for communication with the Godot editor plugin."""

from __future__ import annotations

import asyncio
import json
import logging
from typing import Any

import websockets
from websockets.asyncio.server import ServerConnection

from godot_mcp_studio.protocol.envelope import CommandRequest, CommandResponse, HandshakeMessage
from godot_mcp_studio.sessions.registry import Session, SessionRegistry

logger = logging.getLogger(__name__)

DEFAULT_PORT = 9500


class GodotWebSocketServer:
    """Accepts connections from Godot editor plugins and routes commands."""

    def __init__(self, registry: SessionRegistry, port: int = DEFAULT_PORT):
        self.registry = registry
        self.port = port
        self._pending: dict[str, asyncio.Future[CommandResponse]] = {}
        self._connections: dict[str, ServerConnection] = {}

    async def start(self):
        logger.info("Starting WebSocket server on port %d", self.port)
        async with websockets.serve(self._handle_connection, "127.0.0.1", self.port):
            await asyncio.Future()  # run forever

    async def _handle_connection(self, ws: ServerConnection):
        session_id: str | None = None
        try:
            # First message must be a handshake
            raw = await asyncio.wait_for(ws.recv(), timeout=10.0)
            data = json.loads(raw)
            handshake = HandshakeMessage.model_validate(data)

            session_id = handshake.session_id
            session = Session(
                session_id=handshake.session_id,
                godot_version=handshake.godot_version,
                project_path=handshake.project_path,
                plugin_version=handshake.plugin_version,
                protocol_version=handshake.protocol_version,
            )
            self.registry.register(session)
            self._connections[session_id] = ws
            logger.info(
                "Session connected: %s (Godot %s, %s)",
                session_id,
                handshake.godot_version,
                handshake.project_path,
            )

            # Listen for responses
            async for raw_msg in ws:
                data = json.loads(raw_msg)
                response = CommandResponse.model_validate(data)
                future = self._pending.pop(response.request_id, None)
                if future and not future.done():
                    future.set_result(response)

        except websockets.ConnectionClosed:
            logger.info("Session disconnected: %s", session_id)
        except Exception:
            logger.exception("Error in WebSocket handler for session %s", session_id)
        finally:
            if session_id:
                self.registry.unregister(session_id)
                self._connections.pop(session_id, None)

    async def send_command(
        self,
        session_id: str,
        command: str,
        params: dict[str, Any] | None = None,
        timeout: float = 5.0,
    ) -> CommandResponse:
        ws = self._connections.get(session_id)
        if ws is None:
            raise ConnectionError(f"No connection for session {session_id}")

        request = CommandRequest(command=command, params=params or {})
        future: asyncio.Future[CommandResponse] = asyncio.get_running_loop().create_future()
        self._pending[request.request_id] = future

        await ws.send(request.model_dump_json())

        try:
            return await asyncio.wait_for(future, timeout=timeout)
        except asyncio.TimeoutError:
            self._pending.pop(request.request_id, None)
            raise TimeoutError(
                f"Command {command} timed out after {timeout}s on session {session_id}"
            )

"""WebSocket server for communication with the Godot editor plugin."""

from __future__ import annotations

import asyncio
import json
import logging
from typing import Any

import websockets
from websockets.asyncio.server import ServerConnection

from godot_ai.protocol.envelope import CommandRequest, CommandResponse, HandshakeMessage
from godot_ai.sessions.registry import Session, SessionRegistry

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
        try:
            async with websockets.serve(
                self._handle_connection,
                "127.0.0.1",
                self.port,
                max_size=4 * 1024 * 1024,  # 4 MB for screenshot base64
            ):
                await asyncio.Future()  # run forever
        except OSError as e:
            if e.errno == 48:  # Address already in use
                logger.warning(
                    "WebSocket port %d already in use — another server instance may be running. "
                    "MCP tools will work but the Godot plugin won't connect to this instance.",
                    self.port,
                )
            else:
                raise

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
                readiness=handshake.readiness,
                editor_pid=handshake.editor_pid,
            )
            self.registry.register(session)
            self._connections[session_id] = ws
            logger.info(
                "Session connected: %s (pid=%s, Godot %s, %s)",
                session_id,
                handshake.editor_pid or "?",
                handshake.godot_version,
                handshake.project_path,
            )

            # Listen for responses and events
            async for raw_msg in ws:
                ## Any message counts as a heartbeat — last_seen lets callers
                ## distinguish live editors from stale registry entries.
                live = self.registry.get(session_id)
                if live is not None:
                    live.touch()

                data = json.loads(raw_msg)

                # Handle state events from the plugin
                if data.get("type") == "event":
                    self._handle_event(session_id, data)
                    continue

                # Handle command responses
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

    def _handle_event(self, session_id: str, data: dict) -> None:
        event = data.get("event", "")
        event_data = data.get("data", {})
        session = self.registry.get(session_id)
        if session is None:
            return

        if event == "scene_changed":
            session.current_scene = event_data.get("current_scene", "")
            logger.info("Session %s: scene changed to %s", session_id[:8], session.current_scene)
        elif event == "play_state_changed":
            session.play_state = event_data.get("play_state", "stopped")
            logger.info("Session %s: play state -> %s", session_id[:8], session.play_state)
        elif event == "readiness_changed":
            session.readiness = event_data.get("readiness", "ready")
            logger.info("Session %s: readiness -> %s", session_id[:8], session.readiness)

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

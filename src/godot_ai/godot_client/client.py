"""Typed async client for sending commands to the Godot editor plugin."""

from __future__ import annotations

import logging
from typing import Any

from godot_ai.protocol.errors import ErrorCode
from godot_ai.sessions.registry import SessionRegistry
from godot_ai.transport.websocket import GodotWebSocketServer

logger = logging.getLogger(__name__)


class GodotCommandError(Exception):
    """Raised when a Godot plugin command returns an error response."""

    def __init__(self, code: str, message: str):
        self.code = code
        self.message = message
        super().__init__(f"{code}: {message}")


class GodotClient:
    """High-level client for interacting with connected Godot editors."""

    def __init__(self, ws_server: GodotWebSocketServer, registry: SessionRegistry):
        self.ws_server = ws_server
        self.registry = registry

    async def send(
        self,
        command: str,
        params: dict[str, Any] | None = None,
        session_id: str | None = None,
        timeout: float = 5.0,
    ) -> dict[str, Any]:
        """Send a command to a Godot session and return the response data.

        If session_id is None, uses the active session.
        Raises GodotCommandError if the plugin returns an error.
        """
        if session_id is None:
            session = self.registry.get_active()
            if session is None:
                raise ConnectionError("No active Godot session")
            session_id = session.session_id
            if len(self.registry) > 1:
                logger.debug(
                    "Routing %s to active session %s (%d sessions connected)",
                    command,
                    session_id[:8],
                    len(self.registry),
                )

        if self.registry.get(session_id) is None:
            raise ConnectionError(
                f"Session {session_id} not found. Error code: {ErrorCode.SESSION_NOT_FOUND}"
            )

        response = await self.ws_server.send_command(
            session_id=session_id,
            command=command,
            params=params,
            timeout=timeout,
        )

        if response.status == "error":
            error = response.error
            raise GodotCommandError(
                code=error.code if error else "UNKNOWN",
                message=error.message if error else "Unknown error",
            )

        return response.data

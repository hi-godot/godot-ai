"""Typed async client for sending commands to the Godot editor plugin."""

from __future__ import annotations

import logging
from typing import Any

from fastmcp.exceptions import FastMCPError

from godot_ai.godot_client.circuit_breaker import EditorBridgeCircuitBreaker
from godot_ai.godot_client.session_diagnostics import (
    NO_ACTIVE_SESSION_MESSAGE,
    no_active_session_data,
    session_not_found_data,
    session_not_found_message,
)
from godot_ai.protocol.errors import ErrorCode
from godot_ai.sessions.registry import SessionRegistry
from godot_ai.transport.websocket import GodotWebSocketServer

logger = logging.getLogger(__name__)


class GodotCommandError(FastMCPError):
    """Raised when a Godot plugin command returns an error response."""

    def __init__(
        self,
        code: str,
        message: str,
        data: dict[str, Any] | None = None,
    ):
        self.code = code
        self.message = message
        self.data = data or {}
        if self.data:
            suffix = " [" + ", ".join(f"{k}={v}" for k, v in self.data.items()) + "]"
            super().__init__(f"{code}: {message}{suffix}")
        else:
            super().__init__(f"{code}: {message}")

    def to_payload(self) -> dict[str, Any]:
        return {"code": self.code, "message": self.message, "data": self.data}


class GodotClient:
    """High-level client for interacting with connected Godot editors."""

    def __init__(
        self,
        ws_server: GodotWebSocketServer,
        registry: SessionRegistry,
        circuit_breaker: EditorBridgeCircuitBreaker | None = None,
    ):
        self.ws_server = ws_server
        self.registry = registry
        ## F-006: stop death-spiral hot retries from melting the bridge.
        ## Defaults: 5 consecutive transport failures opens for 1s, doubles
        ## per re-open up to 30s. While open, the next call short-circuits
        ## with PLUGIN_DISCONNECTED + retry_after_ms so retrying clients
        ## get a clear back-off signal instead of another bare TimeoutError.
        self._circuit = circuit_breaker or EditorBridgeCircuitBreaker()

    @property
    def circuit_breaker(self) -> EditorBridgeCircuitBreaker:
        return self._circuit

    def _raise_if_circuit_open(self, session_id: str | None) -> None:
        retry_after_ms = self._circuit.check_open(session_id)
        if retry_after_ms is None:
            return
        snapshot = self._circuit.snapshot(session_id)
        data = {
            "retryable": True,
            "retry_after_ms": retry_after_ms,
            "circuit_open": True,
            **snapshot,
        }
        message = (
            "Editor-bridge circuit is open after repeated transport failures — "
            f"retry in {retry_after_ms}ms"
        )
        if session_id is None and snapshot.get("last_failure_kind") == "no_active_session":
            data = no_active_session_data(**data)
            message = (
                "Editor-bridge circuit is open after repeated no-session failures — "
                "this MCP server still has no connected Godot editor; "
                f"retry in {retry_after_ms}ms"
            )
        elif session_id is not None and snapshot.get("last_failure_kind") == "session_not_found":
            data = session_not_found_data(session_id, **data)
            message = (
                "Editor-bridge circuit is open after repeated missing-session failures — "
                f"session '{session_id}' is still not connected to this MCP server; "
                f"retry in {retry_after_ms}ms"
            )
        raise GodotCommandError(
            code=ErrorCode.PLUGIN_DISCONNECTED,
            message=message,
            data=data,
        )

    def _record_failure(self, session_id: str | None, kind: str) -> None:
        opened = self._circuit.record_failure(session_id, kind=kind)
        if opened:
            ## Log once on each closed→open transition so operators can
            ## grep for the death-spiral entry point. Subsequent
            ## short-circuited calls don't log to avoid amplifying the
            ## spiral we're trying to dampen.
            logger.warning(
                "Editor-bridge circuit OPEN for session %s (kind=%s, snapshot=%s)",
                (session_id or "<no-session>")[:16],
                kind,
                self._circuit.snapshot(session_id),
            )

    async def send(
        self,
        command: str,
        params: dict[str, Any] | None = None,
        session_id: str | None = None,
        timeout: float = 5.0,
        surface_error_hints: bool = True,
    ) -> dict[str, Any]:
        """Send a command to a Godot session and return the response data.

        If session_id is None, uses the active session.
        Raises GodotCommandError if the plugin returns an error.
        Raises GodotCommandError(PLUGIN_DISCONNECTED) when there is no active
        Godot editor session.
        Raises GodotCommandError(PLUGIN_DISCONNECTED) when the per-session
        transport circuit is open (death-spiral protection — see
        ``EditorBridgeCircuitBreaker``).
        """
        ## Resolve the active session first so the circuit check below
        ## keys on a concrete session_id when possible. The no-session
        ## sentinel is only used when there genuinely is no session —
        ## otherwise a once-tripped no-session circuit would falsely
        ## block calls against an editor that has since come back up.
        if session_id is None:
            session = self.registry.get_active()
            if session is None:
                self._raise_if_circuit_open(None)
                self._record_failure(None, kind="no_active_session")
                raise GodotCommandError(
                    code=ErrorCode.PLUGIN_DISCONNECTED,
                    message=NO_ACTIVE_SESSION_MESSAGE,
                    data=no_active_session_data(circuit_open=False),
                )
            session_id = session.session_id
            if len(self.registry) > 1:
                logger.debug(
                    "Routing %s to active session %s (%d sessions connected)",
                    command,
                    session_id[:8],
                    len(self.registry),
                )

        self._raise_if_circuit_open(session_id)

        if self.registry.get(session_id) is None:
            self._record_failure(session_id, kind="session_not_found")
            raise GodotCommandError(
                code=ErrorCode.PLUGIN_DISCONNECTED,
                message=session_not_found_message(session_id),
                data=session_not_found_data(session_id, circuit_open=False),
            )

        try:
            response = await self.ws_server.send_command(
                session_id=session_id,
                command=command,
                params=params,
                timeout=timeout,
            )
        except (ConnectionError, TimeoutError) as exc:
            self._record_failure(session_id, kind=type(exc).__name__)
            raise

        ## A bridge round-trip completed (even if the plugin returned an
        ## error response — that's the plugin saying "no" to a valid
        ## command, not a transport failure). Reset the circuit.
        self._circuit.record_success(session_id)

        if response.status == "error":
            error = response.error
            raise GodotCommandError(
                code=error.code if error else "UNKNOWN",
                message=error.message if error else "Unknown error",
                data=error.data if error else {},
            )

        live_session = self.registry.get(session_id)
        pending_new_errors = live_session.pending_new_errors if live_session else 0
        if surface_error_hints and pending_new_errors > 0:
            data = dict(response.data)
            count = pending_new_errors
            if live_session:
                live_session.pending_new_errors = 0
            data["new_errors_since_last_call"] = count
            plural = "s" if count != 1 else ""
            data["new_errors_hint"] = (
                f"{count} new GDScript error{plural} since your last call. "
                "Inspect with logs_read(source='editor', include_details=true) "
                "and/or logs_read(source='game', include_details=true)."
            )
            return data

        return response.data

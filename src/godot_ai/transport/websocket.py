"""WebSocket server for communication with the Godot editor plugin."""

from __future__ import annotations

import asyncio
import errno
import json
import logging
import re
from typing import Any

import websockets
from pydantic import ValidationError
from websockets.asyncio.server import ServerConnection

from godot_ai import __version__ as _SERVER_VERSION
from godot_ai.handlers._readiness import sync_readiness_for_session
from godot_ai.protocol.envelope import (
    CommandRequest,
    CommandResponse,
    HandshakeMessage,
    PlayStateChangedEvent,
    PluginTelemetryEvent,
    ReadinessChangedEvent,
    SceneChangedEvent,
)
from godot_ai.sessions.registry import Session, SessionRegistry
from godot_ai.telemetry import RecordType, record_telemetry
from godot_ai.transport.origin_guard import make_websocket_request_guard

logger = logging.getLogger(__name__)

DEFAULT_PORT = 9500

## RFC 6455 reserves 4000-4999 for application-defined close codes; we use
## 4001 to flag a handshake rejected for duplicate session_id so a debugging
## peer can distinguish it from a normal close.
_CLOSE_CODE_DUPLICATE_SESSION = 4001

## Allowlist of plugin-emitted telemetry event names. Drop everything else
## silently; the plugin and server lists must stay in sync. Plugin-side
## allowlist lives in ``plugin/addons/godot_ai/telemetry.gd``.
_PLUGIN_EVENT_NAMES: frozenset[str] = frozenset(
    {
        "dock_startup",
        "plugin_reload",
        "self_update",
        "dev_server_toggle",
    }
)
_SELF_UPDATE_STATUSES: frozenset[str] = frozenset(
    {"success", "failed_clean", "failed_mixed", "unknown"}
)
_PLUGIN_RELOAD_SOURCES: frozenset[str] = frozenset({"dock_button", "mcp_tool", "unknown"})
_DEV_SERVER_ACTIONS: frozenset[str] = frozenset({"start", "stop", "unknown"})
_VERSION_TOKEN_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+-]{0,63}$")


def _safe_version_token(value: Any) -> str:
    text = str(value)
    return text if _VERSION_TOKEN_RE.fullmatch(text) else "unknown"


def _sanitized_plugin_event_data(name: str, data: dict[str, Any]) -> dict[str, Any]:
    """Return the server-side telemetry schema for a plugin event.

    The plugin has its own allowlist, but a local peer with a valid session
    can still submit arbitrary data. Keep this as the final outbound
    telemetry boundary: known event name in, canonical safe fields out.
    """
    sanitized: dict[str, Any] = {}

    if name == "dock_startup":
        developer_mode = data.get("developer_mode")
        if isinstance(developer_mode, bool):
            sanitized["developer_mode"] = developer_mode
    elif name == "self_update":
        status = str(data.get("status", "unknown"))
        sanitized["status"] = status if status in _SELF_UPDATE_STATUSES else "unknown"
        if "from_version" in data:
            sanitized["from_version"] = _safe_version_token(data["from_version"])
        if "to_version" in data:
            sanitized["to_version"] = _safe_version_token(data["to_version"])
        if "error" in data:
            sanitized["error"] = "reported"
    elif name == "plugin_reload":
        success = data.get("success")
        if isinstance(success, bool):
            sanitized["success"] = success
        source = str(data.get("source", "unknown"))
        sanitized["source"] = source if source in _PLUGIN_RELOAD_SOURCES else "unknown"
        if "error" in data:
            sanitized["error"] = "reported"
    elif name == "dev_server_toggle":
        action = str(data.get("action", "unknown"))
        sanitized["action"] = action if action in _DEV_SERVER_ACTIONS else "unknown"

    sanitized["event_name"] = name
    return sanitized


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
                # Always loopback. The WS channel is the *local* Python-server↔
                # Godot-editor bridge; the editor connects via ws://127.0.0.1
                # (plugin connection.gd). Remote agents reach us over HTTP only,
                # so --allow-host (#421) must NOT widen this port — that would
                # expose the unauthenticated plugin WS to the LAN, and binding
                # "::" (IPv6-only by default on Windows) would break the editor's
                # IPv4 loopback connection.
                "127.0.0.1",
                self.port,
                max_size=4 * 1024 * 1024,  # 4 MB for screenshot base64
                # Reject DNS-rebinding attempts before the upgrade — see
                # godot_ai.transport.origin_guard. Native plugin clients
                # carry a loopback Host and no Origin, so they pass through.
                process_request=make_websocket_request_guard(),
            ):
                await asyncio.Future()  # run forever
        except OSError as e:
            if e.errno == errno.EADDRINUSE:
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

            ## Reject duplicate session_id while the first peer is live —
            ## otherwise the second handshake silently overwrites the
            ## routing map (duplicate-ID hijack).
            existing = self.registry.get(handshake.session_id)
            if existing is not None:
                logger.warning(
                    "Rejecting duplicate handshake for session %s (existing pid=%s, project=%s)",
                    handshake.session_id,
                    existing.editor_pid,
                    existing.project_path,
                )
                await ws.close(
                    code=_CLOSE_CODE_DUPLICATE_SESSION,
                    reason="session id already registered",
                )
                return

            session_id = handshake.session_id
            session = Session(
                session_id=handshake.session_id,
                godot_version=handshake.godot_version,
                project_path=handshake.project_path,
                plugin_version=handshake.plugin_version,
                protocol_version=handshake.protocol_version,
                readiness=handshake.readiness,
                editor_pid=handshake.editor_pid,
                server_launch_mode=handshake.server_launch_mode,
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

            ## Tell the plugin which server version it's talking to so the dock
            ## can surface a banner when plugin_version != server_version (e.g.
            ## after self-update when the plugin was adopting a foreign-port
            ## server owned by another session and `_stop_server` couldn't kill
            ## it because _server_pid was never set). See #174 follow-up.
            await ws.send(
                json.dumps(
                    {
                        "type": "handshake_ack",
                        "server_version": _SERVER_VERSION,
                    }
                )
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
                ## Heal `Session.readiness` from every response envelope.
                ## The plugin stamps live readiness onto its dispatcher
                ## output, so the cache stays in lockstep with editor
                ## state — no `editor_state` ceremony required after a
                ## game stop / autosave / import. Old plugins omit the
                ## field; the helper treats `None` as a no-op so the
                ## existing event-driven path still applies.
                if response.readiness is not None and live is not None:
                    sync_readiness_for_session(live, response.readiness)
                if response.error_watermark is not None and live is not None:
                    _sync_error_watermark_for_session(live, response.error_watermark)
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

        ## Validate the payload before assigning to typed Session fields —
        ## a malformed plugin event (or hijacked WS) used to ship non-string
        ## values straight through to MCP clients via Session.to_dict()
        ## (audit-v2 #7). On ValidationError we drop the event with a
        ## warning rather than corrupt the cached session state.
        try:
            if event == "scene_changed":
                payload = SceneChangedEvent.model_validate(event_data)
                session.current_scene = payload.current_scene
                logger.info(
                    "Session %s: scene changed to %s", session_id[:8], session.current_scene
                )
            elif event == "play_state_changed":
                payload = PlayStateChangedEvent.model_validate(event_data)
                session.play_state = payload.play_state
                logger.info("Session %s: play state -> %s", session_id[:8], session.play_state)
            elif event == "readiness_changed":
                payload = ReadinessChangedEvent.model_validate(event_data)
                session.readiness = payload.readiness
                logger.info("Session %s: readiness -> %s", session_id[:8], session.readiness)
            elif event == "plugin_event":
                ## Plugin-side events (self-update outcome, dock startup,
                ## reload). The plugin owns the allowlist on the emit side,
                ## but the server is the outbound telemetry trust boundary:
                ## validate the envelope and project it into per-event safe
                ## fields before forwarding.
                payload = PluginTelemetryEvent.model_validate(event_data)
                if payload.name in _PLUGIN_EVENT_NAMES:
                    record_telemetry(
                        RecordType.PLUGIN_EVENT,
                        _sanitized_plugin_event_data(payload.name, payload.data),
                        session_id=session_id,
                    )
                else:
                    logger.debug(
                        "Dropping plugin_event with unknown name %r from %s",
                        payload.name,
                        session_id[:8],
                    )
        except ValidationError as exc:
            logger.warning(
                "Dropping malformed %s event from session %s: %s",
                event,
                session_id[:8],
                exc.errors(include_url=False, include_context=False, include_input=False),
            )

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

        ## Always pop on exit — the response receiver in _handle_connection
        ## pops on the happy path, so this is a no-op there; on `ws.send`
        ## raise / TimeoutError / cancellation it prevents Futures leaking
        ## into _pending forever.
        try:
            await ws.send(request.model_dump_json())
            return await asyncio.wait_for(future, timeout=timeout)
        except asyncio.TimeoutError:
            raise TimeoutError(
                f"Command {command} timed out after {timeout}s on session {session_id}"
            )
        finally:
            self._pending.pop(request.request_id, None)


def _sync_error_watermark_for_session(session: Session, value: dict[str, int]) -> int:
    """Update a session's error watermark and return newly observed errors.

    Watermark components reset independently. When run_seq advances, the
    per-run game component is counted in full because the server may never
    observe its zero between stop/start. Editor and debugger components remain
    session-scoped monotonic deltas; a decrease is treated as a reset and the
    current component value is counted when above zero.
    """

    updates: dict[str, int] = {}
    new_total = 0
    incoming_run_seq = _normalized_watermark_int(value.get("run_seq"))
    previous_run_seq = max(0, int(session.error_watermark.get("run_seq", 0)))
    run_advanced = (
        incoming_run_seq is not None
        and previous_run_seq > 0
        and incoming_run_seq > previous_run_seq
    )
    for key, raw_current in value.items():
        current = _normalized_watermark_int(raw_current)
        if current is None:
            continue
        updates[key] = current
        if key == "run_seq":
            continue

        previous = session.error_watermark.get(key)
        if previous is not None:
            previous_int = max(0, int(previous))
            if run_advanced and key == "game_error_warn":
                new_total += current
            elif current >= previous_int:
                new_total += current - previous_int
            else:
                new_total += current
        elif run_advanced and key == "game_error_warn":
            new_total += current
    session.error_watermark.update(updates)
    session.pending_new_errors += new_total
    return new_total


def _normalized_watermark_int(value: object) -> int | None:
    try:
        return max(0, int(value))
    except (TypeError, ValueError):
        return None

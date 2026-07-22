"""WebSocket server for communication with the Godot editor plugin."""

from __future__ import annotations

import asyncio
import errno
import hmac
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
## Handshake carried an auth token that doesn't match this server launch's
## token (#690). Only ever sent when the server was launched with
## GODOT_AI_WS_TOKEN; tokenless handshakes are accepted for compat.
_CLOSE_CODE_AUTH_TOKEN_MISMATCH = 4003

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

    def __init__(
        self,
        registry: SessionRegistry,
        port: int = DEFAULT_PORT,
        auth_token: str | None = None,
    ):
        self.registry = registry
        self.port = port
        ## Per-launch handshake auth token (#690). The spawning plugin
        ## generates it and hands it to us via the GODOT_AI_WS_TOKEN spawn
        ## env; a handshake carrying a DIFFERENT token is rejected. A
        ## handshake carrying no token is still accepted — older plugins
        ## and editors adopting a server they didn't spawn have no token,
        ## and the field is attacker-omittable anyway, so this is defense
        ## in depth on top of loopback-only binding (see AGENTS.md's WS
        ## trust-boundary note), not an authentication boundary.
        self._auth_token = auth_token or None
        ## request_id -> (owner session_id, future). The session id is part
        ## of the entry (#690) so (a) a disconnect can immediately fail that
        ## session's in-flight futures instead of leaving callers to wait
        ## out their full per-command timeout, and (b) a response is only
        ## ever resolved by the connection the command was sent to — a
        ## hostile local session can't forge a reply to another session's
        ## request_id (defense in depth on top of the uuid4 request ids).
        self._pending: dict[str, tuple[str, asyncio.Future[CommandResponse]]] = {}
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
        close_code: int | None = None
        try:
            # First message must be a handshake
            raw = await asyncio.wait_for(ws.recv(), timeout=10.0)
            data = json.loads(raw)
            handshake = HandshakeMessage.model_validate(data)

            ## #690: when this launch has a token, a handshake carrying a
            ## DIFFERENT one is a peer reading someone else's (or a stale)
            ## secret — reject before registering. Absent tokens pass: see
            ## __init__'s note on why this is compat-gated defense in depth.
            ## Truthiness, not `is not None`: an empty-string auth_token
            ## means "no token" exactly like an omitted field (the plugin
            ## omits when empty, but a client that serializes "" instead
            ## must not be 4003'd — rejecting "" buys nothing when omitting
            ## the field is always accepted).
            if self._auth_token is not None and handshake.auth_token:
                if not hmac.compare_digest(handshake.auth_token, self._auth_token):
                    logger.warning(
                        "Rejecting handshake for session %s: auth token mismatch",
                        handshake.session_id,
                    )
                    await ws.close(
                        code=_CLOSE_CODE_AUTH_TOKEN_MISMATCH,
                        reason="auth token mismatch",
                    )
                    return

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

                ## Parse/validation failures of a single frame must not tear
                ## down the whole editor session (#526): before this guard,
                ## one garbled frame raised out of the loop into the
                ## catch-all, and the finally block unregistered the session
                ## and dropped the editor↔server bridge. Skip the bad frame
                ## with a warning instead, mirroring the event path's
                ## ValidationError handling. Only parse/validation errors are
                ## swallowed — everything else still propagates.
                try:
                    data = json.loads(raw_msg)
                except (json.JSONDecodeError, UnicodeDecodeError) as exc:
                    ## UnicodeDecodeError covers a bytes frame with invalid
                    ## UTF-8 — same malformed-frame class as bad JSON (#526).
                    logger.warning(
                        "Dropping non-JSON frame from session %s: %s", session_id[:8], exc
                    )
                    continue
                if not isinstance(data, dict):
                    ## Valid JSON but not an object (e.g. `[]` or `42`) —
                    ## `.get()` below would raise AttributeError and tear the
                    ## session down through the catch-all (#526).
                    logger.warning(
                        "Dropping non-object JSON frame from session %s: %s",
                        session_id[:8],
                        type(data).__name__,
                    )
                    continue

                # Handle state events from the plugin
                if data.get("type") == "event":
                    self._handle_event(session_id, data)
                    continue

                # Handle command responses
                try:
                    response = CommandResponse.model_validate(data)
                except ValidationError as exc:
                    logger.warning(
                        "Dropping malformed command response from session %s: %s",
                        session_id[:8],
                        exc.errors(include_url=False, include_context=False, include_input=False),
                    )
                    ## If the malformed frame carried a request_id for a
                    ## pending command, fail that future immediately with a
                    ## clear error instead of leaving the caller to hit its
                    ## timeout (#526).
                    request_id = data.get("request_id") if isinstance(data, dict) else None
                    if isinstance(request_id, str):
                        entry = self._pending.get(request_id)
                        ## Session-scoped (#690): only the connection the
                        ## command was sent to may fail its future.
                        if entry is not None and entry[0] == session_id:
                            self._pending.pop(request_id, None)
                            pending = entry[1]
                            if not pending.done():
                                pending.set_exception(
                                    ConnectionError(
                                        f"Malformed response from session {session_id} "
                                        f"for request {request_id}"
                                    )
                                )
                    continue
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
                entry = self._pending.get(response.request_id)
                if entry is not None:
                    if entry[0] != session_id:
                        ## Cross-session response injection (#690): the reply
                        ## came from a different connection than the command
                        ## was sent to. Leave the real session's future
                        ## pending and drop the forged frame.
                        logger.warning(
                            "Dropping response for request %s from session %s — "
                            "command was sent to session %s",
                            response.request_id[:8],
                            session_id[:8],
                            entry[0][:8],
                        )
                    else:
                        self._pending.pop(response.request_id, None)
                        future = entry[1]
                        if not future.done():
                            future.set_result(response)

        except websockets.ConnectionClosed as exc:
            ## Normalize the close frame: prefer the one the peer sent
            ## (rcvd); the keepalive watchdog's own 1011 lives on ``sent``.
            ## The numeric code flows into disconnect telemetry (so 1011
            ## keepalive kills are measurable); the free-form reason stays
            ## in local logs only.
            frame = exc.rcvd or exc.sent
            close_reason = ""
            if frame is not None:
                close_code = frame.code
                close_reason = frame.reason or ""
            logger.info(
                "Session disconnected: %s (close code %s, reason %r)",
                session_id,
                close_code,
                close_reason,
            )
        except Exception:
            logger.exception("Error in WebSocket handler for session %s", session_id)
        finally:
            if session_id:
                self.registry.unregister(session_id, close_code=close_code)
                self._connections.pop(session_id, None)
                ## Fail this session's in-flight futures NOW (#690): a close
                ## settles nothing by itself, so every in-flight command used
                ## to wait out its full per-command timeout (120s for
                ## test_run) after an editor crash / plugin reload — and the
                ## circuit breaker recorded TimeoutError instead of a
                ## disconnect, degrading death-spiral diagnostics.
                for request_id, entry in list(self._pending.items()):
                    if entry[0] != session_id:
                        continue
                    self._pending.pop(request_id, None)
                    future = entry[1]
                    if not future.done():
                        future.set_exception(
                            ConnectionError(
                                f"Session {session_id} disconnected while the command was in flight"
                            )
                        )

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
        self._pending[request.request_id] = (session_id, future)

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


## Watermark components whose baseline resets each game run. The server may
## never observe their zero between stop/start, so on an advanced run_seq the
## current value is counted in full rather than diffed against a stale baseline.
## `game_error_warn` is historically misnamed — it carries game-process ERROR
## counts (see McpGameLogBuffer.error_total); `game_warn` is its warn-level
## sibling.
_PER_RUN_WATERMARK_KEYS = frozenset({"game_error_warn", "game_warn"})

## Warn-level watermark components. Split out from error components so a
## warning-only run surfaces as `new_warnings_since_last_call` instead of
## reading as clean. Editor and game warn streams are independent processes
## with no overlap, so their deltas sum (unlike the error path, where the game
## buffer and Debugger Errors tab are two views of one stream).
_WARN_WATERMARK_KEYS = frozenset({"editor_ring_warn", "game_warn"})


def _sync_error_watermark_for_session(session: Session, value: dict[str, int]) -> None:
    """Fold a plugin-stamped watermark into the session's counters.

    Side effects only: updates ``session.error_watermark`` to the incoming
    component values, adds the newly observed error count to
    ``session.pending_new_errors``, and accumulates newly observed warnings
    onto ``session.pending_new_warnings`` as a parallel,
    independently-consumed channel.

    Watermark components reset independently. When run_seq advances, per-run
    game components are counted in full because the server may never observe
    their zero between stop/start. Editor and debugger components remain
    session-scoped monotonic deltas; a decrease is treated as a reset and the
    current component value is counted when above zero. The debugger and game
    error components overlap (both observe the running game's script errors),
    so their deltas are combined with max(), not summed.
    """

    updates: dict[str, int] = {}
    deltas: dict[str, int] = {}
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
            if run_advanced and key in _PER_RUN_WATERMARK_KEYS:
                deltas[key] = current
            elif current >= previous_int:
                deltas[key] = current - previous_int
            else:
                deltas[key] = current
        elif run_advanced and key in _PER_RUN_WATERMARK_KEYS:
            deltas[key] = current

    ## Warnings first — pull them out before the error math so they can't be
    ## conflated with the error total. Independent process streams, so sum.
    new_warnings = sum(deltas.pop(key, 0) for key in _WARN_WATERMARK_KEYS)

    ## A running game's script errors surface twice: in the game log buffer
    ## (game_error_warn) and as Debugger Errors-tab rows (debugger_promoted).
    ## Those are alternate views of the same error stream — summing them
    ## reports 2 for every push_error once the #641 deferred scans promote
    ## rows reliably. Take the larger of the two overlapping views; only
    ## editor-process components accumulate independently.
    overlap = max(deltas.pop("debugger_promoted", 0), deltas.pop("game_error_warn", 0))
    new_total = overlap + sum(deltas.values())
    session.error_watermark.update(updates)
    session.pending_new_errors += new_total
    session.pending_new_warnings += new_warnings


def _normalized_watermark_int(value: object) -> int | None:
    try:
        return max(0, int(value))
    except (TypeError, ValueError):
        return None

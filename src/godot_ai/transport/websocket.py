"""WebSocket server for communication with the Godot editor plugin."""

from __future__ import annotations

import asyncio
import errno
import hashlib
import hmac
import json
import logging
import re
import secrets
import socket
from functools import partial
from typing import Any, TypeVar

import websockets
from pydantic import BaseModel, ValidationError
from websockets.asyncio.server import ServerConnection

from godot_ai import __version__ as _SERVER_VERSION
from godot_ai.protocol.envelope import (
    WS_PROTOCOL_VERSION,
    AuthenticatedHandshake,
    AuthenticationHello,
    CommandRequest,
    CommandResponse,
    CustomToolsChangedEvent,
    PlayStateChangedEvent,
    PluginTelemetryEvent,
    ReadinessChangedEvent,
    SceneChangedEvent,
    TelemetryOptOutEvent,
)
from godot_ai.services.custom_tool_service import CustomToolDefinition, CustomToolService
from godot_ai.sessions.registry import Session, SessionRegistry
from godot_ai.telemetry import RecordType, latch_runtime_opt_out, record_telemetry
from godot_ai.transport.origin_guard import make_websocket_request_guard

logger = logging.getLogger(__name__)

DEFAULT_PORT = 9500
DEFAULT_MAX_OPEN_CONNECTIONS = 32
DEFAULT_OPEN_TIMEOUT_SECONDS = 5.0
DEFAULT_HANDSHAKE_TIMEOUT_SECONDS = 5.0
DEFAULT_MAX_HANDSHAKE_FRAME_BYTES = 8 * 1024
DEFAULT_MAX_MESSAGE_BYTES = 4 * 1024 * 1024
DEFAULT_MAX_DECODED_MESSAGES = 4
## Keepalive: `websockets` pings every editor peer and closes the session
## with 1011 "keepalive ping timeout" when the pong is late. The editor can
## only answer a ping from `McpConnection._process` → `WebSocketPeer.poll()`
## on the Godot main thread, so any stall longer than the deadline reaps a
## session whose editor is merely busy: a long synchronous editor operation
## the exclusive-run servicing does not cover, or a CPU-starved CI runner
## where the editor and the game subprocess both software-render under
## lavapipe (#958 — the pong went missing for >20s right after
## `run_project`, and the plugin's v4 lifecycle treats the resulting drop as
## terminal, so one late pong killed the whole smoke). The interval keeps
## the library default so ping cadence is unchanged; only the tolerance for
## a late pong is widened, to a budget that comfortably exceeds the smoke's
## 45s session-loss grace. A stall past this is a genuinely hung editor. A
## dead editor process still closes the socket immediately — this deadline
## only bounds how long a *silent* peer keeps its session.
DEFAULT_KEEPALIVE_PING_INTERVAL_SECONDS = 20.0
DEFAULT_KEEPALIVE_PING_TIMEOUT_SECONDS = 60.0

## RFC 6455 reserves 4000-4999 for application-defined close codes; we use
## 4001 to flag a handshake rejected for duplicate session_id so a debugging
## peer can distinguish it from a normal close.
_CLOSE_CODE_DUPLICATE_SESSION = 4001
## Mixed pre-v4/v4 peers fail explicitly instead of entering a legacy parser.
_CLOSE_CODE_PROTOCOL_MISMATCH = 4002
## Missing, stale, or wrong editor capability. No weaker retry exists.
_CLOSE_CODE_AUTH_FAILED = 4003

_CAPABILITY_RE = re.compile(r"^[0-9a-f]{64}$")
_SERVER_PROOF_DOMAIN = "godot-ai-ws-v2/server-proof"
_CLIENT_PROOF_DOMAIN = "godot-ai-ws-v2/client-proof"
_MIN_GODOT_VERSION = (4, 7)


def _proof_message(domain: str, values: tuple[str | int, ...]) -> bytes:
    """Encode an unambiguous, domain-separated handshake transcript."""

    message = bytearray(domain.encode("ascii"))
    for value in values:
        encoded = str(value).encode("utf-8")
        message.extend(b"\n")
        message.extend(str(len(encoded)).encode("ascii"))
        message.extend(b":")
        message.extend(encoded)
    return bytes(message)


def _supports_v4_editor(godot_version: str) -> bool:
    # Engine.get_version_info().string uses a hyphen before status in Godot
    # 4.7 (for example ``4.7-stable (official)``); older patch-bearing forms
    # use a dot. Require either real delimiter after the complete minor number,
    # while accepting both official display formats.
    match = re.match(r"^(\d+)\.(\d+)(?:[.-]|$)", godot_version)
    if match is None:
        return False
    major, minor = map(int, match.groups())
    return major == _MIN_GODOT_VERSION[0] and minor >= _MIN_GODOT_VERSION[1]


def _hmac_proof(capability: str, domain: str, values: tuple[str | int, ...]) -> str:
    if not _CAPABILITY_RE.fullmatch(capability):
        raise ValueError("editor WebSocket capability must be 32 lowercase-hex bytes")
    return hmac.new(
        capability.encode("ascii"),
        _proof_message(domain, values),
        hashlib.sha256,
    ).hexdigest()


def websocket_server_proof(
    capability: str,
    *,
    client_nonce: str,
    server_nonce: str,
    server_version: str = _SERVER_VERSION,
) -> str:
    """Prove server capability possession without receiving editor metadata."""

    return _hmac_proof(
        capability,
        _SERVER_PROOF_DOMAIN,
        (WS_PROTOCOL_VERSION, client_nonce, server_nonce, server_version),
    )


def websocket_client_proof(
    capability: str,
    *,
    client_nonce: str,
    server_nonce: str,
    session_id: str,
    godot_version: str,
    project_path: str,
    plugin_version: str,
    readiness: str,
    editor_pid: int,
    server_launch_mode: str,
    server_version: str = _SERVER_VERSION,
) -> str:
    """Bind editor authentication to the verified challenge and all metadata."""

    return _hmac_proof(
        capability,
        _CLIENT_PROOF_DOMAIN,
        (
            WS_PROTOCOL_VERSION,
            client_nonce,
            server_nonce,
            server_version,
            session_id,
            godot_version,
            project_path,
            plugin_version,
            readiness,
            editor_pid,
            server_launch_mode,
        ),
    )


class _BoundedOpeningServerConnection(ServerConnection):
    """Abort raw sockets beyond the server's pre-auth connection budget."""

    def __init__(self, *args: Any, opening_limit: int, **kwargs: Any) -> None:
        super().__init__(*args, **kwargs)
        self._opening_limit = opening_limit
        self._rejected_at_open = False

    def connection_made(self, transport: asyncio.BaseTransport) -> None:
        super().connection_made(transport)
        ## websockets registers this connection's handler synchronously in
        ## ``handler_tasks`` above. Counting that set bounds HTTP upgrades,
        ## half-open handshakes, pending reservations, and active peers with
        ## one cheap admission check before attacker bytes are processed.
        handlers = getattr(self.server, "handler_tasks", None)
        if handlers is None or len(handlers) > self._opening_limit:
            self._rejected_at_open = True
            transport.abort()

    def data_received(self, data: bytes) -> None:
        if not self._rejected_at_open:
            super().data_received(data)


class _HandshakeFailure(Exception):
    def __init__(self, code: int, reason: str) -> None:
        self.code = code
        self.reason = reason
        super().__init__(reason)


_HandshakeModel = TypeVar("_HandshakeModel", bound=BaseModel)


def _unique_json_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def _reject_json_constant(value: str) -> Any:
    raise ValueError(f"non-finite JSON constant: {value}")


def _strict_json_loads(raw: str | bytes) -> Any:
    return json.loads(
        raw,
        object_pairs_hook=_unique_json_object,
        parse_constant=_reject_json_constant,
    )


def _remaining_handshake_time(deadline: float) -> float:
    remaining = deadline - asyncio.get_running_loop().time()
    if remaining <= 0:
        raise _HandshakeFailure(1008, "v4 editor handshake timed out")
    return remaining


async def _receive_handshake_frame(
    ws: ServerConnection,
    deadline: float,
    model: type[_HandshakeModel],
) -> _HandshakeModel:
    try:
        raw = await asyncio.wait_for(ws.recv(), _remaining_handshake_time(deadline))
    except asyncio.TimeoutError as exc:
        raise _HandshakeFailure(1008, "v4 editor handshake timed out") from exc
    if not isinstance(raw, str):
        raise _HandshakeFailure(1008, "v4 editor handshake requires text JSON")
    if len(raw.encode("utf-8")) > DEFAULT_MAX_HANDSHAKE_FRAME_BYTES:
        raise _HandshakeFailure(1009, "v4 editor handshake frame too large")
    try:
        data = _strict_json_loads(raw)
    except (json.JSONDecodeError, UnicodeDecodeError, ValueError) as exc:
        raise _HandshakeFailure(1008, "invalid v4 editor handshake JSON") from exc
    if not isinstance(data, dict):
        raise _HandshakeFailure(1008, "invalid v4 editor handshake object")
    if data.get("protocol_version") != WS_PROTOCOL_VERSION:
        raise _HandshakeFailure(
            _CLOSE_CODE_PROTOCOL_MISMATCH,
            f"Godot AI v4 WebSocket protocol {WS_PROTOCOL_VERSION} required",
        )
    try:
        return model.model_validate(data)
    except ValidationError as exc:
        expected_type = "auth_hello" if model is AuthenticationHello else "auth_response"
        if data.get("type") != expected_type:
            raise _HandshakeFailure(
                _CLOSE_CODE_PROTOCOL_MISMATCH,
                f"Godot AI v4 expected {expected_type}",
            ) from exc
        raise _HandshakeFailure(1008, f"invalid v4 {expected_type}") from exc


async def _send_handshake_frame(
    ws: ServerConnection,
    deadline: float,
    payload: dict[str, Any],
) -> None:
    try:
        await asyncio.wait_for(
            ws.send(json.dumps(payload, separators=(",", ":"))),
            _remaining_handshake_time(deadline),
        )
    except asyncio.TimeoutError as exc:
        raise _HandshakeFailure(1008, "v4 editor handshake timed out") from exc


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
## #913. Twinned with ``telemetry.gd::OPT_OUT_EVENT``, locked by
## test_telemetry_event_name_parity.py — a one-sided rename would silently
## stop delivering opt-outs. Not in ``_PLUGIN_EVENT_NAMES``: that allowlist
## gates events the server *records*, and this is the opposite.
TELEMETRY_OPT_OUT_EVENT = "telemetry_opt_out"
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
        *,
        max_open_connections: int = DEFAULT_MAX_OPEN_CONNECTIONS,
        sock: socket.socket | None = None,
    ):
        self.registry = registry
        self.port = port
        ## A listening socket the launcher already holds (a port handed over
        ## from a replaced backend); host/port are then only informational.
        self._sock = sock
        if auth_token is not None and not _CAPABILITY_RE.fullmatch(auth_token):
            raise ValueError("editor WebSocket capability must be 32 lowercase-hex bytes")
        if max_open_connections <= 0:
            raise ValueError("max_open_connections must be positive")
        ## None is a deliberately locked editor bridge, not a tokenless mode:
        ## HTTP/status may still start so lifecycle diagnostics remain
        ## available, but every editor connection fails closed until the
        ## capability bootstrap supplies a fresh 32-byte value.
        self._auth_token = auth_token
        self._max_open_connections = int(max_open_connections)
        self._ready_event = asyncio.Event()
        self._startup_error: BaseException | None = None
        ## Coalesced tools/list_changed broadcast. Broadcasts run OFF the
        ## per-editor receive loop (a stalled MCP transport must not delay
        ## queued command responses behind its notify_timeout_s cap), and at
        ## most ONE task is ever in flight: list_changed is a contentless
        ## poke, so N catalog changes during a stalled send need only one
        ## trailing re-notification, not N queued tasks.
        self._broadcast_task: asyncio.Task | None = None
        self._broadcast_rerun: bool = False
        self._custom_tool_service: CustomToolService = CustomToolService.get_instance()

    def _bind_kwargs(self) -> dict[str, Any]:
        if self._sock is not None:
            return {"sock": self._sock}
        return {"host": "127.0.0.1", "port": self.port}

    async def start(self):
        logger.info("Starting WebSocket server on port %d", self.port)
        try:
            async with websockets.serve(
                self._handle_connection,
                # Always loopback. The WS channel is the *local* Python-server↔
                # Godot-editor bridge; the editor connects via ws://127.0.0.1
                # (plugin connection.gd). Remote agents reach us over HTTP only,
                # so --allow-host (#421) must NOT widen this port — authentication
                # is defense in depth, not permission to expose the editor bridge
                # to the LAN. Binding "::" (IPv6-only by default on Windows)
                # would also break the editor's IPv4 loopback connection.
                **self._bind_kwargs(),
                ## Start under the tiny pre-auth ceiling. Once both proofs
                ## validate, the handler raises this peer's parser limit to the
                ## normal 4 MiB screenshot/command envelope budget.
                max_size=DEFAULT_MAX_HANDSHAKE_FRAME_BYTES,
                max_queue=DEFAULT_MAX_DECODED_MESSAGES,
                open_timeout=DEFAULT_OPEN_TIMEOUT_SECONDS,
                close_timeout=1.0,
                ## Explicit, not the library default: see the constants'
                ## rationale (#958). Pinned by tests/unit/test_websocket_keepalive.py.
                ping_interval=DEFAULT_KEEPALIVE_PING_INTERVAL_SECONDS,
                ping_timeout=DEFAULT_KEEPALIVE_PING_TIMEOUT_SECONDS,
                compression=None,
                create_connection=partial(
                    _BoundedOpeningServerConnection,
                    opening_limit=self._max_open_connections,
                ),
                # Reject DNS-rebinding attempts before the upgrade — see
                # godot_ai.transport.origin_guard. Native plugin clients
                # carry a loopback Host and no Origin, so they pass through.
                process_request=make_websocket_request_guard(),
            ):
                self._ready_event.set()
                await asyncio.Future()  # run forever
        except BaseException as exc:
            self._startup_error = exc
            self._ready_event.set()
            if isinstance(exc, OSError) and exc.errno == errno.EADDRINUSE:
                logger.warning(
                    "WebSocket port %d already in use; refusing a half-ready HTTP server.",
                    self.port,
                )
            raise

    async def wait_until_ready(self) -> None:
        """Return only after the WebSocket listener binds, or propagate startup failure."""

        await self._ready_event.wait()
        if self._startup_error is not None:
            raise RuntimeError("WebSocket listener failed to start") from self._startup_error

    async def _handle_connection(self, ws: ServerConnection):
        session_id: str | None = None
        close_code: int | None = None
        try:
            if self._auth_token is None:
                raise _HandshakeFailure(
                    _CLOSE_CODE_AUTH_FAILED,
                    "server has no v4 editor capability; restart it from Godot",
                )

            deadline = asyncio.get_running_loop().time() + DEFAULT_HANDSHAKE_TIMEOUT_SECONDS
            hello = await _receive_handshake_frame(ws, deadline, AuthenticationHello)
            server_nonce = secrets.token_hex(32)
            await _send_handshake_frame(
                ws,
                deadline,
                {
                    "type": "auth_challenge",
                    "protocol_version": WS_PROTOCOL_VERSION,
                    "client_nonce": hello.client_nonce,
                    "server_nonce": server_nonce,
                    "server_version": _SERVER_VERSION,
                    "server_proof": websocket_server_proof(
                        self._auth_token,
                        client_nonce=hello.client_nonce,
                        server_nonce=server_nonce,
                    ),
                },
            )
            handshake = await _receive_handshake_frame(ws, deadline, AuthenticatedHandshake)
            if (
                handshake.client_nonce != hello.client_nonce
                or handshake.server_nonce != server_nonce
            ):
                raise _HandshakeFailure(_CLOSE_CODE_AUTH_FAILED, "v4 handshake nonce mismatch")
            expected_client_proof = websocket_client_proof(
                self._auth_token,
                client_nonce=hello.client_nonce,
                server_nonce=server_nonce,
                session_id=handshake.session_id,
                godot_version=handshake.godot_version,
                project_path=handshake.project_path,
                plugin_version=handshake.plugin_version,
                readiness=handshake.readiness,
                editor_pid=handshake.editor_pid,
                server_launch_mode=handshake.server_launch_mode,
            )
            if not hmac.compare_digest(handshake.client_proof, expected_client_proof):
                raise _HandshakeFailure(_CLOSE_CODE_AUTH_FAILED, "v4 editor proof failed")
            if not _supports_v4_editor(handshake.godot_version):
                raise _HandshakeFailure(
                    _CLOSE_CODE_PROTOCOL_MISMATCH,
                    "Godot 4.7 or newer within the 4.x line is required by the v4 editor protocol",
                )

            ## Proof verification is the only transition that raises this
            ## peer's inbound parser from the handshake ceiling to the normal
            ## payload ceiling. A peer cannot allocate a 4 MiB decoded frame
            ## before authenticating.
            ws.protocol.max_message_size = DEFAULT_MAX_MESSAGE_BYTES

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
            ## Reserve before ACK so a simultaneous duplicate cannot claim the
            ## same ID, but do not expose a routable session until the ACK send
            ## succeeds. A failed send falls through ``finally`` and removes
            ## this pending entry atomically.
            if not self.registry.reserve_connection(session, ws):
                existing = self.registry.get(session_id)
                detail = (
                    f"existing pid={existing.editor_pid}, project={existing.project_path}"
                    if existing is not None
                    else "another handshake is pending"
                )
                logger.warning(
                    "Rejecting duplicate handshake for session %s (%s)",
                    session_id,
                    detail,
                )
                await ws.close(
                    code=_CLOSE_CODE_DUPLICATE_SESSION,
                    reason="session id already registered",
                )
                return

            ## Tell the plugin which server version it's talking to so the dock
            ## can surface a banner when plugin_version != server_version (e.g.
            ## after self-update when the plugin was adopting a foreign-port
            ## server owned by another session and `_stop_server` couldn't kill
            ## it because _server_pid was never set). See #174 follow-up.
            await _send_handshake_frame(
                ws,
                deadline,
                {
                    "type": "handshake_ack",
                    "protocol_version": WS_PROTOCOL_VERSION,
                    "server_version": _SERVER_VERSION,
                },
            )
            self.registry.publish_connection(session_id, ws)
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
                self.registry.note_peer_activity(session_id)

                ## Parse/validation failures of a single frame must not tear
                ## down the whole editor session (#526): before this guard,
                ## one garbled frame raised out of the loop into the
                ## catch-all, and the finally block unregistered the session
                ## and dropped the editor↔server bridge. Skip the bad frame
                ## with a warning instead, mirroring the event path's
                ## ValidationError handling. Only parse/validation errors are
                ## swallowed — everything else still propagates.
                try:
                    data = _strict_json_loads(raw_msg)
                except (json.JSONDecodeError, UnicodeDecodeError, ValueError) as exc:
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
                    await self._handle_event(session_id, data)
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
                        malformed = self.registry.claim_pending_response(
                            session_id,
                            request_id,
                            peer=ws,
                        )
                        if malformed is not None:
                            malformed.set_exception(
                                ConnectionError(
                                    f"Malformed response from session {session_id} "
                                    f"for request {request_id}"
                                )
                            )
                    continue
                ## Claim before applying envelope side effects: unsolicited or
                ## late responses do not own a pending request and therefore
                ## have no authority to mutate the editor snapshot.
                future = self.registry.claim_pending_response(
                    session_id,
                    response.request_id,
                    peer=ws,
                )
                if future is None:
                    logger.warning(
                        "Dropping response for unowned request %s from session %s",
                        response.request_id[:8],
                        session_id[:8],
                    )
                    continue

                ## Heal `Session.readiness` from every owned response envelope.
                ## The plugin stamps live readiness onto its dispatcher
                ## output, so the cache stays in lockstep with editor
                ## state — no `editor_state` ceremony required after a
                ## game stop / autosave / import.
                self.registry.record_readiness(session_id, response.readiness)
                if response.error_watermark is not None:
                    self.registry.record_error_watermark(session_id, response.error_watermark)
                if not future.done():
                    future.set_result(response)

        except _HandshakeFailure as exc:
            close_code = exc.code
            logger.warning("Rejecting editor WebSocket handshake: %s", exc.reason)
            try:
                await ws.close(code=exc.code, reason=exc.reason)
            except websockets.ConnectionClosed:
                pass
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
                removed = self.registry.remove_connection(
                    session_id,
                    peer=ws,
                    close_code=close_code,
                )
                ## Drop this editor's custom tools from the catalog and tell
                ## MCP clients — a closed editor's tools must not linger as
                ## invokable entries. A rejected duplicate does not own the
                ## table entry, so it must not erase the live peer's catalog.
                if removed and self._custom_tool_service.remove_session(session_id):
                    self._schedule_tools_broadcast()

    def _schedule_tools_broadcast(self) -> None:
        """Fire a coalesced tools/list_changed broadcast, non-blocking.

        Called from the per-editor receive loop and disconnect cleanup —
        awaiting the broadcast inline would let one stalled MCP transport
        (bounded, but up to ``notify_timeout_s`` per session) delay queued
        command responses behind it. At most one broadcast task is in
        flight: a change arriving mid-broadcast sets a rerun flag consumed
        when the current send finishes, so an event burst against a stalled
        client costs one trailing notification instead of one queued task
        per event. Single-threaded event loop — the flag needs no lock.
        """
        if self._broadcast_task is not None and not self._broadcast_task.done():
            self._broadcast_rerun = True
            return
        self._broadcast_rerun = False
        self._broadcast_task = asyncio.create_task(self._run_tools_broadcast())

    async def _run_tools_broadcast(self) -> None:
        while True:
            try:
                await self._custom_tool_service.notify_tools_change()
            except Exception:
                ## notify_tools_change isolates per-session failures itself;
                ## this catches anything that still escapes (test doubles).
                logger.debug("tools/list_changed broadcast failed", exc_info=True)
            if not self._broadcast_rerun:
                return
            self._broadcast_rerun = False

    async def _handle_event(self, session_id: str, data: dict) -> None:
        event = data.get("event", "")
        event_data = data.get("data", {})
        if self.registry.get(session_id) is None:
            return

        ## Validate the payload before assigning to typed Session fields —
        ## a malformed plugin event (or hijacked WS) used to ship non-string
        ## values straight through to MCP clients via Session.to_dict()
        ## (audit-v2 #7). On ValidationError we drop the event with a
        ## warning rather than corrupt the cached session state.
        try:
            if event == "scene_changed":
                payload = SceneChangedEvent.model_validate(event_data)
                self.registry.record_scene_changed(session_id, payload.current_scene)
                logger.info(
                    "Session %s: scene changed to %s", session_id[:8], payload.current_scene
                )
            elif event == "play_state_changed":
                payload = PlayStateChangedEvent.model_validate(event_data)
                self.registry.record_play_state_changed(session_id, payload.play_state)
                logger.info("Session %s: play state -> %s", session_id[:8], payload.play_state)
            elif event == "custom_tools_changed":
                ## Plugin payload shape: {"tools": [ {...}, ... ]} — see
                ## plugin.gd::_on_custom_tools_changed. Iterating event_data
                ## itself would walk dict KEYS, not tool dicts.
                try:
                    payload = CustomToolsChangedEvent.model_validate(event_data)
                    tools = [CustomToolDefinition.model_validate(t) for t in payload.tools]
                    self._custom_tool_service.update_session_tools(session_id, tools)
                    logger.info(
                        "Session %s: custom tools -> %d registered (%d enabled)",
                        session_id[:8],
                        len(tools),
                        sum(tool.enabled for tool in tools),
                    )
                    self._schedule_tools_broadcast()
                except ValidationError as e:
                    logger.error("Invalid custom tool definition: %s", e)
            elif event == "readiness_changed":
                payload = ReadinessChangedEvent.model_validate(event_data)
                self.registry.record_readiness(session_id, payload.readiness)
                logger.info("Session %s: readiness -> %s", session_id[:8], payload.readiness)
            elif event == "plugin_event":
                ## Plugin-side events (self-update outcome, dock startup,
                ## reload). The plugin owns the allowlist on the emit side,
                ## but the server is the outbound telemetry trust boundary:
                ## validate the envelope and project it into per-event safe
                ## fields before forwarding.
                payload = PluginTelemetryEvent.model_validate(event_data)
                if payload.name in _PLUGIN_EVENT_NAMES:
                    try:
                        record_telemetry(
                            RecordType.PLUGIN_EVENT,
                            _sanitized_plugin_event_data(payload.name, payload.data),
                            session_id=session_id,
                        )
                    except Exception:  # noqa: BLE001
                        logger.debug("plugin event telemetry failed", exc_info=True)
                else:
                    logger.debug(
                        "Dropping plugin_event with unknown name %r from %s",
                        payload.name,
                        session_id[:8],
                    )
            elif event == TELEMETRY_OPT_OUT_EVENT:
                ## #913: an editor that adopted this server cannot put
                ## GODOT_AI_DISABLE_TELEMETRY in our environment, so it says so
                ## here — authenticated and instance-bound, past the registry
                ## check above, while status/lease stays read-only. Latching
                ## and one-way; holds until this process is replaced.
                TelemetryOptOutEvent.model_validate(event_data)
                if latch_runtime_opt_out():
                    logger.info(
                        "Session %s opted this server out of telemetry for the "
                        "rest of its life; restart it to re-enable.",
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
        request = CommandRequest(command=command, params=params or {})
        ws, future = self.registry.open_request(session_id, request.request_id)

        ## Always pop on exit — the response receiver in _handle_connection
        ## pops on the happy path, so this is a no-op there; on `ws.send`
        ## raise / TimeoutError / cancellation it prevents Futures leaking
        ## in the peer's pending set forever.
        ## The deadline covers the SEND as well as the response wait. When the
        ## transport is write-paused by TCP backpressure — an editor that has
        ## stopped reading its socket — `ws.send` blocks for the whole stall, and
        ## with the timeout wrapped around the future alone it never even
        ## started: the tool call hung unbounded instead of failing with an
        ## actionable message. Nothing else bounds it; websockets' own keepalive
        ## ping queues behind the same paused drain.
        ##
        ## The two legs get distinct messages, because they mean opposite things
        ## to a caller deciding whether to retry. `websockets` hands the COMPLETE
        ## frame to the transport before awaiting `drain()`, so a send-leg
        ## timeout leaves a well-formed request buffered — the editor executes it
        ## in full once it drains. Reporting that as a plain timeout invites a
        ## retry that duplicates the mutation. A response-leg timeout means the
        ## request was delivered and the reply did not arrive in budget, which is
        ## the ordinary case. Conflating the two is the same failure the
        ## disconnect-vs-timeout split below exists to prevent.
        sent = False
        try:
            async with asyncio.timeout(timeout):
                await ws.send(request.model_dump_json())
                sent = True
                return await future
        except asyncio.TimeoutError:
            if not sent:
                raise TimeoutError(
                    f"Command {command} timed out after {timeout}s on session {session_id} "
                    "before the request left the socket (transport write-paused). "
                    "It may still execute when the editor resumes reading — do not "
                    "retry a mutating command without checking editor state first."
                )
            raise TimeoutError(
                f"Command {command} timed out after {timeout}s on session {session_id}"
            )
        finally:
            self.registry.cancel_request(session_id, request.request_id, peer=ws)

"""Authenticated, finite-work ASGI boundary."""

from __future__ import annotations

import asyncio
import hmac
import json
from http import HTTPStatus
from typing import Any

from starlette.types import ASGIApp, Message, Receive, Scope, Send

from godot_ai.transport.capability import validate_capability

MAX_HTTP_BODY_BYTES = 4 * 1024 * 1024
MAX_LEASE_BODY_BYTES = 8 * 1024
BODY_TIMEOUT_SECONDS = 15.0
MAX_HTTP_CONCURRENCY = 64
MAX_MCP_SESSIONS = 32
MCP_SESSION_IDLE_SECONDS = 30 * 60
MCP_HANDSHAKE_VERSIONS = frozenset(
    {b"2024-11-05", b"2025-03-26", b"2025-06-18", b"2025-11-25"}
)

_ERRORS = {
    "MCP_PROTOCOL_UNSUPPORTED": (
        HTTPStatus.BAD_REQUEST,
        "Godot AI requires an initialize-handshake MCP protocol; "
        "use 2025-11-25 or earlier supported revisions.",
        (),
    ),
    "TRANSPORT_AUTH_REQUIRED": (
        HTTPStatus.UNAUTHORIZED,
        "A valid Godot AI transport capability is required.",
        ((b"www-authenticate", b'Bearer realm="godot-ai"'),),
    ),
    "TRANSPORT_OVERLOADED": (
        HTTPStatus.SERVICE_UNAVAILABLE,
        "Godot AI HTTP concurrency limit reached; retry later.",
        ((b"retry-after", b"1"),),
    ),
    "MCP_SESSION_LIMIT_REACHED": (
        HTTPStatus.SERVICE_UNAVAILABLE,
        "Godot AI MCP session limit reached; close or reuse a session.",
        ((b"retry-after", b"1"),),
    ),
    "INVALID_CONTENT_LENGTH": (
        HTTPStatus.BAD_REQUEST,
        "Invalid or ambiguous Content-Length.",
        (),
    ),
    "REQUEST_BODY_TOO_LARGE": (
        HTTPStatus.REQUEST_ENTITY_TOO_LARGE,
        "Request body exceeds its transport limit.",
        (),
    ),
    "REQUEST_BODY_TIMEOUT": (
        HTTPStatus.REQUEST_TIMEOUT,
        "Request body was not received before the deadline.",
        (),
    ),
}


async def _reject(send: Send, code: str) -> None:
    status, message, extra = _ERRORS[code]
    body = json.dumps({"error": {"code": code, "message": message}}, separators=(",", ":")).encode()
    await send(
        {
            "type": "http.response.start",
            "status": status,
            "headers": [
                (b"content-type", b"application/json"),
                (b"content-length", str(len(body)).encode()),
                (b"cache-control", b"no-store"),
                (b"connection", b"close"),
                *extra,
            ],
        }
    )
    await send({"type": "http.response.body", "body": body, "more_body": False})


def _headers(scope: Scope, name: bytes) -> list[bytes]:
    return [value for key, value in scope.get("headers", ()) if key.lower() == name]


class _Wrapper:
    def __init__(self, app: ASGIApp) -> None:
        self.app = app

    def __getattr__(self, name: str) -> Any:
        return getattr(self.app, name)


class CapabilityAuthMiddleware(_Wrapper):
    def __init__(self, app: ASGIApp, capability: str) -> None:
        super().__init__(app)
        self._capability = validate_capability(capability)

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return
        values = _headers(scope, b"authorization")
        supplied = ""
        try:
            scheme, space, supplied = values[0].decode("ascii").partition(" ")
            valid = (
                len(values) == 1
                and space == " "
                and scheme.lower() == "bearer"
                and supplied == supplied.strip()
                and hmac.compare_digest(supplied, self._capability)
            )
        except (IndexError, UnicodeDecodeError):
            valid = False
        if not valid:
            await _reject(send, "TRANSPORT_AUTH_REQUIRED")
            return
        await self.app(scope, receive, send)


class BoundedHTTPMiddleware(_Wrapper):
    def __init__(
        self,
        app: ASGIApp,
        *,
        max_concurrency: int = MAX_HTTP_CONCURRENCY,
        max_body_bytes: int = MAX_HTTP_BODY_BYTES,
        max_lease_body_bytes: int = MAX_LEASE_BODY_BYTES,
        body_timeout_seconds: float = BODY_TIMEOUT_SECONDS,
        max_sessions: int = MAX_MCP_SESSIONS,
        session_idle_seconds: float = MCP_SESSION_IDLE_SECONDS,
    ) -> None:
        limits = (
            max_concurrency,
            max_body_bytes,
            max_lease_body_bytes,
            body_timeout_seconds,
            max_sessions,
            session_idle_seconds,
        )
        if any(value <= 0 for value in limits):
            raise ValueError("HTTP limits must be positive")
        super().__init__(app)
        self.max_concurrency = int(max_concurrency)
        self.max_body_bytes = int(max_body_bytes)
        self.max_lease_body_bytes = int(max_lease_body_bytes)
        self.body_timeout_seconds = float(body_timeout_seconds)
        self.max_sessions = int(max_sessions)
        self.session_idle_seconds = float(session_idle_seconds)
        self._active = self._new_session_reservations = 0

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return
        if scope.get("path") == "/mcp":
            versions = _headers(scope, b"mcp-protocol-version")
            # Sessionless MCP cannot deliver our out-of-request catalog notifications.
            if versions and (len(versions) != 1 or versions[0] not in MCP_HANDSHAKE_VERSIONS):
                await _reject(send, "MCP_PROTOCOL_UNSUPPORTED")
                return
        if self._active >= self.max_concurrency:
            await _reject(send, "TRANSPORT_OVERLOADED")
            return

        manager = self._session_manager() if scope.get("path") == "/mcp" else None
        new_session = manager is not None and not _headers(scope, b"mcp-session-id")
        if manager is not None:
            instances = getattr(manager, "_server_instances", None)
            if not isinstance(instances, dict):
                raise RuntimeError("unsupported FastMCP session manager")
            manager.session_idle_timeout = self.session_idle_seconds
            self._prune_sessions(manager, instances)
            if new_session and len(instances) + self._new_session_reservations >= self.max_sessions:
                await _reject(send, "MCP_SESSION_LIMIT_REACHED")
                return

        self._active += 1
        self._new_session_reservations += int(new_session)
        try:
            replay = await self._bounded_body(scope, receive, send)
            if replay is not None:
                await self.app(scope, replay, send)
        finally:
            self._active -= 1
            self._new_session_reservations -= int(new_session)
            if manager is not None:
                self._prune_sessions(manager, getattr(manager, "_server_instances", {}))

    async def _bounded_body(self, scope: Scope, receive: Receive, send: Send) -> Receive | None:
        limit = (
            self.max_lease_body_bytes
            if str(scope.get("path", "")).startswith("/godot-ai/lease/")
            else self.max_body_bytes
        )
        declared = _headers(scope, b"content-length")
        try:
            raw_length = declared[0].decode("ascii") if len(declared) == 1 else ""
            if len(declared) > 1 or (declared and not raw_length.isdigit()):
                raise ValueError
        except (UnicodeDecodeError, ValueError):
            await _reject(send, "INVALID_CONTENT_LENGTH")
            return None
        if declared:
            normalized_length = raw_length.lstrip("0") or "0"
            limit_text = str(limit)
            if len(normalized_length) > len(limit_text) or (
                len(normalized_length) == len(limit_text)
                and normalized_length > limit_text
            ):
                await _reject(send, "REQUEST_BODY_TOO_LARGE")
                return None

        body = bytearray()
        queued: list[Message] = []
        try:
            async with asyncio.timeout(self.body_timeout_seconds):
                while True:
                    message = await receive()
                    if message["type"] != "http.request":
                        queued.append(message)
                        break
                    chunk = message.get("body", b"")
                    if len(body) + len(chunk) > limit:
                        await _reject(send, "REQUEST_BODY_TOO_LARGE")
                        return None
                    body.extend(chunk)
                    if not message.get("more_body", False):
                        queued.append(
                            {"type": "http.request", "body": bytes(body), "more_body": False}
                        )
                        break
        except TimeoutError:
            await _reject(send, "REQUEST_BODY_TIMEOUT")
            return None

        async def replay() -> Message:
            return queued.pop() if queued else await receive()

        return replay

    def _session_manager(self) -> Any | None:
        pending, seen = [self.app], set()
        while pending:
            current = pending.pop()
            if current is None or id(current) in seen:
                continue
            seen.add(id(current))
            manager = getattr(current, "session_manager", None)
            if manager is not None:
                return manager
            pending.append(getattr(current, "app", None))
            for route in getattr(current, "routes", ()):
                pending.extend((getattr(route, "endpoint", None), getattr(route, "app", None)))
        return None

    @staticmethod
    def _prune_sessions(manager: Any, instances: dict[str, Any]) -> None:
        owners = getattr(manager, "_session_owners", None)
        for session_id, transport in tuple(instances.items()):
            if getattr(transport, "is_terminated", False):
                instances.pop(session_id, None)
                if isinstance(owners, dict):
                    owners.pop(session_id, None)

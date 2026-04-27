"""ASGI factory and dev runner for reloadable HTTP transports."""

from __future__ import annotations

import json
import os
from http import HTTPStatus
from pathlib import Path
from typing import Any

import fastmcp
import uvicorn
from starlette.types import ASGIApp, Message, Receive, Scope, Send

DEV_TRANSPORT_ENV = "GODOT_AI_DEV_TRANSPORT"
DEV_WS_PORT_ENV = "GODOT_AI_DEV_WS_PORT"
DEV_EXCLUDE_DOMAINS_ENV = "GODOT_AI_DEV_EXCLUDE_DOMAINS"
RELOADABLE_TRANSPORTS = {"sse", "streamable-http"}

STALE_MCP_SESSION_MESSAGE = (
    "MCP session expired or was not found; reinitialize the streamable HTTP session"
)
STALE_MCP_SESSION_DATA = {
    "recoverable": True,
    "action": "reinitialize_mcp_session",
    "reason": "stale_streamable_http_session",
}


class StaleMcpSessionDiagnosticMiddleware:
    """Rewrite the SDK's stale streamable-HTTP session error with actionable data.

    The Python MCP SDK rejects unknown/expired ``mcp-session-id`` values in its
    streamable-HTTP session manager before Godot AI's tool handlers run. It
    returns a JSON-RPC 404 with ``error.message == "Session not found"``. Server-
    side resurrection is not safe because the missing ID names transport state
    that was lost with the old manager, but we can preserve the protocol shape
    and add machine-readable recovery guidance for clients/LLMs.
    """

    def __init__(self, app: ASGIApp) -> None:
        self.app = app

    def __getattr__(self, name: str) -> Any:
        """Expose wrapped ASGI app attributes used by FastMCP's runner.

        FastMCP inspects attributes such as ``state`` on the object returned by
        ``http_app()`` before handing it to uvicorn. Keep this middleware
        transparent for those app-level attributes while still intercepting HTTP
        response bodies at call time.
        """
        return getattr(self.app, name)

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        # The SDK only emits "Session not found" when the client sent an
        # mcp-session-id header. Skip buffering for everything else so unrelated
        # HTTP 404s keep their original streaming/timing semantics.
        if scope["type"] != "http" or not _request_has_mcp_session_id(scope):
            await self.app(scope, receive, send)
            return

        start_message: Message | None = None
        body_parts: list[bytes] = []

        async def capture_send(message: Message) -> None:
            nonlocal start_message
            if message["type"] == "http.response.start":
                start_message = dict(message)
                if start_message.get("status") != HTTPStatus.NOT_FOUND:
                    await send(message)
                return
            if message["type"] == "http.response.body":
                if start_message is None or start_message.get("status") != HTTPStatus.NOT_FOUND:
                    await send(message)
                    return
                body_parts.append(message.get("body", b""))
                if message.get("more_body", False):
                    return
                await self._send_response(start_message, b"".join(body_parts), send)
                return
            await send(message)

        await self.app(scope, receive, capture_send)

    async def _send_response(
        self,
        start_message: Message,
        body: bytes,
        send: Send,
    ) -> None:
        rewritten = self._rewrite_stale_session_body(body)
        response_body = rewritten if rewritten is not None else body
        headers = start_message.get("headers", [])
        if rewritten is not None:
            headers = self._headers_without_content_length(headers)
            headers = self._ensure_json_content_type(headers)
        start_message = {**start_message, "headers": headers}
        await send(start_message)
        await send({"type": "http.response.body", "body": response_body, "more_body": False})

    def _rewrite_stale_session_body(self, body: bytes) -> bytes | None:
        try:
            payload = json.loads(body.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            return None
        if not self._is_sdk_session_not_found(payload):
            return None

        payload["error"]["message"] = STALE_MCP_SESSION_MESSAGE
        payload["error"]["data"] = STALE_MCP_SESSION_DATA
        return json.dumps(payload, separators=(",", ":")).encode("utf-8")

    def _is_sdk_session_not_found(self, payload: Any) -> bool:
        # Match on multiple stable SDK signals (code + id + message) to avoid
        # rewriting unrelated JSON-RPC 404s that happen to share one field.
        if not isinstance(payload, dict) or payload.get("jsonrpc") != "2.0":
            return False
        if payload.get("id") != "server-error":
            return False
        error = payload.get("error")
        if not isinstance(error, dict):
            return False
        return error.get("code") == -32600 and error.get("message") == "Session not found"

    def _headers_without_content_length(self, headers: Any) -> list[tuple[bytes, bytes]]:
        return [(key, value) for key, value in headers if key.lower() != b"content-length"]

    def _ensure_json_content_type(
        self,
        headers: list[tuple[bytes, bytes]],
    ) -> list[tuple[bytes, bytes]]:
        if any(key.lower() == b"content-type" for key, _ in headers):
            return headers
        return [*headers, (b"content-type", b"application/json")]


def _request_has_mcp_session_id(scope: Scope) -> bool:
    return any(key.lower() == b"mcp-session-id" for key, _ in scope.get("headers", []))


def _get_dev_transport() -> str:
    transport = os.environ.get(DEV_TRANSPORT_ENV, "streamable-http")
    if transport not in RELOADABLE_TRANSPORTS:
        raise ValueError(f"Unsupported dev transport: {transport}")
    return transport


def _get_dev_ws_port() -> int:
    raw = os.environ.get(DEV_WS_PORT_ENV, "9500")
    try:
        return int(raw)
    except ValueError as exc:
        raise ValueError(f"Invalid {DEV_WS_PORT_ENV}: {raw}") from exc


def create_app():
    """Create the FastMCP ASGI app for uvicorn's reload supervisor."""
    from godot_ai.server import create_server
    from godot_ai.tools.domains import parse_exclude_list

    exclude_domains = parse_exclude_list(os.environ.get(DEV_EXCLUDE_DOMAINS_ENV, ""))
    server = create_server(ws_port=_get_dev_ws_port(), exclude_domains=exclude_domains)
    return server.http_app(transport=_get_dev_transport())


def run_with_reload(
    *,
    transport: str,
    port: int,
    ws_port: int,
    exclude_domains: set[str] | None = None,
) -> None:
    """Run the HTTP transport through uvicorn's supported reload path."""
    if transport not in RELOADABLE_TRANSPORTS:
        raise ValueError(f"Reload is only supported for HTTP transports, got {transport}")

    os.environ[DEV_TRANSPORT_ENV] = transport
    os.environ[DEV_WS_PORT_ENV] = str(ws_port)
    os.environ[DEV_EXCLUDE_DOMAINS_ENV] = ",".join(sorted(exclude_domains or set()))

    src_dir = str(Path(__file__).resolve().parent.parent)
    uvicorn.run(
        "godot_ai.asgi:create_app",
        factory=True,
        host=fastmcp.settings.host,
        port=port,
        log_level=fastmcp.settings.log_level.lower(),
        timeout_graceful_shutdown=2,
        lifespan="on",
        ws="websockets-sansio",
        reload=True,
        reload_dirs=[src_dir],
    )

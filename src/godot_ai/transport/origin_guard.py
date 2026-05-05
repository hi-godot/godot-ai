"""Loopback Host/Origin guard for the WebSocket and HTTP transports.

The WebSocket server binds to ``127.0.0.1`` and the streamable-HTTP
transport likewise. That stops *direct* off-host traffic but does not
stop a browser tab on a malicious origin from mounting **DNS rebinding**:
the browser resolves ``attacker.example.com`` to ``127.0.0.1`` and then
issues ``new WebSocket("ws://attacker.example.com:9500")``. The request
lands on our loopback socket carrying a non-localhost ``Host`` (and
``Origin``) header.

This module enforces a Host/Origin allowlist that rejects those rebound
requests *before* the WebSocket upgrade runs or any HTTP route fires:

- ``Host`` must resolve to one of ``127.0.0.1``, ``localhost`` or
  ``[::1]`` — with an optional ``:port``. RFC 7230 requires bracketed
  form for IPv6 in HTTP/1.1 Host headers, so a bare ``::1`` is not
  accepted (would be a malformed request).
- ``Origin`` is validated only when present (native non-browser clients
  omit it). A present Origin must be empty, the literal ``null`` (file://
  / sandboxed contexts), or a URL whose hostname matches the loopback
  allowlist.

Native clients (the Godot plugin, the FastMCP CLI client, ``curl`` with
no ``-H Origin``) keep working unchanged. Browser-driven traffic from any
non-loopback origin is refused with HTTP 403 long before reaching FastMCP
or our session registry.

See umbrella #343, finding #1 (audit-v2).
"""

from __future__ import annotations

from http import HTTPStatus
from typing import Any
from urllib.parse import urlsplit

from starlette.types import ASGIApp, Receive, Scope, Send

LOOPBACK_HOSTNAMES: frozenset[str] = frozenset({"127.0.0.1", "localhost", "[::1]"})
LOOPBACK_ORIGIN_SCHEMES: frozenset[str] = frozenset({"http", "https", "ws", "wss"})

FORBIDDEN_BODY = (
    b"forbidden: non-loopback Host or Origin (DNS rebinding guard)\n"
    b"see https://github.com/hi-godot/godot-ai issue #345 for details\n"
)


def _strip_port(host: str) -> str:
    """Return ``host`` with a trailing ``:port`` stripped.

    Handles bracketed IPv6 (``[::1]:9500`` → ``[::1]``) and bare-name
    forms (``localhost:8000`` → ``localhost``).
    """
    if not host:
        return host
    if host.startswith("[") and "]" in host:
        return host[: host.index("]") + 1]
    return host.split(":", 1)[0]


def is_allowed_host(host_header: str | None) -> bool:
    """Whether ``host_header`` resolves to a loopback name.

    Empty or missing returns False — a properly formed HTTP/1.1 request
    always carries a Host header, and refusing the request is safer than
    guessing. The WebSocket guard mirrors this.
    """
    if not host_header:
        return False
    return _strip_port(host_header.strip()).lower() in LOOPBACK_HOSTNAMES


def is_allowed_origin(origin_header: str | None) -> bool:
    """Whether ``origin_header`` is absent or names a loopback URL.

    Native clients do not send Origin. Browsers always do, and sandboxed
    or file:// contexts send ``Origin: null``. Both are accepted; any
    other origin must parse to a URL whose hostname is loopback.
    """
    if origin_header is None:
        return True
    value = origin_header.strip()
    if not value or value.lower() == "null":
        return True
    parsed = urlsplit(value)
    if parsed.scheme.lower() not in LOOPBACK_ORIGIN_SCHEMES:
        return False
    if not parsed.hostname:
        return False
    hostname = parsed.hostname.lower()
    # urlsplit strips IPv6 brackets — re-add for the bracketed-form lookup.
    bracketed = f"[{hostname}]" if ":" in hostname else hostname
    return hostname in LOOPBACK_HOSTNAMES or bracketed in LOOPBACK_HOSTNAMES


class LocalhostOnlyHTTPMiddleware:
    """ASGI middleware that rejects HTTP requests off the loopback allowlist.

    Wraps the FastMCP ASGI app so the guard runs *before* the MCP
    streamable-HTTP session manager, before ``/godot-ai/status``, and
    before any inner middleware. Non-HTTP scopes (lifespan) pass through.
    """

    def __init__(self, app: ASGIApp) -> None:
        self.app = app

    def __getattr__(self, name: str) -> Any:
        # Mirror StaleMcpSessionDiagnosticMiddleware: FastMCP / uvicorn
        # introspect attributes (e.g. ``state``) on the wrapped ASGI app.
        return getattr(self.app, name)

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return

        host_count = 0
        origin_count = 0
        host: str | None = None
        origin: str | None = None
        for raw_key, raw_value in scope.get("headers", []):
            key = raw_key.lower()
            if key == b"host":
                host_count += 1
                host = raw_value.decode("latin-1")
            elif key == b"origin":
                origin_count += 1
                origin = raw_value.decode("latin-1")

        ## Duplicate Host or Origin headers fail closed: a single request
        ## carrying both a loopback and a non-loopback value is ambiguous,
        ## a classic HTTP smuggling shape, and never legitimate for our
        ## clients.
        if host_count > 1 or origin_count > 1:
            await _send_forbidden(send)
            return

        if is_allowed_host(host) and is_allowed_origin(origin):
            await self.app(scope, receive, send)
            return

        await _send_forbidden(send)


async def _send_forbidden(send: Send) -> None:
    await send(
        {
            "type": "http.response.start",
            "status": HTTPStatus.FORBIDDEN,
            "headers": [
                (b"content-type", b"text/plain; charset=utf-8"),
                (b"content-length", str(len(FORBIDDEN_BODY)).encode("ascii")),
            ],
        }
    )
    await send({"type": "http.response.body", "body": FORBIDDEN_BODY, "more_body": False})


def make_websocket_request_guard():
    """Return a ``process_request`` hook for ``websockets.asyncio.server.serve``.

    The hook fires before the WebSocket upgrade. When Host or Origin
    fails the loopback allowlist the hook synthesizes an HTTP 403 via
    ``connection.respond(...)``; returning that response from
    ``process_request`` aborts the upgrade without ever creating a
    Session.
    """

    async def guard(connection, request):
        ## Use ``get_all`` so a smuggled duplicate (two ``Host:`` lines)
        ## fails closed rather than tripping ``MultipleValuesError`` at
        ## ``request.headers.get(...)`` and surfacing as an opaque 500.
        hosts = request.headers.get_all("Host")
        origins = request.headers.get_all("Origin")
        if len(hosts) > 1 or len(origins) > 1:
            return connection.respond(
                HTTPStatus.FORBIDDEN,
                FORBIDDEN_BODY.decode("utf-8"),
            )
        host = hosts[0] if hosts else None
        origin = origins[0] if origins else None
        if is_allowed_host(host) and is_allowed_origin(origin):
            return None
        return connection.respond(
            HTTPStatus.FORBIDDEN,
            FORBIDDEN_BODY.decode("utf-8"),
        )

    return guard

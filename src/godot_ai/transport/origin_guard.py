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
  omit it). A present Origin must be empty or a URL whose hostname
  matches the loopback allowlist. ``Origin: null`` is **rejected** —
  browsers emit it from sandboxed iframes and downloaded ``file://``
  pages, which is exactly the rebinding-bypass shape. Native clients
  do not produce ``null`` (they omit Origin entirely).
- ``Sec-Fetch-Site`` is also checked when present: any value other than
  ``same-origin`` / ``none`` (i.e. browser-issued cross-origin
  subresources or navigations from a foreign page) is refused. This
  catches `<img src=...>` / `<link>` / `<script>` liveness oracles
  against ``/godot-ai/status``, where browsers send a loopback ``Host``
  and *no* ``Origin`` for "no-cors" subresource loads. Native clients
  never send ``Sec-Fetch-*`` (it's a Fetch-Metadata header set only by
  browsers), so missing means "allow".

Native clients (the Godot plugin, the FastMCP CLI client, ``curl`` with
no ``-H Origin``) keep working unchanged. Browser-driven traffic — even
``no-cors`` subresources that wouldn't carry an Origin — is refused with
HTTP 403 long before reaching FastMCP or our session registry.

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
FORBIDDEN_BODY_TEXT = FORBIDDEN_BODY.decode("utf-8")


## Sec-Fetch-Site values that indicate the request is browser-driven and
## NOT a top-level navigation or same-origin operation. Modern browsers
## always send Sec-Fetch-Site on HTTP requests (including ``no-cors``
## subresources like ``<img>`` / ``<script>`` / ``<link>`` that carry
## *no* Origin); native non-browser clients never send it.
SEC_FETCH_SITE_FOREIGN: frozenset[str] = frozenset({"cross-site", "same-site"})


def _normalise_host(host: str) -> str:
    """Return ``host`` with a trailing ``:port`` stripped, lowercased,
    and with any single trailing DNS root dot removed.

    Handles bracketed IPv6 (``[::1]:9500`` → ``[::1]``), bare-name forms
    (``LOCALHOST:8000`` → ``localhost``), and the rare-but-valid trailing
    dot (``localhost.`` → ``localhost``) so the allowlist lookup is
    independent of caller punctuation.
    """
    if not host:
        return host
    if host.startswith("[") and "]" in host:
        without_port = host[: host.index("]") + 1]
    else:
        without_port = host.split(":", 1)[0]
    normalised = without_port.lower()
    if normalised.endswith(".") and not normalised.endswith(".]"):
        normalised = normalised.rstrip(".")
    return normalised


def is_allowed_host(host_header: str | None) -> bool:
    """Whether ``host_header`` resolves to a loopback name.

    Empty or missing returns False — a properly formed HTTP/1.1 request
    always carries a Host header, and refusing the request is safer than
    guessing. The WebSocket guard mirrors this.
    """
    if not host_header:
        return False
    return _normalise_host(host_header.strip()) in LOOPBACK_HOSTNAMES


def is_allowed_origin(origin_header: str | None) -> bool:
    """Whether ``origin_header`` is absent or names a loopback URL.

    Native clients do not send Origin. Browsers always do, and the
    request is rejected unless the Origin parses to a loopback URL.
    ``Origin: null`` is rejected — sandboxed iframes and downloaded
    ``file://`` pages emit it, which is the exact bypass an attacker
    would use to bridge a foreign origin onto our loopback socket.
    """
    if origin_header is None:
        return True
    value = origin_header.strip()
    if not value:
        return True
    if value.lower() == "null":
        return False
    parsed = urlsplit(value)
    ## ``urlsplit`` already lowercases the scheme per RFC 3986, so no
    ## extra normalization is needed before the set lookup.
    if parsed.scheme not in LOOPBACK_ORIGIN_SCHEMES:
        return False
    if not parsed.hostname:
        return False
    hostname = parsed.hostname.lower().rstrip(".")
    # urlsplit strips IPv6 brackets — re-add for the bracketed-form lookup.
    bracketed = f"[{hostname}]" if ":" in hostname else hostname
    return hostname in LOOPBACK_HOSTNAMES or bracketed in LOOPBACK_HOSTNAMES


def is_allowed_sec_fetch_site(value: str | None) -> bool:
    """Whether the ``Sec-Fetch-Site`` header indicates a non-foreign request.

    Modern browsers stamp every HTTP request with one of ``cross-site``,
    ``same-site``, ``same-origin`` or ``none`` (top-level navigation /
    bookmark). Native clients never send it. Treat missing as "allow"
    (native client) and the foreign values as "reject" — the rest of the
    allowlist still has to pass, this is just an early-out for the
    `<img src=...>` / `<script src=...>` cross-origin probe shape that
    would otherwise slip past a loopback Host / missing Origin.
    """
    if value is None:
        return True
    return value.strip().lower() not in SEC_FETCH_SITE_FOREIGN


def evaluate_loopback(
    hosts: list[str],
    origins: list[str],
    sec_fetch_sites: list[str] | None = None,
) -> bool:
    """Return True iff the request's headers pass the allowlist.

    Both transports (ASGI middleware + WebSocket ``process_request``)
    funnel their per-request header extraction through this helper so
    the duplicate-header smuggling rule, the value-allowlist rule, and
    the Sec-Fetch-Site cross-origin reject rule are evaluated identically.
    A divergence between the two transports would be a security
    regression — this helper exists to prevent it.
    """
    if len(hosts) > 1 or len(origins) > 1:
        return False
    if sec_fetch_sites and len(sec_fetch_sites) > 1:
        return False
    host = hosts[0] if hosts else None
    origin = origins[0] if origins else None
    sec_fetch_site = sec_fetch_sites[0] if sec_fetch_sites else None
    return (
        is_allowed_host(host)
        and is_allowed_origin(origin)
        and is_allowed_sec_fetch_site(sec_fetch_site)
    )


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

        hosts: list[str] = []
        origins: list[str] = []
        sec_fetch_sites: list[str] = []
        for raw_key, raw_value in scope.get("headers", []):
            key = raw_key.lower()
            if key == b"host":
                hosts.append(raw_value.decode("latin-1"))
            elif key == b"origin":
                origins.append(raw_value.decode("latin-1"))
            elif key == b"sec-fetch-site":
                sec_fetch_sites.append(raw_value.decode("latin-1"))

        if evaluate_loopback(hosts, origins, sec_fetch_sites):
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
        hosts = list(request.headers.get_all("Host"))
        origins = list(request.headers.get_all("Origin"))
        sec_fetch_sites = list(request.headers.get_all("Sec-Fetch-Site"))
        if evaluate_loopback(hosts, origins, sec_fetch_sites):
            return None
        return connection.respond(HTTPStatus.FORBIDDEN, FORBIDDEN_BODY_TEXT)

    return guard

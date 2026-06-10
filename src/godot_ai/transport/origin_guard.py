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

When the ``--allow-host`` opt-in (#421) binds the transport off loopback,
the **real socket peer** (``scope["client"]`` / ``remote_address``) is the
authoritative LAN gate — see :func:`peer_ip_allowed`. The ``Host`` header
is client-controlled, so a peer outside the allowed range could otherwise
pass the range check by spoofing ``Host: <an-allowed-ip>``; gating on the
unforgeable peer address closes that. In the default loopback-only mode the
peer gate is a pass-through and behavior is byte-for-byte unchanged.

See umbrella #343, finding #1 (audit-v2).
"""

from __future__ import annotations

import ipaddress
from collections.abc import Iterable, Sequence
from http import HTTPStatus
from typing import Any
from urllib.parse import urlsplit

from starlette.types import ASGIApp, Receive, Scope, Send

IPNetwork = ipaddress.IPv4Network | ipaddress.IPv6Network

LOOPBACK_HOSTNAMES: frozenset[str] = frozenset({"127.0.0.1", "localhost", "[::1]"})
LOOPBACK_ORIGIN_SCHEMES: frozenset[str] = frozenset({"http", "https", "ws", "wss"})

FORBIDDEN_BODY = (
    b"forbidden: peer, Host, or Origin not permitted (DNS rebinding / --allow-host guard)\n"
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


def parse_allow_hosts(values: Iterable[str]) -> list[IPNetwork]:
    """Parse ``--allow-host`` CLI values into IP networks (issue #421).

    Each value may be a CIDR (``192.168.1.0/24``), a bare IP
    (``192.168.1.50`` → a /32 or /128), or a comma-separated list of
    either. ``host_bits`` set on a CIDR are tolerated (``strict=False``)
    so ``192.168.1.5/24`` is accepted as ``192.168.1.0/24``. Raises
    ``ValueError`` (with the offending token) on anything unparseable so
    a typo fails loudly at startup instead of silently exposing nothing.
    """
    networks: list[IPNetwork] = []
    for raw in values:
        for token in str(raw).split(","):
            token = token.strip()
            if not token:
                continue
            try:
                networks.append(ipaddress.ip_network(token, strict=False))
            except ValueError as exc:
                raise ValueError(f"invalid --allow-host value {token!r}: {exc}") from exc
    return networks


def bind_host_for_networks(networks: Sequence[IPNetwork] | None) -> str | None:
    """HTTP bind address that exposes the transport to ``networks`` (issue #421).

    Returns ``None`` when no networks are named so the caller keeps its
    loopback default (the byte-for-byte unchanged path).

    Otherwise **prioritizes IPv4 reachability**: if the allowlist contains
    *any* IPv4 network we bind ``"0.0.0.0"`` (IPv4 all-interfaces, reachable
    on every platform), and only bind ``"::"`` when the allowlist is
    *exclusively* IPv6. This avoids the non-portable assumption that ``"::"``
    yields a dual-stack listener — it does on Linux (``bindv6only=0``) but
    sockets are IPv6-only by default on Windows, where binding ``"::"`` would
    make an IPv4 range in the allowlist unreachable. The trade-off: an
    allowlist that *mixes* IPv4 and IPv6 is served over IPv4 only (its IPv6
    ranges won't be reachable over IPv6). That's the safe default — LAN MCP is
    overwhelmingly IPv4, and IPv4 reachability is preserved everywhere. A
    dual-stack / separate-listener setup for mixed allowlists can come later
    if needed.
    """
    if not networks:
        return None
    if any(isinstance(net, ipaddress.IPv4Network) for net in networks):
        return "0.0.0.0"  # noqa: S104 — opt-in; the guard still gates every request
    return "::"  # noqa: S104 — allowlist is IPv6-only, no IPv4 to serve


def _host_ip_in_networks(host_header: str, networks: Sequence[IPNetwork] | None) -> bool:
    """Whether the Host header's IP literal falls inside one of ``networks``.

    Only IP literals match — a DNS name (the shape a rebinding attack
    presents) never parses to an address, so it can't slip into an
    allowed network. Bracketed IPv6 (``[192.168..]`` form) is unwrapped
    by ``_normalise_host`` first.
    """
    if not networks:
        return False
    candidate = _normalise_host(host_header.strip())
    if candidate.startswith("[") and candidate.endswith("]"):
        candidate = candidate[1:-1]
    try:
        ip = ipaddress.ip_address(candidate)
    except ValueError:
        return False
    return any(ip in net for net in networks)


def peer_ip_allowed(peer_ip: str | None, allowed_networks: Sequence[IPNetwork] | None) -> bool:
    """Whether the real TCP peer address is permitted to reach the transport.

    This is the authoritative LAN gate. The ``Host`` header is
    client-controlled — a peer outside an allowed network can spoof
    ``Host: <an-allowed-ip>`` and pass :func:`is_allowed_host` — so when
    the transport is bound off loopback (the ``--allow-host`` opt-in, #421)
    the *socket peer* (``scope["client"]`` for ASGI, ``remote_address`` for
    the WebSocket server), which the client cannot forge, must itself be
    loopback or fall inside an allowed network.

    With no allowlist (the default), the transport stays bound to loopback,
    so the kernel already guarantees a loopback peer and this is a
    pass-through that keeps the original behavior byte-for-byte — including
    contexts (e.g. unit scopes) where the peer address isn't populated.
    When an allowlist *is* set but the peer can't be determined, it fails
    closed: better to refuse than to fall back to the spoofable header.
    """
    if not allowed_networks:
        return True
    if not peer_ip:
        return False
    ## Strip an IPv6 zone id (``fe80::1%eth0``) before parsing.
    candidate = peer_ip.split("%", 1)[0].strip()
    try:
        ip = ipaddress.ip_address(candidate)
    except ValueError:
        return False
    ## A dual-stack listener can report an IPv4 peer in IPv4-mapped IPv6 form
    ## (``::ffff:127.0.0.1``), whose ``.is_loopback`` is False and which never
    ## matches an IPv4 allowlist network. Unwrap it to the real IPv4 address so
    ## a genuine loopback / in-network peer isn't wrongly rejected.
    if isinstance(ip, ipaddress.IPv6Address) and ip.ipv4_mapped is not None:
        ip = ip.ipv4_mapped
    if ip.is_loopback:
        return True
    return any(ip in net for net in allowed_networks)


def is_allowed_host(
    host_header: str | None,
    allowed_networks: Sequence[IPNetwork] | None = None,
) -> bool:
    """Whether ``host_header`` resolves to a loopback name (or an allowed LAN IP).

    Empty or missing returns False — a properly formed HTTP/1.1 request
    always carries a Host header, and refusing the request is safer than
    guessing. The WebSocket guard mirrors this.

    When ``allowed_networks`` is supplied (the ``--allow-host`` opt-in,
    #421), a Host header whose IP literal falls inside one of those
    networks is also accepted. ``allowed_networks=None`` (the default)
    is byte-for-byte the original loopback-only behavior.
    """
    if not host_header:
        return False
    if _normalise_host(host_header.strip()) in LOOPBACK_HOSTNAMES:
        return True
    return _host_ip_in_networks(host_header, allowed_networks)


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
    allowed_networks: Sequence[IPNetwork] | None = None,
    peer_ip: str | None = None,
) -> bool:
    """Return True iff the request passes the allowlist.

    Both transports (ASGI middleware + WebSocket ``process_request``)
    funnel their per-request extraction through this helper so the
    duplicate-header smuggling rule, the value-allowlist rule, the
    Sec-Fetch-Site cross-origin reject rule, and the peer-address gate are
    evaluated identically. A divergence between the two transports would be
    a security regression — this helper exists to prevent it.

    ``allowed_networks`` (the ``--allow-host`` opt-in, #421) widens access
    to named LAN CIDRs. Authorization is anchored on ``peer_ip`` — the real
    socket peer, which the client cannot forge — not on the ``Host`` header
    (which it can). The Host header is still range-checked, but only as a
    secondary filter; the peer gate is what actually keeps out-of-range
    hosts off the server. The Origin and Sec-Fetch-Site rules are left
    untouched: a browser on the LAN sends a non-loopback Origin (rejected)
    and a foreign Sec-Fetch-Site (rejected), so DNS-rebinding defense
    survives the opt-in. A native remote agent sends neither header, so it
    passes once both its peer address and Host IP are allowed.

    When ``allowed_networks`` is None (the loopback-only default), the peer
    gate is a pass-through and behavior is byte-for-byte unchanged.
    """
    if len(hosts) > 1 or len(origins) > 1:
        return False
    if sec_fetch_sites and len(sec_fetch_sites) > 1:
        return False
    host = hosts[0] if hosts else None
    origin = origins[0] if origins else None
    sec_fetch_site = sec_fetch_sites[0] if sec_fetch_sites else None
    return (
        peer_ip_allowed(peer_ip, allowed_networks)
        and is_allowed_host(host, allowed_networks)
        and is_allowed_origin(origin)
        and is_allowed_sec_fetch_site(sec_fetch_site)
    )


class LocalhostOnlyHTTPMiddleware:
    """ASGI middleware that rejects HTTP requests off the loopback allowlist.

    Wraps the FastMCP ASGI app so the guard runs *before* the MCP
    streamable-HTTP session manager, before ``/godot-ai/status``, and
    before any inner middleware. Non-HTTP scopes (lifespan) pass through.
    """

    def __init__(
        self,
        app: ASGIApp,
        allowed_networks: Sequence[IPNetwork] | None = None,
    ) -> None:
        self.app = app
        # #421: empty/None keeps the loopback-only behavior byte-for-byte.
        self.allowed_networks = list(allowed_networks) if allowed_networks else None

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

        ## ASGI populates ``scope["client"]`` with the real ``(host, port)``
        ## peer — unforgeable, unlike the Host header. ``None`` in unusual
        ## servers; the peer gate fails closed for it only when opted in.
        client = scope.get("client")
        peer_ip = client[0] if client else None

        if evaluate_loopback(hosts, origins, sec_fetch_sites, self.allowed_networks, peer_ip):
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


def make_websocket_request_guard(allowed_networks: Sequence[IPNetwork] | None = None):
    """Return a ``process_request`` hook for ``websockets.asyncio.server.serve``.

    The hook fires before the WebSocket upgrade. When the real peer
    address, Host, or Origin fails the allowlist the hook synthesizes an
    HTTP 403 via ``connection.respond(...)``; returning that response from
    ``process_request`` aborts the upgrade without ever creating a Session.

    ``allowed_networks`` (the ``--allow-host`` opt-in, #421) gates the
    unforgeable peer address (``remote_address``) and widens the Host
    allowlist identically to the HTTP middleware, so the two transports
    never diverge.
    """
    networks = list(allowed_networks) if allowed_networks else None

    async def guard(connection, request):
        ## Use ``get_all`` so a smuggled duplicate (two ``Host:`` lines)
        ## fails closed rather than tripping ``MultipleValuesError`` at
        ## ``request.headers.get(...)`` and surfacing as an opaque 500.
        hosts = list(request.headers.get_all("Host"))
        origins = list(request.headers.get_all("Origin"))
        sec_fetch_sites = list(request.headers.get_all("Sec-Fetch-Site"))
        ## ``remote_address`` is the real TCP peer (set before the HTTP
        ## upgrade) — unforgeable, unlike the Host header. It's a
        ## ``(host, port[, flowinfo, scopeid])`` tuple, or None if the
        ## socket is already gone; the peer gate fails closed for None
        ## only when opted in.
        remote = getattr(connection, "remote_address", None)
        peer_ip = remote[0] if remote else None
        if evaluate_loopback(hosts, origins, sec_fetch_sites, networks, peer_ip):
            return None
        return connection.respond(HTTPStatus.FORBIDDEN, FORBIDDEN_BODY_TEXT)

    return guard

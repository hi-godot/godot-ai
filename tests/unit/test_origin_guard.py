"""Loopback Host/Origin guard — DNS-rebinding mitigation (audit-v2 #1, #345).

Covers the pure helpers in ``godot_ai.transport.origin_guard`` and the
ASGI middleware surface. The WebSocket-server side is exercised in
``tests/integration/test_websocket.py`` against a live ``websockets``
server because the upgrade path runs inside the library, not in our
code.
"""

from __future__ import annotations

import pytest

from godot_ai.transport.origin_guard import (
    LocalhostOnlyHTTPMiddleware,
    bind_host_for_networks,
    evaluate_loopback,
    is_allowed_host,
    is_allowed_origin,
    is_allowed_sec_fetch_site,
    parse_allow_hosts,
    peer_ip_allowed,
)

# ---------------------------------------------------------------------------
# is_allowed_host
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "host",
    [
        "127.0.0.1",
        "127.0.0.1:9500",
        "localhost",
        "localhost:8000",
        "LOCALHOST",  # case-insensitive
        "[::1]",
        "[::1]:9500",
        # RFC-1034-valid trailing-dot FQDN syntax — browsers and curl can
        # preserve it through to the Host header. Friction trap if rejected.
        "localhost.",
        "localhost.:8000",
        "127.0.0.1.",
    ],
)
def test_loopback_hosts_pass(host: str) -> None:
    assert is_allowed_host(host) is True


def test_bare_unbracketed_ipv6_loopback_rejected() -> None:
    """RFC 7230 requires IPv6 in brackets in the HTTP Host header. A
    bare ``::1`` would be a malformed request and is not on the
    allowlist — only the bracketed form ``[::1]`` is accepted."""
    assert is_allowed_host("::1") is False


@pytest.mark.parametrize(
    "host",
    [
        # The classic DNS-rebinding shape: attacker tricks the browser into
        # resolving their domain to 127.0.0.1, browser sends ``Host: <domain>``.
        "attacker.example.com",
        "attacker.example.com:9500",
        "192.168.1.50",
        "10.0.0.1:8000",
        # Public DNS names that *resolve* to 127.0.0.1 but don't *match* it.
        "godot-ai.test",
        "rebound.local:9500",
        # Empty / missing → reject; well-formed HTTP carries a Host.
        "",
        None,
        "   ",
        # Sneaky-looking but non-loopback.
        "127.0.0.1.attacker.example.com",
        "localhost.evil.example.com",
    ],
)
def test_non_loopback_hosts_rejected(host) -> None:
    assert is_allowed_host(host) is False


# ---------------------------------------------------------------------------
# is_allowed_origin
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "origin",
    [
        # Native plugin / CLI clients omit Origin entirely — must pass.
        None,
        "",
        "   ",
        # Loopback origins are allowed for tooling that explicitly opts in.
        "http://127.0.0.1",
        "http://127.0.0.1:9500",
        "http://localhost",
        "http://localhost:8000",
        "https://localhost:8443",
        "ws://127.0.0.1:9500",
        "wss://localhost:8443",
        "http://[::1]",
        "http://[::1]:9500",
        # Trailing-dot FQDN form — accepted alongside the canonical name.
        "http://localhost.",
        "http://localhost.:8000",
    ],
)
def test_loopback_origins_pass(origin) -> None:
    assert is_allowed_origin(origin) is True


@pytest.mark.parametrize("null_origin", ["null", "NULL", " null ", "Null"])
def test_origin_null_rejected(null_origin: str) -> None:
    """``Origin: null`` is the bypass shape — sandboxed iframes and
    downloaded ``file://`` pages emit it and would otherwise let an
    attacker bridge a foreign origin onto the loopback socket. Native
    clients never produce ``null`` (they omit Origin entirely)."""
    assert is_allowed_origin(null_origin) is False


@pytest.mark.parametrize(
    "origin",
    [
        # The DNS-rebinding shape: browser-driven Origin is the attacker's domain.
        "https://attacker.example.com",
        "http://attacker.example.com:9500",
        "https://godot-ai.test",
        # Schemes outside the HTTP/WS family — refuse rather than guess.
        "file:///home/user/index.html",
        "data:text/html;base64,PHNjcmlwdD4=",
        "chrome-extension://abc",
        # IP that isn't loopback.
        "http://192.168.1.50",
        # Looks-like-loopback substring but is actually a foreign host.
        "http://localhost.evil.example.com",
        "http://127.0.0.1.evil.example.com",
        # Malformed origin: scheme present but no hostname.
        "http://",
    ],
)
def test_non_loopback_origins_rejected(origin: str) -> None:
    assert is_allowed_origin(origin) is False


# ---------------------------------------------------------------------------
# is_allowed_sec_fetch_site — block browser cross-origin probes
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "value",
    [
        # Native non-browser clients never send Sec-Fetch-Site.
        None,
        # Top-level navigation (user typed URL / clicked bookmark).
        "none",
        # Same-origin fetch (e.g. our own /godot-ai/status from a loopback
        # browser context).
        "same-origin",
        # Case insensitivity per spec.
        "None",
        "Same-Origin",
        # Whitespace tolerance.
        " none ",
    ],
)
def test_sec_fetch_site_friendly_values_pass(value) -> None:
    assert is_allowed_sec_fetch_site(value) is True


@pytest.mark.parametrize(
    "value",
    [
        # Cross-origin subresource load (`<img src="http://127.0.0.1...">`
        # from a foreign page) — reject.
        "cross-site",
        "CROSS-SITE",
        # Same-site cross-origin — also reject; the request is still
        # browser-driven from a different origin (different port/scheme).
        "same-site",
    ],
)
def test_sec_fetch_site_foreign_values_rejected(value: str) -> None:
    assert is_allowed_sec_fetch_site(value) is False


# ---------------------------------------------------------------------------
# evaluate_loopback — combined gate
# ---------------------------------------------------------------------------


def test_evaluate_loopback_native_client() -> None:
    """No Origin, no Sec-Fetch-Site, loopback Host — native client path."""
    assert evaluate_loopback(["127.0.0.1:9500"], [], []) is True


def test_evaluate_loopback_loopback_browser_passes() -> None:
    """Browser pointed at our own loopback origin still passes."""
    assert (
        evaluate_loopback(
            ["127.0.0.1:9500"],
            ["http://127.0.0.1:9500"],
            ["same-origin"],
        )
        is True
    )


def test_evaluate_loopback_cross_site_subresource_rejected() -> None:
    """The Copilot-flagged liveness oracle: cross-origin <img> hits our
    /godot-ai/status with a loopback Host and *no* Origin (no-cors mode).
    Sec-Fetch-Site is the giveaway."""
    assert (
        evaluate_loopback(
            ["127.0.0.1:9500"],
            [],
            ["cross-site"],
        )
        is False
    )


def test_evaluate_loopback_origin_null_rejected() -> None:
    """Sandboxed iframe / file:// page emit ``Origin: null`` — reject."""
    assert (
        evaluate_loopback(
            ["127.0.0.1:9500"],
            ["null"],
            ["cross-site"],
        )
        is False
    )


# ---------------------------------------------------------------------------
# LocalhostOnlyHTTPMiddleware (ASGI scope shape)
# ---------------------------------------------------------------------------


async def _call_middleware(
    middleware: LocalhostOnlyHTTPMiddleware,
    *,
    headers: list[tuple[bytes, bytes]],
    scope_type: str = "http",
    client: tuple[str, int] | None = None,
) -> tuple[list[dict], bool]:
    """Run the middleware against a synthetic scope; return (sent, inner_called).

    ``client`` populates ASGI's ``scope["client"]`` (the real ``(host, port)``
    peer). Omitted by default so loopback-only tests don't need it — the peer
    gate is a pass-through unless ``allowed_networks`` is set.
    """
    inner_called = False

    async def inner(scope, receive, send):
        nonlocal inner_called
        inner_called = True
        await send({"type": "http.response.start", "status": 200, "headers": []})
        await send({"type": "http.response.body", "body": b"ok", "more_body": False})

    middleware.app = inner  # type: ignore[assignment]
    sent: list[dict] = []

    async def send(message):
        sent.append(message)

    async def receive():
        return {"type": "http.request", "body": b"", "more_body": False}

    scope = {"type": scope_type, "method": "GET", "path": "/x", "headers": headers}
    if client is not None:
        scope["client"] = client
    await middleware(scope, receive, send)
    return sent, inner_called


async def test_middleware_passes_loopback_request_through() -> None:
    middleware = LocalhostOnlyHTTPMiddleware(app=None)  # type: ignore[arg-type]
    sent, inner_called = await _call_middleware(
        middleware,
        headers=[(b"host", b"127.0.0.1:8000")],
    )
    assert inner_called is True
    assert sent[0]["status"] == 200


async def test_middleware_rejects_non_loopback_host() -> None:
    middleware = LocalhostOnlyHTTPMiddleware(app=None)  # type: ignore[arg-type]
    sent, inner_called = await _call_middleware(
        middleware,
        headers=[(b"host", b"attacker.example.com:8000")],
    )
    assert inner_called is False, "inner app must not run for rejected requests"
    assert sent[0]["type"] == "http.response.start"
    assert sent[0]["status"] == 403


async def test_middleware_rejects_browser_origin_with_loopback_host() -> None:
    """The DNS-rebinding fingerprint: browser sends Origin even when the
    Host happened to resolve to loopback. Reject on Origin alone."""
    middleware = LocalhostOnlyHTTPMiddleware(app=None)  # type: ignore[arg-type]
    sent, inner_called = await _call_middleware(
        middleware,
        headers=[
            (b"host", b"127.0.0.1:8000"),
            (b"origin", b"https://attacker.example.com"),
        ],
    )
    assert inner_called is False
    assert sent[0]["status"] == 403


async def test_middleware_passes_loopback_origin_with_loopback_host() -> None:
    middleware = LocalhostOnlyHTTPMiddleware(app=None)  # type: ignore[arg-type]
    sent, inner_called = await _call_middleware(
        middleware,
        headers=[
            (b"host", b"localhost:8000"),
            (b"origin", b"http://localhost:8000"),
        ],
    )
    assert inner_called is True
    assert sent[0]["status"] == 200


async def test_middleware_rejects_missing_host() -> None:
    middleware = LocalhostOnlyHTTPMiddleware(app=None)  # type: ignore[arg-type]
    sent, inner_called = await _call_middleware(middleware, headers=[])
    assert inner_called is False
    assert sent[0]["status"] == 403


async def test_middleware_passes_lifespan_scope_through() -> None:
    """Non-HTTP scopes (lifespan, websocket) must not be filtered — only
    the HTTP path carries the Host/Origin headers we guard."""
    middleware = LocalhostOnlyHTTPMiddleware(app=None)  # type: ignore[arg-type]
    inner_called = False

    async def inner(scope, receive, send):
        nonlocal inner_called
        inner_called = True

    middleware.app = inner  # type: ignore[assignment]

    async def send(message):
        pass

    async def receive():
        return {"type": "lifespan.startup"}

    await middleware({"type": "lifespan"}, receive, send)
    assert inner_called is True


async def test_middleware_response_body_explains_dns_rebinding() -> None:
    middleware = LocalhostOnlyHTTPMiddleware(app=None)  # type: ignore[arg-type]
    sent, _ = await _call_middleware(
        middleware,
        headers=[(b"host", b"attacker.example.com")],
    )
    body = sent[1]["body"]
    assert b"forbidden" in body.lower()
    assert b"DNS rebinding" in body or b"dns rebinding" in body.lower()


async def test_middleware_rejects_duplicate_host_smuggle() -> None:
    """HTTP smuggling shape: two Host headers, one loopback and one not.
    The guard must fail closed regardless of which one is "correct"."""
    middleware = LocalhostOnlyHTTPMiddleware(app=None)  # type: ignore[arg-type]
    sent, inner_called = await _call_middleware(
        middleware,
        headers=[
            (b"host", b"127.0.0.1"),
            (b"host", b"attacker.example.com"),
        ],
    )
    assert inner_called is False
    assert sent[0]["status"] == 403


async def test_middleware_rejects_origin_null() -> None:
    """A sandboxed iframe / file:// page hitting our loopback socket
    sends ``Origin: null`` — must be rejected even though the Host
    looks loopback."""
    middleware = LocalhostOnlyHTTPMiddleware(app=None)  # type: ignore[arg-type]
    sent, inner_called = await _call_middleware(
        middleware,
        headers=[
            (b"host", b"127.0.0.1:8000"),
            (b"origin", b"null"),
        ],
    )
    assert inner_called is False
    assert sent[0]["status"] == 403


async def test_middleware_rejects_cross_origin_subresource() -> None:
    """The /godot-ai/status liveness-oracle shape Copilot flagged: a
    cross-origin <img> / <script> load arrives with a loopback Host
    and *no* Origin (no-cors mode) — but Sec-Fetch-Site reveals it."""
    middleware = LocalhostOnlyHTTPMiddleware(app=None)  # type: ignore[arg-type]
    sent, inner_called = await _call_middleware(
        middleware,
        headers=[
            (b"host", b"127.0.0.1:8000"),
            (b"sec-fetch-site", b"cross-site"),
        ],
    )
    assert inner_called is False
    assert sent[0]["status"] == 403


async def test_middleware_passes_top_level_navigation() -> None:
    """User typed URL / clicked bookmark — Sec-Fetch-Site: none."""
    middleware = LocalhostOnlyHTTPMiddleware(app=None)  # type: ignore[arg-type]
    sent, inner_called = await _call_middleware(
        middleware,
        headers=[
            (b"host", b"127.0.0.1:8000"),
            (b"sec-fetch-site", b"none"),
        ],
    )
    assert inner_called is True
    assert sent[0]["status"] == 200


async def test_middleware_rejects_duplicate_origin_smuggle() -> None:
    middleware = LocalhostOnlyHTTPMiddleware(app=None)  # type: ignore[arg-type]
    sent, inner_called = await _call_middleware(
        middleware,
        headers=[
            (b"host", b"127.0.0.1"),
            (b"origin", b"http://localhost"),
            (b"origin", b"https://attacker.example.com"),
        ],
    )
    assert inner_called is False
    assert sent[0]["status"] == 403


def test_middleware_passes_state_attribute_through() -> None:
    """FastMCP introspects ``state`` on the wrapped ASGI app — the
    middleware must not shadow that lookup. See the matching pattern in
    ``StaleMcpSessionDiagnosticMiddleware``."""

    class FakeApp:
        state = "fake-state-marker"

    middleware = LocalhostOnlyHTTPMiddleware(FakeApp())  # type: ignore[arg-type]
    assert middleware.state == "fake-state-marker"


# ---------------------------------------------------------------------------
# --allow-host LAN opt-in (issue #421)
# ---------------------------------------------------------------------------


def test_parse_allow_hosts_cidr_and_bare_ip() -> None:
    nets = parse_allow_hosts(["192.168.1.0/24", "10.0.0.5"])
    assert str(nets[0]) == "192.168.1.0/24"
    # A bare IP becomes a host-route (/32).
    assert str(nets[1]) == "10.0.0.5/32"


def test_parse_allow_hosts_comma_separated_and_repeated() -> None:
    nets = parse_allow_hosts(["192.168.1.0/24, 10.0.0.0/8", "172.16.0.0/12"])
    assert [str(n) for n in nets] == ["192.168.1.0/24", "10.0.0.0/8", "172.16.0.0/12"]


def test_parse_allow_hosts_empty_is_empty_list() -> None:
    assert parse_allow_hosts([]) == []
    assert parse_allow_hosts(["", "  "]) == []


def test_parse_allow_hosts_tolerates_host_bits() -> None:
    # strict=False: a CIDR with host bits set is normalised, not rejected.
    nets = parse_allow_hosts(["192.168.1.5/24"])
    assert str(nets[0]) == "192.168.1.0/24"


def test_parse_allow_hosts_rejects_garbage() -> None:
    with pytest.raises(ValueError, match="not-an-ip"):
        parse_allow_hosts(["not-an-ip"])


def test_is_allowed_host_lan_ip_in_network() -> None:
    nets = parse_allow_hosts(["192.168.1.0/24"])
    assert is_allowed_host("192.168.1.50:8000", nets) is True
    assert is_allowed_host("192.168.1.50", nets) is True


def test_is_allowed_host_lan_ip_outside_network_rejected() -> None:
    nets = parse_allow_hosts(["192.168.1.0/24"])
    assert is_allowed_host("192.168.2.50:8000", nets) is False
    assert is_allowed_host("10.0.0.1", nets) is False


def test_is_allowed_host_loopback_still_passes_with_networks() -> None:
    nets = parse_allow_hosts(["192.168.1.0/24"])
    assert is_allowed_host("127.0.0.1:8000", nets) is True
    assert is_allowed_host("localhost", nets) is True


def test_is_allowed_host_dns_name_never_matches_network() -> None:
    # A DNS name (the rebinding shape) never parses to an IP, so it can't
    # slip into an allowed network even if that name resolves there.
    nets = parse_allow_hosts(["192.168.1.0/24"])
    assert is_allowed_host("attacker.example.com:8000", nets) is False


def test_is_allowed_host_bracketed_ipv6_in_network() -> None:
    # A bracketed IPv6 Host literal is unwrapped and matched against an IPv6
    # CIDR; one outside the range is rejected.
    nets = parse_allow_hosts(["fd00::/8"])
    assert is_allowed_host("[fd00::1]:8000", nets) is True
    assert is_allowed_host("[fd00::1]", nets) is True
    assert is_allowed_host("[2001:db8::1]:8000", nets) is False


def test_is_allowed_host_without_networks_unchanged() -> None:
    # Default (None) is byte-for-byte loopback-only.
    assert is_allowed_host("192.168.1.50:8000") is False
    assert is_allowed_host("192.168.1.50:8000", None) is False


def test_evaluate_loopback_native_lan_agent_passes() -> None:
    nets = parse_allow_hosts(["192.168.1.0/24"])
    # Native remote agent: in-range peer, LAN Host, no Origin/Sec-Fetch-Site.
    assert evaluate_loopback(["192.168.1.50:8000"], [], [], nets, peer_ip="192.168.1.50") is True


def test_evaluate_loopback_lan_browser_origin_rejected() -> None:
    """The opt-in widens Host only — a browser on the LAN still sends a
    non-loopback Origin and is rejected, preserving rebinding defense."""
    nets = parse_allow_hosts(["192.168.1.0/24"])
    assert (
        evaluate_loopback(
            ["192.168.1.50:8000"],
            ["http://192.168.1.50:8000"],
            [],
            nets,
            peer_ip="192.168.1.50",
        )
        is False
    )


def test_evaluate_loopback_lan_cross_site_subresource_rejected() -> None:
    nets = parse_allow_hosts(["192.168.1.0/24"])
    assert (
        evaluate_loopback(["192.168.1.50:8000"], [], ["cross-site"], nets, peer_ip="192.168.1.50")
        is False
    )


def test_evaluate_loopback_spoofed_host_foreign_peer_rejected() -> None:
    """The core --allow-host fix: an out-of-range peer that spoofs an
    in-range Host header is rejected on the peer gate. Host alone is not
    the authority."""
    nets = parse_allow_hosts(["192.168.1.0/24"])
    # Attacker at 10.0.0.5 (outside the CIDR) sends Host: 192.168.1.50.
    assert evaluate_loopback(["192.168.1.50:8000"], [], [], nets, peer_ip="10.0.0.5") is False


def test_evaluate_loopback_in_range_peer_loopback_host_passes() -> None:
    """A local client on the LAN-bound server (peer 127.0.0.1, Host
    loopback) still works after the opt-in."""
    nets = parse_allow_hosts(["192.168.1.0/24"])
    assert evaluate_loopback(["127.0.0.1:8000"], [], [], nets, peer_ip="127.0.0.1") is True


async def test_middleware_allows_lan_host_when_opted_in() -> None:
    nets = parse_allow_hosts(["192.168.1.0/24"])
    middleware = LocalhostOnlyHTTPMiddleware(app=None, allowed_networks=nets)  # type: ignore[arg-type]
    sent, inner_called = await _call_middleware(
        middleware,
        headers=[(b"host", b"192.168.1.50:8000")],
        client=("192.168.1.50", 51234),
    )
    assert inner_called is True
    assert sent[0]["status"] == 200


async def test_middleware_rejects_lan_host_browser_origin_when_opted_in() -> None:
    nets = parse_allow_hosts(["192.168.1.0/24"])
    middleware = LocalhostOnlyHTTPMiddleware(app=None, allowed_networks=nets)  # type: ignore[arg-type]
    sent, inner_called = await _call_middleware(
        middleware,
        headers=[
            (b"host", b"192.168.1.50:8000"),
            (b"origin", b"http://192.168.1.50:8000"),
        ],
        client=("192.168.1.50", 51234),
    )
    assert inner_called is False
    assert sent[0]["status"] == 403


async def test_middleware_rejects_spoofed_host_from_foreign_peer() -> None:
    """The --allow-host fix at the transport boundary: a peer OUTSIDE the
    allowed range spoofs an in-range Host header. The peer gate refuses it
    even though the Host passes the range check."""
    nets = parse_allow_hosts(["192.168.1.0/24"])
    middleware = LocalhostOnlyHTTPMiddleware(app=None, allowed_networks=nets)  # type: ignore[arg-type]
    sent, inner_called = await _call_middleware(
        middleware,
        headers=[(b"host", b"192.168.1.50:8000")],
        client=("10.0.0.5", 51234),
    )
    assert inner_called is False
    assert sent[0]["status"] == 403


async def test_middleware_rejects_when_opted_in_and_peer_unknown() -> None:
    """Bound off loopback but the ASGI server didn't populate scope["client"]
    — fail closed rather than fall back to the spoofable Host header."""
    nets = parse_allow_hosts(["192.168.1.0/24"])
    middleware = LocalhostOnlyHTTPMiddleware(app=None, allowed_networks=nets)  # type: ignore[arg-type]
    sent, inner_called = await _call_middleware(
        middleware,
        headers=[(b"host", b"192.168.1.50:8000")],
        client=None,
    )
    assert inner_called is False
    assert sent[0]["status"] == 403


async def test_middleware_allows_loopback_peer_when_opted_in() -> None:
    """A local client (peer 127.0.0.1) on a LAN-bound server still works."""
    nets = parse_allow_hosts(["192.168.1.0/24"])
    middleware = LocalhostOnlyHTTPMiddleware(app=None, allowed_networks=nets)  # type: ignore[arg-type]
    sent, inner_called = await _call_middleware(
        middleware,
        headers=[(b"host", b"127.0.0.1:8000")],
        client=("127.0.0.1", 51234),
    )
    assert inner_called is True
    assert sent[0]["status"] == 200


async def test_middleware_rejects_lan_host_without_opt_in() -> None:
    # Default middleware (no networks) keeps rejecting LAN hosts. A loopback
    # peer is irrelevant — the loopback bind already guarantees it.
    middleware = LocalhostOnlyHTTPMiddleware(app=None)  # type: ignore[arg-type]
    sent, inner_called = await _call_middleware(
        middleware,
        headers=[(b"host", b"192.168.1.50:8000")],
        client=("127.0.0.1", 51234),
    )
    assert inner_called is False
    assert sent[0]["status"] == 403


def test_bind_host_for_networks_none_keeps_loopback_default() -> None:
    # No opt-in → None so callers keep their loopback default.
    assert bind_host_for_networks(None) is None
    assert bind_host_for_networks([]) is None


def test_bind_host_for_networks_ipv4_only() -> None:
    assert bind_host_for_networks(parse_allow_hosts(["192.168.1.0/24"])) == "0.0.0.0"


def test_bind_host_for_networks_ipv6_only() -> None:
    # An IPv6-only allowlist binds "::" (no IPv4 range to serve).
    assert bind_host_for_networks(parse_allow_hosts(["fd00::/8"])) == "::"


def test_bind_host_for_networks_prioritizes_ipv4_reachability() -> None:
    # Any IPv4 in the allowlist → "0.0.0.0", so IPv4 stays reachable on every
    # platform (incl. Windows v6-only). A mixed allowlist must NOT bind "::"
    # and silently drop IPv4 reachability. See bind_host_for_networks docstring.
    assert bind_host_for_networks(parse_allow_hosts(["192.168.1.0/24", "fd00::/8"])) == "0.0.0.0"
    assert bind_host_for_networks(parse_allow_hosts(["fd00::/8", "10.0.0.0/8"])) == "0.0.0.0"


# ---------------------------------------------------------------------------
# peer_ip_allowed — the authoritative, unforgeable LAN gate (--allow-host fix)
# ---------------------------------------------------------------------------


def test_peer_ip_allowed_no_networks_is_passthrough() -> None:
    # Loopback-only default: the kernel bind guarantees a loopback peer, so the
    # gate is a pass-through — even when the peer is unknown — keeping behavior
    # byte-for-byte unchanged.
    assert peer_ip_allowed(None, None) is True
    assert peer_ip_allowed("127.0.0.1", None) is True
    assert peer_ip_allowed("192.168.1.50", None) is True
    assert peer_ip_allowed("10.0.0.5", []) is True


def test_peer_ip_allowed_in_network() -> None:
    nets = parse_allow_hosts(["192.168.1.0/24"])
    assert peer_ip_allowed("192.168.1.50", nets) is True
    assert peer_ip_allowed("192.168.1.1", nets) is True


def test_peer_ip_allowed_out_of_network_rejected() -> None:
    nets = parse_allow_hosts(["192.168.1.0/24"])
    assert peer_ip_allowed("192.168.2.50", nets) is False
    assert peer_ip_allowed("10.0.0.5", nets) is False


def test_peer_ip_allowed_loopback_always_ok_when_opted_in() -> None:
    nets = parse_allow_hosts(["192.168.1.0/24"])
    assert peer_ip_allowed("127.0.0.1", nets) is True
    assert peer_ip_allowed("::1", nets) is True


def test_peer_ip_allowed_missing_fails_closed_when_opted_in() -> None:
    nets = parse_allow_hosts(["192.168.1.0/24"])
    assert peer_ip_allowed(None, nets) is False
    assert peer_ip_allowed("", nets) is False


def test_peer_ip_allowed_unparseable_fails_closed() -> None:
    nets = parse_allow_hosts(["192.168.1.0/24"])
    assert peer_ip_allowed("not-an-ip", nets) is False
    # A DNS name never reaches here (peer is always an IP literal), but if it
    # somehow did, it must not slip through.
    assert peer_ip_allowed("attacker.example.com", nets) is False


def test_peer_ip_allowed_strips_ipv6_zone_id() -> None:
    nets = parse_allow_hosts(["fd00::/8"])
    assert peer_ip_allowed("fd00::1%eth0", nets) is True
    assert peer_ip_allowed("2001:db8::1%eth0", nets) is False


def test_peer_ip_allowed_unwraps_ipv4_mapped_ipv6() -> None:
    ## A dual-stack listener can report an IPv4 peer as IPv4-mapped IPv6
    ## (``::ffff:a.b.c.d``); ``.is_loopback`` is False on that form and it
    ## never matches an IPv4 network, so without unwrapping a genuine
    ## loopback / in-network peer would be wrongly rejected.
    nets = parse_allow_hosts(["192.168.1.0/24"])
    assert peer_ip_allowed("::ffff:127.0.0.1", nets) is True  # mapped loopback
    assert peer_ip_allowed("::ffff:192.168.1.50", nets) is True  # mapped in-network
    assert peer_ip_allowed("::ffff:10.0.0.5", nets) is False  # mapped out-of-network

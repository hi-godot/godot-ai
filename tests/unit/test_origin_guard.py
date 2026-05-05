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
    is_allowed_host,
    is_allowed_origin,
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
        # Sandboxed and file:// contexts emit ``Origin: null``.
        "null",
        "NULL",
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
    ],
)
def test_loopback_origins_pass(origin) -> None:
    assert is_allowed_origin(origin) is True


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
# LocalhostOnlyHTTPMiddleware (ASGI scope shape)
# ---------------------------------------------------------------------------


async def _call_middleware(
    middleware: LocalhostOnlyHTTPMiddleware,
    *,
    headers: list[tuple[bytes, bytes]],
    scope_type: str = "http",
) -> tuple[list[dict], bool]:
    """Run the middleware against a synthetic scope; return (sent, inner_called)."""
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

"""HTTP authentication and finite-work boundary tests."""

from __future__ import annotations

import asyncio
import json
from types import SimpleNamespace
from unittest.mock import MagicMock

import pytest
import uvicorn
from uvicorn.server import ServerState

from godot_ai import asgi
from godot_ai.transport.security import BoundedHTTPMiddleware, CapabilityAuthMiddleware

CAPABILITY = "c" * 32


def _scope(*headers: tuple[bytes, bytes], path: str = "/mcp") -> dict:
    return {
        "type": "http",
        "method": "POST",
        "path": path,
        "headers": list(headers),
    }


async def _call(app, scope: dict, messages: list[dict] | None = None) -> list[dict]:
    incoming = list(messages or [{"type": "http.request", "body": b""}])
    sent: list[dict] = []

    async def receive() -> dict:
        return incoming.pop(0) if incoming else {"type": "http.disconnect"}

    async def send(message: dict) -> None:
        sent.append(message)

    await app(scope, receive, send)
    return sent


def _error_code(messages: list[dict]) -> str:
    return json.loads(messages[-1]["body"])["error"]["code"]


@pytest.mark.asyncio
async def test_capability_auth_rejects_missing_wrong_and_duplicate_headers() -> None:
    called = False

    async def endpoint(_scope, _receive, _send) -> None:
        nonlocal called
        called = True

    app = CapabilityAuthMiddleware(endpoint, CAPABILITY)
    cases = (
        _scope(),
        _scope((b"authorization", b"Bearer wrong")),
        _scope(
            (b"authorization", f"Bearer {CAPABILITY}".encode()),
            (b"authorization", f"Bearer {CAPABILITY}".encode()),
        ),
    )
    for scope in cases:
        response = await _call(app, scope)
        assert response[0]["status"] == 401
        assert _error_code(response) == "TRANSPORT_AUTH_REQUIRED"
    assert not called


@pytest.mark.asyncio
async def test_capability_auth_passes_one_exact_bearer_value() -> None:
    called = False

    async def endpoint(_scope, _receive, _send) -> None:
        nonlocal called
        called = True

    app = CapabilityAuthMiddleware(endpoint, CAPABILITY)
    await _call(app, _scope((b"authorization", f"bearer {CAPABILITY}".encode())))
    assert called


@pytest.mark.asyncio
async def test_body_limit_counts_chunks_without_trusting_content_length() -> None:
    called = False

    async def endpoint(_scope, _receive, _send) -> None:
        nonlocal called
        called = True

    app = BoundedHTTPMiddleware(endpoint, max_body_bytes=4)
    response = await _call(
        app,
        _scope(),
        [
            {"type": "http.request", "body": b"abc", "more_body": True},
            {"type": "http.request", "body": b"de", "more_body": False},
        ],
    )
    assert response[0]["status"] == 413
    assert _error_code(response) == "REQUEST_BODY_TOO_LARGE"
    assert not called


@pytest.mark.asyncio
@pytest.mark.parametrize(
    ("headers", "status", "code"),
    [
        ([(b"content-length", b"nope")], 400, "INVALID_CONTENT_LENGTH"),
        (
            [(b"content-length", b"1"), (b"content-length", b"1")],
            400,
            "INVALID_CONTENT_LENGTH",
        ),
        ([(b"content-length", b"5")], 413, "REQUEST_BODY_TOO_LARGE"),
        ([(b"content-length", b"9" * 5000)], 413, "REQUEST_BODY_TOO_LARGE"),
    ],
)
async def test_content_length_is_unambiguous_and_bounded(headers, status, code) -> None:
    async def endpoint(_scope, _receive, _send) -> None:
        raise AssertionError("rejected request reached endpoint")

    response = await _call(BoundedHTTPMiddleware(endpoint, max_body_bytes=4), _scope(*headers))
    assert response[0]["status"] == status
    assert _error_code(response) == code


@pytest.mark.asyncio
async def test_body_deadline_rejects_a_drip_feed() -> None:
    async def endpoint(_scope, _receive, _send) -> None:
        raise AssertionError("timed-out request reached endpoint")

    async def receive() -> dict:
        await asyncio.Event().wait()
        raise AssertionError

    sent: list[dict] = []

    async def send(message: dict) -> None:
        sent.append(message)

    app = BoundedHTTPMiddleware(endpoint, body_timeout_seconds=0.001)
    await app(_scope(), receive, send)
    assert sent[0]["status"] == 408
    assert _error_code(sent) == "REQUEST_BODY_TIMEOUT"


@pytest.mark.asyncio
async def test_concurrency_limit_rejects_instead_of_queueing() -> None:
    entered = asyncio.Event()
    release = asyncio.Event()

    async def endpoint(_scope, _receive, _send) -> None:
        entered.set()
        await release.wait()

    app = BoundedHTTPMiddleware(endpoint, max_concurrency=1)
    first = asyncio.create_task(_call(app, _scope()))
    await entered.wait()
    second = await _call(app, _scope())
    release.set()
    await first

    assert second[0]["status"] == 503
    assert _error_code(second) == "TRANSPORT_OVERLOADED"


@pytest.mark.asyncio
async def test_session_limit_counts_reservations_and_prunes_terminated() -> None:
    manager = SimpleNamespace(
        _server_instances={
            "dead": SimpleNamespace(is_terminated=True),
            "live": SimpleNamespace(is_terminated=False),
        },
        _session_owners={"dead": object(), "live": object()},
        session_idle_timeout=0,
    )

    class Endpoint:
        session_manager = manager

        async def __call__(self, _scope, _receive, _send) -> None:
            return None

    app = BoundedHTTPMiddleware(Endpoint(), max_sessions=1, session_idle_seconds=7)
    response = await _call(app, _scope())
    assert response[0]["status"] == 503
    assert _error_code(response) == "MCP_SESSION_LIMIT_REACHED"
    assert set(manager._server_instances) == {"live"}
    assert set(manager._session_owners) == {"live"}
    assert manager.session_idle_timeout == 7


def _transport() -> MagicMock:
    transport = MagicMock(spec=asyncio.Transport)
    transport.get_extra_info.side_effect = lambda name, default=None: {
        "peername": ("127.0.0.1", 41000),
        "sockname": ("127.0.0.1", 8000),
        "sslcontext": None,
    }.get(name, default)
    transport.is_closing.return_value = False
    return transport


def _h11_protocol(loop, state: ServerState, *, limit: int = 1):
    async def app(_scope, _receive, _send) -> None:
        return None

    config = uvicorn.Config(app, limit_concurrency=limit, log_config=None)
    return asgi.BoundedH11Protocol(config, state, {}, _loop=loop)


def test_hardened_uvicorn_config_bounds_every_pre_asgi_stage() -> None:
    config = asgi.hardened_uvicorn_config(access_log=False)

    assert config == {
        "access_log": False,
        "http": asgi.BoundedH11Protocol,
        "limit_concurrency": asgi.HTTP_SERVER_CONNECTION_LIMIT,
        "backlog": asgi.HTTP_SERVER_BACKLOG,
        "timeout_keep_alive": asgi.HTTP_SERVER_KEEP_ALIVE_SECONDS,
        "h11_max_incomplete_event_size": asgi.HTTP_SERVER_MAX_INCOMPLETE_EVENT_BYTES,
    }


def test_h11_protocol_rejects_raw_connections_past_the_cap() -> None:
    loop = asyncio.new_event_loop()
    state = ServerState()
    first = _h11_protocol(loop, state)
    second = _h11_protocol(loop, state)
    first_transport, second_transport = _transport(), _transport()
    try:
        first.connection_made(first_transport)
        second.connection_made(second_transport)

        first_transport.abort.assert_not_called()
        second_transport.abort.assert_called_once()
        assert state.connections == {first}
    finally:
        first.connection_lost(None)
        loop.close()


def test_h11_incomplete_header_deadline_closes_the_socket() -> None:
    loop = asyncio.new_event_loop()
    protocol = _h11_protocol(loop, ServerState())
    transport = _transport()
    try:
        protocol.connection_made(transport)
        assert protocol._header_timeout is not None
        protocol._close_incomplete_header()
        transport.close.assert_called_once()
    finally:
        protocol.connection_lost(None)
        loop.close()


class _UnsupportedBoundary(BoundedHTTPMiddleware):
    def _session_manager(self):
        raise AssertionError("unsupported protocol touched session manager")


async def _unexpected_endpoint(_scope, _receive, _send):
    raise AssertionError("unsupported protocol reached endpoint")


def _unsupported_scope(*headers):
    return _scope((b"mcp-protocol-version", b"2026-07-28"), *headers)


@pytest.mark.parametrize(
    "extra",
    [
        [],
        [(b"mcp-session-id", b"untrusted")],
        [
            (b"mcp-protocol-version", b"2025-11-25"),
        ],
    ],
)
async def test_unsupported_consumes_body_without_session_access(extra):
    app = _UnsupportedBoundary(_unexpected_endpoint, max_sessions=1)
    chunks = [
        {"type": "http.request", "body": b"one", "more_body": True},
        {"type": "http.request", "body": b"two", "more_body": False},
    ]
    sent = []

    async def receive():
        assert app._active == 1
        assert app._new_session_reservations == 0
        return chunks.pop(0)

    async def send(message):
        assert not chunks
        sent.append(message)

    await app(_unsupported_scope(*extra), receive, send)
    assert sent[0]["status"] == 400
    assert _error_code(sent) == "MCP_PROTOCOL_UNSUPPORTED"
    assert app._active == app._new_session_reservations == 0


@pytest.mark.parametrize("ending", ["complete", "cancel", "disconnect", "send_failure"])
async def test_unsupported_admission_and_cleanup(ending):
    app = _UnsupportedBoundary(_unexpected_endpoint, max_concurrency=1)
    entered, release = asyncio.Event(), asyncio.Event()
    sent = []

    async def receive():
        entered.set()
        await release.wait()
        return (
            {"type": "http.disconnect"}
            if ending == "disconnect"
            else {
                "type": "http.request",
                "body": b"done",
            }
        )

    async def send(message):
        if ending == "send_failure":
            raise ConnectionError("test peer gone")
        sent.append(message)

    first = asyncio.create_task(app(_unsupported_scope(), receive, send))
    try:
        await asyncio.wait_for(entered.wait(), 1)
        assert app._active == 1

        async def no_read():
            raise AssertionError("overloaded body consumed")

        overloaded = []

        async def overload_send(message):
            overloaded.append(message)

        await app(_unsupported_scope(), no_read, overload_send)
        assert overloaded[0]["status"] == 503
        assert _error_code(overloaded) == "TRANSPORT_OVERLOADED"
        assert app._active == 1
        if ending == "cancel":
            first.cancel()
            with pytest.raises(asyncio.CancelledError):
                await first
        else:
            release.set()
            if ending == "send_failure":
                with pytest.raises(ConnectionError, match="test peer gone"):
                    await first
            else:
                await first
                assert _error_code(sent) == "MCP_PROTOCOL_UNSUPPORTED"
        assert app._active == app._new_session_reservations == 0
    finally:
        release.set()
        if not first.done():
            first.cancel()
            with pytest.raises(asyncio.CancelledError):
                await first


@pytest.mark.parametrize(
    "headers,chunks,status,code",
    [
        ([(b"content-length", b"invalid")], [], 400, "INVALID_CONTENT_LENGTH"),
        ([(b"content-length", b"1"), (b"content-length", b"1")], [], 400, "INVALID_CONTENT_LENGTH"),
        ([(b"content-length", b"5")], [], 413, "REQUEST_BODY_TOO_LARGE"),
        (
            [],
            [
                {"type": "http.request", "body": b"123", "more_body": True},
                {"type": "http.request", "body": b"45"},
            ],
            413,
            "REQUEST_BODY_TOO_LARGE",
        ),
    ],
)
async def test_unsupported_preserves_body_limits(headers, chunks, status, code):
    app = _UnsupportedBoundary(_unexpected_endpoint, max_body_bytes=4)
    incoming = list(chunks)
    sent = []

    async def receive():
        assert incoming, "invalid declared length must reject before reading"
        return incoming.pop(0)

    async def send(message):
        sent.append(message)

    await app(_unsupported_scope(*headers), receive, send)
    assert sent[0]["status"] == status
    assert _error_code(sent) == code
    assert app._active == app._new_session_reservations == 0


async def test_unsupported_timeout_releases_admission():
    app = _UnsupportedBoundary(_unexpected_endpoint, body_timeout_seconds=0.001)
    sent = []

    async def receive():
        await asyncio.Event().wait()
        raise AssertionError("timeout must interrupt receive")

    async def send(message):
        sent.append(message)

    await app(_unsupported_scope(), receive, send)
    assert sent[0]["status"] == 408
    assert _error_code(sent) == "REQUEST_BODY_TIMEOUT"
    assert app._active == app._new_session_reservations == 0


async def test_unsupported_unauthorized_body_is_not_consumed():
    bounded = _UnsupportedBoundary(_unexpected_endpoint)
    app = CapabilityAuthMiddleware(bounded, CAPABILITY)
    sent = []

    async def receive():
        raise AssertionError("unauthorized body consumed")

    async def send(message):
        sent.append(message)

    await app(_unsupported_scope(), receive, send)
    assert sent[0]["status"] == 401
    assert _error_code(sent) == "TRANSPORT_AUTH_REQUIRED"
    assert bounded._active == bounded._new_session_reservations == 0

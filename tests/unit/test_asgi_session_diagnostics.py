from __future__ import annotations

import json

import pytest

from godot_ai.asgi import STALE_MCP_SESSION_MESSAGE, StaleMcpSessionDiagnosticMiddleware
from godot_ai.server import create_server


async def _single_http_request(app, *, headers=None):
    sent = []

    scope = {
        "type": "http",
        "method": "POST",
        "path": "/mcp",
        "headers": headers or [],
    }

    async def receive():
        return {"type": "http.request", "body": b"", "more_body": False}

    async def send(message):
        sent.append(message)

    await app(scope, receive, send)
    return sent


async def _single_asgi_request(app, *, scope):
    sent = []

    async def receive():
        return {"type": "websocket.disconnect"}

    async def send(message):
        sent.append(message)

    await app(scope, receive, send)
    return sent


@pytest.mark.anyio
async def test_stale_mcp_session_diagnostic_rewrites_sdk_session_not_found():
    async def sdk_stale_session_response(scope, receive, send):
        await send(
            {
                "type": "http.response.start",
                "status": 404,
                "headers": [(b"content-type", b"application/json")],
            }
        )
        await send(
            {
                "type": "http.response.body",
                "body": json.dumps(
                    {
                        "jsonrpc": "2.0",
                        "id": "server-error",
                        "error": {"code": -32600, "message": "Session not found"},
                    }
                ).encode(),
                "more_body": False,
            }
        )

    app = StaleMcpSessionDiagnosticMiddleware(sdk_stale_session_response)

    sent = await _single_http_request(
        app,
        headers=[(b"mcp-session-id", b"stale-session-id")],
    )

    assert sent[0]["status"] == 404
    body = json.loads(sent[1]["body"])
    assert body == {
        "jsonrpc": "2.0",
        "id": "server-error",
        "error": {
            "code": -32600,
            "message": STALE_MCP_SESSION_MESSAGE,
            "data": {
                "recoverable": True,
                "action": "reinitialize_mcp_session",
                "reason": "stale_streamable_http_session",
            },
        },
    }


@pytest.mark.anyio
async def test_stale_mcp_session_diagnostic_handles_chunked_stale_session_body():
    async def sdk_stale_session_response(scope, receive, send):
        await send({"type": "http.response.start", "status": 404, "headers": []})
        await send(
            {
                "type": "http.response.body",
                "body": b'{"jsonrpc":"2.0","id":"server-error",',
                "more_body": True,
            }
        )
        await send(
            {
                "type": "http.response.body",
                "body": b'"error":{"code":-32600,"message":"Session not found"}}',
                "more_body": False,
            }
        )

    app = StaleMcpSessionDiagnosticMiddleware(sdk_stale_session_response)

    sent = await _single_http_request(app)

    assert sent[0]["status"] == 404
    assert (b"content-type", b"application/json") in sent[0]["headers"]
    body = json.loads(sent[1]["body"])
    assert body["error"]["message"] == STALE_MCP_SESSION_MESSAGE
    assert body["error"]["data"]["action"] == "reinitialize_mcp_session"


@pytest.mark.anyio
async def test_stale_mcp_session_diagnostic_leaves_other_responses_unchanged():
    async def ok_response(scope, receive, send):
        await send(
            {
                "type": "http.response.start",
                "status": 200,
                "headers": [(b"content-type", b"application/json")],
            }
        )
        await send({"type": "http.response.body", "body": b'{"ok": true}', "more_body": False})

    app = StaleMcpSessionDiagnosticMiddleware(ok_response)

    sent = await _single_http_request(app)

    assert sent == [
        {
            "type": "http.response.start",
            "status": 200,
            "headers": [(b"content-type", b"application/json")],
        },
        {"type": "http.response.body", "body": b'{"ok": true}', "more_body": False},
    ]


@pytest.mark.anyio
async def test_stale_mcp_session_diagnostic_streams_non_404_responses_unchanged():
    async def streaming_response(scope, receive, send):
        await send(
            {
                "type": "http.response.start",
                "status": 200,
                "headers": [(b"content-type", b"text/event-stream")],
            }
        )
        await send({"type": "http.response.body", "body": b"data: one\n\n", "more_body": True})
        await send({"type": "http.response.body", "body": b"data: two\n\n", "more_body": False})

    app = StaleMcpSessionDiagnosticMiddleware(streaming_response)

    sent = await _single_http_request(app)

    assert sent == [
        {
            "type": "http.response.start",
            "status": 200,
            "headers": [(b"content-type", b"text/event-stream")],
        },
        {"type": "http.response.body", "body": b"data: one\n\n", "more_body": True},
        {"type": "http.response.body", "body": b"data: two\n\n", "more_body": False},
    ]


@pytest.mark.anyio
async def test_stale_mcp_session_diagnostic_passes_non_http_scopes_through():
    async def websocket_response(scope, receive, send):
        await send({"type": "websocket.close", "code": 1000})

    app = StaleMcpSessionDiagnosticMiddleware(websocket_response)

    sent = await _single_asgi_request(app, scope={"type": "websocket", "path": "/ws"})

    assert sent == [{"type": "websocket.close", "code": 1000}]


@pytest.mark.anyio
async def test_stale_mcp_session_diagnostic_passes_unhandled_asgi_messages_through():
    async def extension_message_response(scope, receive, send):
        await send(
            {
                "type": "http.response.debug",
                "info": {"note": "kept for downstream middleware"},
            }
        )

    app = StaleMcpSessionDiagnosticMiddleware(extension_message_response)

    sent = await _single_http_request(app)

    assert sent == [
        {
            "type": "http.response.debug",
            "info": {"note": "kept for downstream middleware"},
        }
    ]


@pytest.mark.anyio
async def test_stale_mcp_session_diagnostic_leaves_other_404_responses_unchanged():
    async def not_found_response(scope, receive, send):
        await send(
            {
                "type": "http.response.start",
                "status": 404,
                "headers": [(b"content-type", b"text/plain"), (b"content-length", b"9")],
            }
        )
        await send({"type": "http.response.body", "body": b"not found", "more_body": False})

    app = StaleMcpSessionDiagnosticMiddleware(not_found_response)

    sent = await _single_http_request(app)

    assert sent == [
        {
            "type": "http.response.start",
            "status": 404,
            "headers": [(b"content-type", b"text/plain"), (b"content-length", b"9")],
        },
        {"type": "http.response.body", "body": b"not found", "more_body": False},
    ]


@pytest.mark.anyio
async def test_stale_mcp_session_diagnostic_leaves_other_json_rpc_404_errors_unchanged():
    async def json_rpc_not_found_response(scope, receive, send):
        body = json.dumps(
            {
                "jsonrpc": "2.0",
                "id": "server-error",
                "error": {"code": -32000, "message": "Tool not found"},
            }
        ).encode()
        await send(
            {
                "type": "http.response.start",
                "status": 404,
                "headers": [(b"content-type", b"application/json")],
            }
        )
        await send({"type": "http.response.body", "body": body, "more_body": False})

    app = StaleMcpSessionDiagnosticMiddleware(json_rpc_not_found_response)

    sent = await _single_http_request(app)

    body = json.loads(sent[1]["body"])
    assert body["error"] == {"code": -32000, "message": "Tool not found"}
    assert "data" not in body["error"]


def test_create_server_wraps_streamable_http_app_with_stale_session_diagnostic():
    server = create_server()

    app = server.http_app(transport="streamable-http")

    assert isinstance(app, StaleMcpSessionDiagnosticMiddleware)


def test_create_server_does_not_wrap_sse_app_with_stale_session_diagnostic():
    server = create_server()

    app = server.http_app(transport="sse")

    assert not isinstance(app, StaleMcpSessionDiagnosticMiddleware)


def test_stale_mcp_session_diagnostic_preserves_fastmcp_app_state():
    server = create_server()

    app = server.http_app(transport="streamable-http")

    assert app.state is app.app.state

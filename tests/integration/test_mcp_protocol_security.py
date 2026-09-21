"""Real SDK protocol routing behind Godot AI's HTTP security wrappers."""

from __future__ import annotations

import asyncio
from contextlib import asynccontextmanager
from types import SimpleNamespace

import httpx2 as httpx
import pytest
from fastmcp import Client
from fastmcp.client.transports import StreamableHttpTransport

from godot_ai.server import GodotAIFastMCP

CAPABILITY = "c" * 32
MODERN = "2026-07-28"
LEGACY = "2025-11-25"


@asynccontextmanager
async def endpoint():
    server = GodotAIFastMCP("protocol-boundary-test")
    server._transport_capabilities = SimpleNamespace(http=CAPABILITY)
    entered, release = asyncio.Event(), asyncio.Event()

    @server.tool
    async def echo(value: str) -> dict:
        return {"value": value}

    @server.tool
    async def hold() -> dict:
        entered.set()
        await release.wait()
        return {"released": True}

    app = server.http_app(json_response=True)
    bounded = app.app.app
    async with app.router.lifespan_context(app):
        async with httpx.AsyncClient(
            transport=httpx.ASGITransport(app=app),
            base_url="http://127.0.0.1",
            headers={
                "authorization": f"Bearer {CAPABILITY}",
                "accept": "application/json, text/event-stream",
            },
        ) as client:
            yield server, bounded, client, entered, release


async def rpc(client, method, *, protocol=MODERN, params=None, headers=None):
    params = dict(params or {})
    routing = {"mcp-protocol-version": protocol}
    if protocol == MODERN:
        routing["mcp-method"] = method
        if "name" in params:
            routing["mcp-name"] = params["name"]
        params["_meta"] = {
            "io.modelcontextprotocol/protocolVersion": MODERN,
            "io.modelcontextprotocol/clientCapabilities": {},
        }
    return await client.post(
        "/mcp",
        headers={**routing, **(headers or {})},
        json={"jsonrpc": "2.0", "id": 1, "method": method, "params": params or {}},
    )


async def initialize(client, protocol=LEGACY):
    response = await rpc(
        client,
        "initialize",
        protocol=protocol,
        params={
            "protocolVersion": protocol,
            "capabilities": {},
            "clientInfo": {"name": "security-test", "version": "1"},
        },
    )
    assert response.status_code == 200, response.text
    assert response.json()["result"]["protocolVersion"] == protocol
    session = response.headers["mcp-session-id"]
    response = await client.post(
        "/mcp",
        headers={"mcp-protocol-version": protocol, "mcp-session-id": session},
        json={"jsonrpc": "2.0", "method": "notifications/initialized"},
    )
    assert response.status_code == 202, response.text
    return session


@pytest.mark.parametrize("protocol", ["2024-11-05", "2025-03-26", "2025-06-18", LEGACY])
async def test_handshake_versions_list_and_call(protocol):
    async with endpoint() as fixture:
        _, bounded, client, _, _ = fixture
        session = await initialize(client, protocol)
        headers = {"mcp-session-id": session}
        response = await rpc(client, "tools/list", protocol=protocol, headers=headers)
        assert response.status_code == 200, response.text
        assert {tool["name"] for tool in response.json()["result"]["tools"]} == {"echo", "hold"}
        response = await rpc(
            client,
            "tools/call",
            protocol=protocol,
            headers=headers,
            params={"name": "echo", "arguments": {"value": protocol}},
        )
        assert response.status_code == 200, response.text
        assert response.json()["result"]["structuredContent"] == {"value": protocol}
        assert len(bounded._session_manager()._server_instances) == 1
        response = await rpc(client, "server/discover", protocol=protocol, headers=headers)
        assert response.json()["error"]["code"] == -32601, response.text


async def test_auto_client_falls_back_without_advertising_modern_support():
    async with endpoint() as fixture:
        _, bounded, http, _, _ = fixture

        def factory(**kwargs):
            return httpx.AsyncClient(transport=http._transport, headers=http.headers)

        transport = StreamableHttpTransport("http://127.0.0.1/mcp", httpx_client_factory=factory)
        async with Client(transport) as client:
            assert client.session.protocol_version == LEGACY
            assert client.session.initialize_result is not None
            assert client.session.discover_result is None
            result = await client.call_tool("echo", {"value": "auto-fallback"})
            assert result.data == {"value": "auto-fallback"}
            assert len(bounded._session_manager()._server_instances) == 1


@pytest.mark.parametrize("versions", [[MODERN], ["unknown"], [LEGACY, LEGACY], [LEGACY, MODERN]])
async def test_rejected_versions_never_dispatch_mutation(versions):
    async with endpoint() as fixture:
        _, bounded, client, entered, _ = fixture
        for method in ("server/discover", "tools/list", "tools/call"):
            response = await client.post(
                "/mcp",
                headers=[("mcp-protocol-version", version) for version in versions],
                json={
                    "jsonrpc": "2.0",
                    "id": 1,
                    "method": method,
                    "params": {"name": "hold", "arguments": {}},
                },
            )
            assert response.status_code == 400, response.text
            assert response.json()["error"]["code"] == "MCP_PROTOCOL_UNSUPPORTED"
        assert not entered.is_set()
        assert not bounded._session_manager()._server_instances


@pytest.mark.parametrize("protocol", [MODERN, LEGACY])
async def test_protocol_guards_auth_host_origin_and_body(protocol):
    async with endpoint() as fixture:
        _, bounded, client, _, _ = fixture
        for headers, status in (
            ({"authorization": "Bearer wrong"}, 401),
            ({"host": "attacker.example"}, 403),
            ({"origin": "https://attacker.example"}, 403),
        ):
            response = await rpc(client, "tools/list", protocol=protocol, headers=headers)
            assert response.status_code == status, response.text
        if protocol == MODERN:
            return  # Auth and origin refusals above must precede the protocol gate.
        bounded.max_body_bytes = 128
        response = await rpc(
            client,
            "tools/call",
            protocol=protocol,
            params={"name": "echo", "arguments": {"value": "x" * 256}},
        )
        assert response.status_code == 413, response.text
        assert response.json()["error"]["code"] == "REQUEST_BODY_TOO_LARGE"


async def test_legacy_concurrency_limit():
    async with endpoint() as fixture:
        _, bounded, client, entered, release = fixture
        bounded.max_concurrency = 1
        session = await initialize(client)
        headers = {"mcp-session-id": session}
        first = asyncio.create_task(
            rpc(client, "tools/call", protocol=LEGACY, headers=headers, params={"name": "hold"})
        )
        try:
            await asyncio.wait_for(entered.wait(), 5)
            response = await rpc(client, "tools/list", protocol=LEGACY, headers=headers)
            assert response.status_code == 503, response.text
            assert response.json()["error"]["code"] == "TRANSPORT_OVERLOADED"
        finally:
            release.set()
            response = await first
        assert response.status_code == 200, response.text
        assert response.json()["result"]["structuredContent"] == {"released": True}


async def test_full_legacy_capacity_rejects_new_handshakes():
    async with endpoint() as fixture:
        _, bounded, client, _, _ = fixture
        bounded.max_sessions = 1
        session = await initialize(client)
        response = await rpc(
            client, "tools/list", protocol=LEGACY, headers={"mcp-session-id": session}
        )
        assert response.status_code == 200, response.text
        response = await rpc(
            client,
            "initialize",
            protocol=LEGACY,
            params={
                "protocolVersion": LEGACY,
                "capabilities": {},
                "clientInfo": {"name": "overflow", "version": "1"},
            },
        )
        assert response.status_code == 503, response.text
        assert response.json()["error"]["code"] == "MCP_SESSION_LIMIT_REACHED"


async def test_missing_version_header_preserves_handshake():
    async with endpoint() as fixture:
        _, _, client, _, _ = fixture
        response = await client.post(
            "/mcp",
            json={
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": {
                    "protocolVersion": LEGACY,
                    "capabilities": {},
                    "clientInfo": {"name": "headerless", "version": "1"},
                },
            },
        )
        assert response.status_code == 200, response.text
        assert response.json()["result"]["protocolVersion"] == LEGACY
        assert response.headers["mcp-session-id"]


@pytest.mark.parametrize("headers", [{}, {"mcp-protocol-version": LEGACY}])
async def test_modern_envelope_cannot_bypass_header_policy(headers):
    async with endpoint() as fixture:
        _, _, client, entered, _ = fixture
        response = await client.post(
            "/mcp",
            headers=headers,
            json={
                "jsonrpc": "2.0",
                "id": 1,
                "method": "tools/call",
                "params": {
                    "name": "hold",
                    "arguments": {},
                    "_meta": {
                        "io.modelcontextprotocol/protocolVersion": MODERN,
                        "io.modelcontextprotocol/clientCapabilities": {},
                    },
                },
            },
        )
        assert response.status_code == 400, response.text
        assert not entered.is_set()

"""Protocol rejection over real TCP, including the SDK discovery fallback."""

from __future__ import annotations

import asyncio
import json
import secrets
import socket
from collections import Counter
from contextlib import asynccontextmanager

import httpx2 as httpx
import pytest
import uvicorn
from fastmcp import Client
from fastmcp.client.transports import StreamableHttpTransport

from godot_ai.asgi import hardened_uvicorn_config
from godot_ai.server import GodotAIFastMCP
from godot_ai.transport.capability import LaunchCapabilities


class DelayedBody(httpx.AsyncByteStream):
    def __init__(self, body: bytes, delay: float) -> None:
        self.body, self.delay = body, delay

    async def __aiter__(self):
        await asyncio.sleep(self.delay)
        yield self.body


@asynccontextmanager
async def wire_endpoint():
    token = secrets.token_hex(32)
    mcp = GodotAIFastMCP("wire-protocol-regression")
    mcp._transport_capabilities = LaunchCapabilities(token, secrets.token_hex(32))
    reads = []

    @mcp.tool
    def read_value() -> dict:
        reads.append("read")
        return {"value": "read-once"}

    app = mcp.http_app(json_response=True)
    bounded = app.app.app
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        listener.listen(64)
        port = listener.getsockname()[1]
        server = uvicorn.Server(
            uvicorn.Config(
                app,
                host="127.0.0.1",
                port=port,
                log_level="warning",
                **hardened_uvicorn_config(access_log=False),
            )
        )
        task = asyncio.create_task(server.serve(sockets=[listener]))
        try:
            async with asyncio.timeout(10):
                while not server.started:
                    if task.done():
                        await task
                        raise AssertionError("server exited before readiness")
                    await asyncio.sleep(0.01)
            yield f"http://127.0.0.1:{port}/mcp", token, bounded, reads
        finally:
            server.should_exit = True
            await asyncio.wait_for(task, 10)


@pytest.mark.parametrize("delay", [0, 0.001, 0.01])
async def test_delayed_discovery_receives_complete_rejection(delay):
    async with wire_endpoint() as (url, token, bounded, reads):
        body = b'{"jsonrpc":"2.0","id":1,"method":"server/discover","params":{}}'
        async with httpx.AsyncClient(trust_env=False, timeout=5) as client:
            response = await client.post(
                url,
                content=DelayedBody(body, delay),
                headers={
                    "authorization": f"Bearer {token}",
                    "mcp-protocol-version": "2026-07-28",
                    "content-type": "application/json",
                    "accept": "application/json, text/event-stream",
                    "content-length": str(len(body)),
                },
            )
        assert response.status_code == 400
        assert response.json()["error"]["code"] == "MCP_PROTOCOL_UNSUPPORTED"
        assert len(response.content) == int(response.headers["content-length"])
        assert response.headers["connection"] == "close"
        assert not reads
        assert not bounded._session_manager()._server_instances
        assert bounded._active == bounded._new_session_reservations == 0


@pytest.mark.parametrize("delay", [0.001, 0.01])
async def test_delayed_discovery_client_initializes_and_reads_once(delay):
    methods = Counter()

    async def delay_discovery(request):
        if request.method != "POST":
            return
        body = await request.aread()
        method = json.loads(body)["method"]
        methods[method] += 1
        if method == "server/discover":
            request.stream = DelayedBody(body, delay)

    async with wire_endpoint() as (url, token, bounded, reads):

        def factory(**kwargs):
            return httpx.AsyncClient(
                **kwargs,
                trust_env=False,
                event_hooks={"request": [delay_discovery]},
            )

        transport = StreamableHttpTransport(
            url,
            headers={"authorization": f"Bearer {token}"},
            httpx_client_factory=factory,
        )
        async with asyncio.timeout(15):
            async with Client(transport) as client:
                assert client.session.protocol_version == "2025-11-25"
                assert client.session.initialize_result is not None
                assert client.session.discover_result is None
                result = await client.call_tool("read_value")
                assert result.data == {"value": "read-once"}
                assert len(bounded._session_manager()._server_instances) == 1
        assert methods["server/discover"] == methods["initialize"] == methods["tools/call"] == 1
        assert reads == ["read"]
        assert bounded._active == bounded._new_session_reservations == 0

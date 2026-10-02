"""Integration tests: custom_tools_changed WS events → CustomToolService.

Two layers:
  * WS event handling — a mock Godot plugin pushes tool snapshots over the
    real WebSocket; the server must parse, store, and clear them per
    session, including on disconnect.
  * End-to-end — plugin pushes tools, an MCP client sees them via the
    ``custom_manage(op="list")`` tool (the full plugin → service → FastMCP
    → client chain).

Catalog isolation: CustomToolService is a process-level singleton, so the
WS-event suite clears its catalog before each test — a leftover tool from
a previous test would otherwise leak in and flake assertions.
"""

from __future__ import annotations

import asyncio

import pytest


def _tool_payload(name: str = "gdunit_run", **extra) -> dict:
    base = {
        "name": name,
        "description": f"run {name}",
        "params_schema": {"type": "object"},
        "source": "gdunit4_mcp",
    }
    base.update(extra)
    return base


@pytest.fixture(autouse=True)
def _isolate_catalog():
    """CustomToolService is a process singleton — wipe between tests."""
    from godot_ai.services.custom_tool_service import CustomToolService

    svc = CustomToolService.get_instance()
    svc._tools_by_session.clear()
    yield
    svc._tools_by_session.clear()


class TestCustomToolsWsEvents:
    """Plugin pushes custom_tools_changed → server catalog updates."""

    async def test_event_populates_catalog(self, harness):
        plugin = await harness.connect_plugin(session_id="s-ct-1")
        try:
            await plugin.send_event(
                "custom_tools_changed",
                {"tools": [_tool_payload("t1"), _tool_payload("t2")]},
            )
            await asyncio.sleep(0.05)
            svc = harness.server._custom_tool_service
            assert {t.name for t in svc.get_tools()} == {"t1", "t2"}
            assert svc.get_tool("t1") is not None
        finally:
            await plugin.close()

    async def test_empty_tools_list_clears_session(self, harness):
        plugin = await harness.connect_plugin(session_id="s-ct-2")
        try:
            await plugin.send_event("custom_tools_changed", {"tools": [_tool_payload("t1")]})
            await asyncio.sleep(0.05)
            assert harness.server._custom_tool_service.get_tool("t1") is not None
            ## Empty snapshot = "I have no tools now", not "ignore this".
            await plugin.send_event("custom_tools_changed", {"tools": []})
            await asyncio.sleep(0.05)
            assert harness.server._custom_tool_service.get_tools() == []
        finally:
            await plugin.close()

    async def test_malformed_tool_definition_dropped(self, harness):
        plugin = await harness.connect_plugin(session_id="s-ct-3")
        try:
            ## Missing required `name` — Pydantic ValidationError must be
            ## caught and the catalog left untouched.
            await plugin.send_event(
                "custom_tools_changed",
                {"tools": [{"description": "no name"}]},
            )
            await asyncio.sleep(0.05)
            assert harness.server._custom_tool_service.get_tools() == []
        finally:
            await plugin.close()

    async def test_disconnect_drops_session_tools(self, harness):
        plugin = await harness.connect_plugin(session_id="s-ct-4")
        await plugin.send_event("custom_tools_changed", {"tools": [_tool_payload("only-here")]})
        await asyncio.sleep(0.05)
        assert harness.server._custom_tool_service.get_tool("only-here") is not None
        await plugin.close()
        await asyncio.sleep(0.15)  # let server process the disconnect
        assert harness.server._custom_tool_service.get_tool("only-here") is None

    async def test_two_sessions_merge_catalog(self, harness):
        p1 = await harness.connect_plugin(session_id="s-ct-5a")
        p2 = await harness.connect_plugin(session_id="s-ct-5b")
        try:
            await p1.send_event("custom_tools_changed", {"tools": [_tool_payload("from-a")]})
            await p2.send_event("custom_tools_changed", {"tools": [_tool_payload("from-b")]})
            await asyncio.sleep(0.05)
            names = {t.name for t in harness.server._custom_tool_service.get_tools()}
            assert names == {"from-a", "from-b"}
        finally:
            await p1.close()
            await p2.close()

    async def test_two_sessions_scoped_catalog(self, harness):
        ## "Active session only": a scoped query returns only the owning
        ## session's tools, so list and invoke stay bound to one editor.
        p1 = await harness.connect_plugin(session_id="s-ct-5c")
        p2 = await harness.connect_plugin(session_id="s-ct-5d")
        try:
            await p1.send_event("custom_tools_changed", {"tools": [_tool_payload("from-c")]})
            await p2.send_event("custom_tools_changed", {"tools": [_tool_payload("from-d")]})
            await asyncio.sleep(0.05)
            svc = harness.server._custom_tool_service
            assert {t.name for t in svc.get_tools(session_id="s-ct-5c")} == {"from-c"}
            assert {t.name for t in svc.get_tools(session_id="s-ct-5d")} == {"from-d"}
            ## A tool that exists in one session must not resolve in the other.
            assert svc.get_tool("from-c", session_id="s-ct-5d") is None
        finally:
            await p1.close()
            await p2.close()

    async def test_payload_unwraps_tools_key_not_dict_keys(self, harness):
        ## Regression guard: an earlier version iterated event_data itself
        ## (yielding the dict KEY "tools" as a string) instead of
        ## event_data["tools"]. A string fed to model_validate must be
        ## rejected without corrupting the catalog.
        plugin = await harness.connect_plugin(session_id="s-ct-6")
        try:
            await plugin.send_event(
                "custom_tools_changed",
                {"tools": [_tool_payload("good")]},
            )
            await asyncio.sleep(0.05)
            assert harness.server._custom_tool_service.get_tool("good") is not None
        finally:
            await plugin.close()


class TestCustomManageEndToEnd:
    """Plugin pushes tools → MCP client lists them via custom_manage(list)."""

    async def test_custom_manage_lists_registered_tools(self, mcp_stack):
        client, plugin = mcp_stack
        await plugin.send_event(
            "custom_tools_changed",
            {
                "tools": [
                    _tool_payload(
                        "e2e_tool",
                        deferred=True,
                        timeout_ms=5000,
                        requires_writable=True,
                    )
                ]
            },
        )
        await asyncio.sleep(0.1)  # let the WS event land in the catalog
        result = await client.call_tool("custom_manage", {"op": "list", "params": {}})
        data = result.structured_content
        assert data["tool_count"] == 1
        tool = data["tools"][0]
        assert tool["name"] == "e2e_tool"
        ## The medium-priority payload fields (#781 comment) round-trip
        ## through the WS event → Pydantic model → MCP tool response.
        assert tool["deferred"] is True
        assert tool["timeout_ms"] == 5000
        assert tool["requires_writable"] is True

    async def test_custom_manage_empty_when_no_tools_pushed(self, mcp_stack):
        client, plugin = mcp_stack
        result = await client.call_tool("custom_manage", {"op": "list", "params": {}})
        data = result.structured_content
        assert data["tool_count"] == 0
        assert data["tools"] == []


class TestCustomToolsResource:
    """godot://custom-tools resource content, not just URI registration."""

    async def test_resource_serves_session_tools(self, mcp_stack):
        import json as _json

        client, plugin = mcp_stack
        await plugin.send_event("custom_tools_changed", {"tools": [_tool_payload("res_tool")]})
        await asyncio.sleep(0.1)
        contents = await client.read_resource("godot://custom-tools")
        payload = _json.loads(contents[0].text)
        assert payload["tool_count"] == 1
        assert payload["tools"][0]["name"] == "res_tool"


class TestDisconnectBroadcastFailure:
    """A stalled/broken MCP transport must not break editor disconnect cleanup."""

    async def test_disconnect_cleanup_survives_broadcast_failure(self, harness, monkeypatch):
        svc = harness.server._custom_tool_service

        async def _boom():
            raise RuntimeError("transport torn down")

        plugin = await harness.connect_plugin(session_id="s-ct-fail")
        await plugin.send_event("custom_tools_changed", {"tools": [_tool_payload("doomed")]})
        await asyncio.sleep(0.05)
        assert svc.get_tool("doomed") is not None
        ## monkeypatch, not direct assignment: the service is a process
        ## singleton, so a leaked sabotage would poison later tests.
        monkeypatch.setattr(svc, "notify_tools_change", _boom)
        await plugin.close()
        await asyncio.sleep(0.15)
        ## The raise inside the disconnect finally-block must be swallowed:
        ## tools dropped, server still accepting connections.
        assert svc.get_tool("doomed") is None
        probe = await harness.connect_plugin(session_id="s-ct-after")
        await probe.close()


class TestPromotedToolsEndToEnd:
    """promoted=true specs surface as first-class MCP tools with the
    addon's own schema, and calls route through the custom dispatch path."""

    async def test_promoted_tool_listed_with_schema_and_invocable(self, mcp_stack):
        client, plugin = mcp_stack
        schema = {
            "type": "object",
            "properties": {"suite": {"type": "string"}},
            "required": ["suite"],
        }
        await plugin.send_event(
            "custom_tools_changed",
            {
                "tools": [
                    _tool_payload("gdunit_run", promoted=True, params_schema=schema),
                    _tool_payload("helper", promoted=False),
                ]
            },
        )
        await asyncio.sleep(0.1)

        tools = {t.name: t for t in await client.list_tools()}
        assert "custom_gdunit_run" in tools
        ## The addon's schema is advertised VERBATIM — the whole point of
        ## promotion (agents validate params natively, no custom_manage
        ## indirection). Unpromoted tools stay off the first-class list.
        assert tools["custom_gdunit_run"].input_schema == schema
        assert "custom_helper" not in tools

        async def _answer():
            command = await plugin.recv_command()
            assert command["command"] == "custom_tool:gdunit_run"
            assert command["params"]["suite"] == "smoke"
            await plugin.send_response(command["request_id"], {"passed": 3}, readiness="ready")

        answer = asyncio.ensure_future(_answer())
        result = await client.call_tool("custom_gdunit_run", {"suite": "smoke"})
        await answer
        ## GodotClient.send returns the response DATA (envelope unwrapped).
        assert result.structured_content["passed"] == 3

    async def test_disabled_promotion_is_hidden_and_stale_call_is_specific(self, mcp_stack):
        client, plugin = mcp_stack
        await plugin.send_event(
            "custom_tools_changed", {"tools": [_tool_payload("temp", promoted=True)]}
        )
        await asyncio.sleep(0.1)
        assert any(t.name == "custom_temp" for t in await client.list_tools())
        ## Dock-disable keeps the definition server-side as a hidden
        ## tombstone: fresh discovery omits it while a cached client gets the
        ## domain-specific error promised by the dock contract.
        await plugin.send_event(
            "custom_tools_changed",
            {"tools": [_tool_payload("temp", promoted=True, enabled=False)]},
        )
        await asyncio.sleep(0.1)
        assert not any(t.name == "custom_temp" for t in await client.list_tools())
        stale = await client.call_tool("custom_temp", {"msg": "stale"}, raise_on_error=False)
        assert stale.is_error
        assert stale.structured_content["error"]["code"] == "CUSTOM_TOOL_DISABLED"

    async def test_promotion_unregisters_on_empty_snapshot(self, mcp_stack):
        client, plugin = mcp_stack
        await plugin.send_event(
            "custom_tools_changed", {"tools": [_tool_payload("temp", promoted=True)]}
        )
        await asyncio.sleep(0.1)
        assert any(t.name == "custom_temp" for t in await client.list_tools())
        ## Empty snapshot means addon unregister, not dock-disable.
        await plugin.send_event("custom_tools_changed", {"tools": []})
        await asyncio.sleep(0.1)
        assert not any(t.name == "custom_temp" for t in await client.list_tools())
        ## list_tools() also filters HIDDEN tools, so additionally prove the
        ## registration is gone (not a disabled tombstone): a call must fail
        ## with the generic unknown-tool error. No structured-code assert —
        ## FastMCP is version-ranged, not pinned.
        result = await client.call_tool("custom_temp", {}, raise_on_error=False)
        assert result.is_error

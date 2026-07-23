"""Retry-safety and timeout contracts for the attach stdio proxy."""

from __future__ import annotations

import asyncio
from dataclasses import replace
from types import SimpleNamespace
from typing import Any

import httpx
from mcp.types import CallToolResult, TextContent, Tool

from godot_ai import __version__
from godot_ai.attach.ensure import AttachStartupError, BackendStatus
from godot_ai.attach.proxy import AttachProxyTool, AttachRecoveryMiddleware, _http_client_factory
from godot_ai.fastmcp_compat import ToolResult
from godot_ai.protocol.attach import ATTACH_PROTOCOL_VERSION


def _status() -> BackendStatus:
    return BackendStatus(
        instance_id="instance-a",
        server_version=__version__,
        attach_protocol_version=ATTACH_PROTOCOL_VERSION,
        ws_port=9500,
        exclude_domains=(),
        owner_type="attach",
        tool_catalog_hash="a" * 64,
        package_path="/tmp/godot_ai",
    )


def _context(method: str = "tools/call", tool_name: str = "node_create") -> Any:
    return SimpleNamespace(
        method=method,
        message=SimpleNamespace(name=tool_name, arguments={}),
    )


async def test_tools_call_retries_once_only_after_connect_error() -> None:
    ensures: list[bool] = []
    calls = 0

    async def ensure() -> BackendStatus:
        ensures.append(True)
        return _status()

    async def call_next(_context: Any) -> ToolResult:
        nonlocal calls
        calls += 1
        if calls == 1:
            raise httpx.ConnectError("refused", request=httpx.Request("POST", "http://x"))
        return ToolResult(content=[TextContent(type="text", text="ok")])

    result = await AttachRecoveryMiddleware(ensure).on_call_tool(_context(), call_next)

    assert result.content[0].text == "ok"
    assert calls == 2
    assert ensures == [True, True]


async def test_tools_call_retries_once_after_connect_timeout() -> None:
    calls = 0

    async def ensure() -> BackendStatus:
        return _status()

    async def call_next(_context: Any) -> ToolResult:
        nonlocal calls
        calls += 1
        if calls == 1:
            raise httpx.ConnectTimeout(
                "connect timed out",
                request=httpx.Request("POST", "http://x"),
            )
        return ToolResult(content=[TextContent(type="text", text="ok")])

    result = await AttachRecoveryMiddleware(ensure).on_call_tool(_context(), call_next)

    assert result.content[0].text == "ok"
    assert calls == 2


async def test_ambiguous_tools_call_is_not_replayed() -> None:
    calls = 0

    async def ensure() -> BackendStatus:
        return _status()

    async def call_next(_context: Any) -> ToolResult:
        nonlocal calls
        calls += 1
        raise httpx.ReadError("reset", request=httpx.Request("POST", "http://x"))

    result = await AttachRecoveryMiddleware(ensure).on_call_tool(_context(), call_next)
    mcp_result = result.to_mcp_result()

    assert calls == 1
    assert mcp_result.isError is True
    error = mcp_result.structuredContent["error"]
    assert error["code"] == "TRANSPORT_OUTCOME_UNKNOWN"
    assert error["data"]["retryable"] is False


async def test_test_run_unknown_outcome_names_idempotent_probe() -> None:
    async def ensure() -> BackendStatus:
        return _status()

    async def call_next(_context: Any) -> ToolResult:
        raise TimeoutError("response deadline")

    result = await AttachRecoveryMiddleware(ensure).on_call_tool(
        _context(tool_name="test_run"),
        call_next,
    )
    hint = result.to_mcp_result().structuredContent["error"]["data"]["hint"]

    assert 'test_manage(op="results_get")' in hint


async def test_safe_request_retries_after_transport_failure() -> None:
    calls = 0
    ensures: list[bool] = []

    async def ensure() -> BackendStatus:
        ensures.append(True)
        return _status()

    async def call_next(_context: Any) -> str:
        nonlocal calls
        calls += 1
        if calls == 1:
            raise httpx.ReadError("reset", request=httpx.Request("GET", "http://x"))
        return "tools"

    result = await AttachRecoveryMiddleware(ensure).on_request(
        _context(method="tools/list"),
        call_next,
    )

    assert result == "tools"
    assert calls == 2
    assert ensures == [True, True]


async def test_safe_request_retries_after_backend_instance_change() -> None:
    calls = 0
    ensures = 0

    async def ensure() -> BackendStatus:
        nonlocal ensures
        ensures += 1
        return _status()

    async def observe() -> BackendStatus:
        return replace(_status(), instance_id="instance-b")

    async def call_next(_context: Any) -> str:
        nonlocal calls
        calls += 1
        if calls == 1:
            await asyncio.sleep(1)
        return "tools"

    result = await AttachRecoveryMiddleware(
        ensure,
        observe,
        dispatch_monitor_seconds=0.001,
    ).on_request(_context(method="tools/list"), call_next)

    assert result == "tools"
    assert calls == 2


async def test_mutation_is_not_replayed_after_backend_instance_change() -> None:
    calls = 0
    ensures = 0

    async def ensure() -> BackendStatus:
        nonlocal ensures
        ensures += 1
        return _status()

    async def observe() -> BackendStatus:
        return replace(_status(), instance_id="instance-b")

    async def call_next(_context: Any) -> ToolResult:
        nonlocal calls
        calls += 1
        await asyncio.sleep(1)
        return ToolResult(content=[TextContent(type="text", text="late")])

    result = await AttachRecoveryMiddleware(
        ensure,
        observe,
        dispatch_monitor_seconds=0.001,
    ).on_call_tool(_context(), call_next)
    error = result.to_mcp_result().structuredContent["error"]

    assert calls == 1
    assert error["code"] == "TRANSPORT_OUTCOME_UNKNOWN"


async def test_transient_probe_failure_does_not_cancel_healthy_mutation() -> None:
    ensures = 0
    observations = 0

    async def ensure() -> BackendStatus:
        nonlocal ensures
        ensures += 1
        return _status()

    async def observe() -> BackendStatus | None:
        nonlocal observations
        observations += 1
        if observations == 1:
            return None
        return _status()

    async def call_next(_context: Any) -> ToolResult:
        await asyncio.sleep(0.01)
        return ToolResult(content=[TextContent(type="text", text="healthy")])

    result = await AttachRecoveryMiddleware(
        ensure,
        observe,
        dispatch_monitor_seconds=0.001,
        monitor_failure_threshold=3,
    ).on_call_tool(_context(tool_name="test_run"), call_next)

    assert result.content[0].text == "healthy"
    assert ensures == 1
    assert observations >= 2


async def test_monitor_requires_consecutive_probe_failures() -> None:
    calls = 0

    async def ensure() -> BackendStatus:
        return _status()

    async def observe() -> None:
        return None

    async def call_next(_context: Any) -> ToolResult:
        nonlocal calls
        calls += 1
        await asyncio.sleep(1)
        return ToolResult(content=[TextContent(type="text", text="late")])

    result = await AttachRecoveryMiddleware(
        ensure,
        observe,
        dispatch_monitor_seconds=0.001,
        monitor_failure_threshold=3,
    ).on_call_tool(_context(), call_next)
    error = result.to_mcp_result().structuredContent["error"]

    assert calls == 1
    assert error["code"] == "TRANSPORT_OUTCOME_UNKNOWN"


async def test_incompatible_backend_after_safe_connect_retry_is_structured() -> None:
    ensures = 0

    async def ensure() -> BackendStatus:
        nonlocal ensures
        ensures += 1
        if ensures == 1:
            return _status()
        raise AttachStartupError(
            "NEW_CLIENT_SESSION_REQUIRED",
            "version mismatch",
            hint="reconfigure and start a new session",
        )

    async def call_next(_context: Any) -> ToolResult:
        raise httpx.ConnectError("refused", request=httpx.Request("POST", "http://x"))

    result = await AttachRecoveryMiddleware(ensure).on_call_tool(_context(), call_next)
    error = result.to_mcp_result().structuredContent["error"]

    assert error["code"] == "NEW_CLIENT_SESSION_REQUIRED"
    assert error["data"]["retryable"] is False


async def test_second_connect_refusal_is_retryable_but_not_replayed_again() -> None:
    calls = 0

    async def ensure() -> BackendStatus:
        return _status()

    async def call_next(_context: Any) -> ToolResult:
        nonlocal calls
        calls += 1
        raise httpx.ConnectError("refused", request=httpx.Request("POST", "http://x"))

    result = await AttachRecoveryMiddleware(ensure).on_call_tool(_context(), call_next)
    error = result.to_mcp_result().structuredContent["error"]

    assert calls == 2
    assert error["code"] == "PLUGIN_DISCONNECTED"
    assert error["data"]["retryable"] is True
    assert "backend-<HTTP-port>.log" in error["data"]["hint"]
    assert "Open this project" not in error["data"]["hint"]


async def test_downstream_http_client_has_no_read_deadline() -> None:
    client = _http_client_factory()
    try:
        assert client.timeout.connect == 5.0
        assert client.timeout.read is None
        assert client.timeout.write == 30.0
        assert client.timeout.pool == 5.0
    finally:
        await client.aclose()


async def test_backend_editor_busy_error_passes_through_untouched() -> None:
    payload = {
        "code": "EDITOR_NOT_READY",
        "message": "A test run is already in progress.",
        "data": {
            "sub_code": "EDITOR_TEST_RUNNING",
            "retryable": True,
            "hint": "Wait for the active test run to finish, then retry.",
        },
    }

    class FakeClient:
        async def __aenter__(self):
            return self

        async def __aexit__(self, *_args):
            return None

        async def call_tool_mcp(self, **_kwargs) -> CallToolResult:
            return CallToolResult(
                content=[TextContent(type="text", text=payload["message"])],
                structuredContent={"error": payload},
                isError=True,
            )

    tool = AttachProxyTool.from_mcp_tool(
        lambda: FakeClient(),  # type: ignore[arg-type]
        Tool(name="test_run", inputSchema={"type": "object", "properties": {}}),
    )

    forwarded = (await tool.run({})).to_mcp_result()

    assert forwarded.isError is True
    assert forwarded.structuredContent == {"error": payload}
    assert forwarded.content == [TextContent(type="text", text=payload["message"])]

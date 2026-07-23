"""Retry-safety and timeout contracts for the attach stdio proxy."""

from __future__ import annotations

import asyncio
from dataclasses import replace
from types import SimpleNamespace
from typing import Any

import httpx
import pytest
from mcp.types import CallToolResult, TextContent, Tool

from godot_ai import __version__
from godot_ai.attach import proxy as proxy_module
from godot_ai.attach.ensure import AttachStartupError, BackendStatus
from godot_ai.attach.proxy import (
    AttachProxyProvider,
    AttachProxyTool,
    AttachRecoveryMiddleware,
    _BackendChanged,
    _http_client_factory,
    create_attach_proxy,
)
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
    observed_twice = asyncio.Event()

    async def ensure() -> BackendStatus:
        nonlocal ensures
        ensures += 1
        return _status()

    async def observe() -> BackendStatus | None:
        nonlocal observations
        observations += 1
        if observations == 1:
            return None
        observed_twice.set()
        return _status()

    async def call_next(_context: Any) -> ToolResult:
        await asyncio.wait_for(observed_twice.wait(), timeout=1)
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

    received: dict[str, Any] = {}

    class FakeClient:
        async def __aenter__(self):
            return self

        async def __aexit__(self, *_args):
            return None

        async def call_tool_mcp(self, **kwargs) -> CallToolResult:
            received.update(kwargs)
            return CallToolResult(
                content=[TextContent(type="text", text=payload["message"])],
                structuredContent={"error": payload},
                isError=True,
            )

    tool = AttachProxyTool.from_mcp_tool(
        lambda: FakeClient(),  # type: ignore[arg-type]
        Tool(name="test_run", inputSchema={"type": "object", "properties": {}}),
    )

    context = SimpleNamespace(request_context=SimpleNamespace(meta={"trace": "abc"}))
    forwarded = (await tool.run({}, context)).to_mcp_result()

    assert forwarded.isError is True
    assert forwarded.structuredContent == {"error": payload}
    assert forwarded.content == [TextContent(type="text", text=payload["message"])]
    assert received["meta"] == {"trace": "abc"}


async def test_proxy_provider_lazily_populates_tool_cache(monkeypatch: pytest.MonkeyPatch) -> None:
    provider = AttachProxyProvider(lambda: None)  # type: ignore[arg-type]
    tool = AttachProxyTool.from_mcp_tool(
        lambda: None,  # type: ignore[arg-type]
        Tool(name="editor_state", inputSchema={"type": "object", "properties": {}}),
    )

    async def load_tools():
        provider._attach_tools = {tool.name: tool}
        return [tool]

    monkeypatch.setattr(provider, "_list_tools", load_tools)
    assert await provider._get_tool("editor_state") is tool


async def test_proxy_provider_converts_and_caches_upstream_tools(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    upstream = AttachProxyTool.from_mcp_tool(
        lambda: None,  # type: ignore[arg-type]
        Tool(name="editor_state", inputSchema={"type": "object", "properties": {}}),
    )

    async def list_upstream(_provider):
        return [upstream]

    monkeypatch.setattr(proxy_module.ProxyProvider, "_list_tools", list_upstream)
    provider = AttachProxyProvider(lambda: None)  # type: ignore[arg-type]

    tools = await provider._list_tools()

    assert [tool.name for tool in tools] == ["editor_state"]
    assert provider._attach_tools["editor_state"] is tools[0]


def test_create_attach_proxy_wires_fresh_client_provider_and_outer_middleware(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    captured: dict[str, Any] = {}

    class FakeTransport:
        def __init__(self, url: str, *, httpx_client_factory) -> None:
            captured["url"] = url
            captured["factory"] = httpx_client_factory

    class FakeClient:
        def __init__(self, transport, *, timeout, init_timeout) -> None:
            captured["transport"] = transport
            captured["timeout"] = timeout
            captured["init_timeout"] = init_timeout

    async def ensure() -> BackendStatus:
        return _status()

    async def observe() -> BackendStatus:
        return _status()

    monkeypatch.setattr(proxy_module, "StreamableHttpTransport", FakeTransport)
    monkeypatch.setattr(proxy_module, "Client", FakeClient)

    proxy = create_attach_proxy("http://127.0.0.1:8123/mcp", ensure, observe)
    provider = proxy.providers[1]
    client = provider.client_factory()

    assert isinstance(client, FakeClient)
    assert captured["url"] == "http://127.0.0.1:8123/mcp"
    assert captured["factory"] is proxy_module._http_client_factory
    assert captured["timeout"] is None
    assert captured["init_timeout"] == proxy_module.DEFAULT_INIT_TIMEOUT_SECONDS
    assert isinstance(proxy.middleware[0], AttachRecoveryMiddleware)


async def test_generic_request_delegates_tools_call_to_specialized_hook() -> None:
    ensured = False

    async def ensure() -> BackendStatus:
        nonlocal ensured
        ensured = True
        return _status()

    async def call_next(_context: Any) -> str:
        return "delegated"

    result = await AttachRecoveryMiddleware(ensure).on_request(_context(), call_next)
    assert result == "delegated"
    assert ensured is False


def test_recovery_middleware_rejects_invalid_monitor_threshold() -> None:
    async def ensure() -> BackendStatus:
        return _status()

    with pytest.raises(ValueError, match="at least 1"):
        AttachRecoveryMiddleware(ensure, monitor_failure_threshold=0)


async def test_safe_request_reraises_non_transport_failure() -> None:
    async def ensure() -> BackendStatus:
        return _status()

    async def call_next(_context: Any) -> str:
        raise ValueError("application bug")

    with pytest.raises(ValueError, match="application bug"):
        await AttachRecoveryMiddleware(ensure).on_request(
            _context(method="tools/list"),
            call_next,
        )


async def test_tool_initial_ensure_failure_is_structured() -> None:
    async def ensure() -> BackendStatus:
        raise AttachStartupError(
            "NEW_CLIENT_SESSION_REQUIRED",
            "version mismatch",
            hint="start a new session",
        )

    async def call_next(_context: Any) -> ToolResult:
        raise AssertionError("must not dispatch")

    result = await AttachRecoveryMiddleware(ensure).on_call_tool(_context(), call_next)
    assert result.to_mcp_result().structuredContent["error"]["code"] == (
        "NEW_CLIENT_SESSION_REQUIRED"
    )


async def test_tool_reraises_non_transport_failure() -> None:
    async def ensure() -> BackendStatus:
        return _status()

    async def call_next(_context: Any) -> ToolResult:
        raise ValueError("application bug")

    with pytest.raises(ValueError, match="application bug"):
        await AttachRecoveryMiddleware(ensure).on_call_tool(_context(), call_next)


@pytest.mark.parametrize(
    ("retry_error", "expected_code"),
    [
        (
            AttachStartupError(
                "NEW_CLIENT_SESSION_REQUIRED",
                "version mismatch",
                hint="start a new session",
            ),
            "NEW_CLIENT_SESSION_REQUIRED",
        ),
        (_BackendChanged("instance-a"), "TRANSPORT_OUTCOME_UNKNOWN"),
        (
            httpx.ReadError(
                "reset",
                request=httpx.Request("POST", "http://127.0.0.1/mcp"),
            ),
            "TRANSPORT_OUTCOME_UNKNOWN",
        ),
    ],
)
async def test_single_replay_maps_retry_failures(
    monkeypatch: pytest.MonkeyPatch,
    retry_error: BaseException,
    expected_code: str,
) -> None:
    async def ensure() -> BackendStatus:
        return _status()

    middleware = AttachRecoveryMiddleware(ensure)
    attempts = 0

    async def run_once(*_args):
        nonlocal attempts
        attempts += 1
        if attempts == 1:
            raise httpx.ConnectError(
                "refused",
                request=httpx.Request("POST", "http://127.0.0.1/mcp"),
            )
        raise retry_error

    monkeypatch.setattr(middleware, "_run_with_instance_monitor", run_once)
    result = await middleware.on_call_tool(_context(), lambda _context: None)  # type: ignore[arg-type]
    assert result.to_mcp_result().structuredContent["error"]["code"] == expected_code


async def test_single_replay_reraises_unexpected_retry_failure(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    async def ensure() -> BackendStatus:
        return _status()

    middleware = AttachRecoveryMiddleware(ensure)
    attempts = 0

    async def run_once(*_args):
        nonlocal attempts
        attempts += 1
        if attempts == 1:
            raise httpx.ConnectError(
                "refused",
                request=httpx.Request("POST", "http://127.0.0.1/mcp"),
            )
        raise ValueError("application bug")

    monkeypatch.setattr(middleware, "_run_with_instance_monitor", run_once)
    with pytest.raises(ValueError, match="application bug"):
        await middleware.on_call_tool(_context(), lambda _context: None)  # type: ignore[arg-type]


async def test_backend_monitor_requires_observer() -> None:
    async def ensure() -> BackendStatus:
        return _status()

    middleware = AttachRecoveryMiddleware(ensure)
    with pytest.raises(RuntimeError, match="without an observer"):
        await middleware._wait_for_backend_change("instance-a")


async def test_backend_monitor_counts_observer_exceptions() -> None:
    async def ensure() -> BackendStatus:
        return _status()

    async def observe() -> BackendStatus:
        raise RuntimeError("transient probe failure")

    middleware = AttachRecoveryMiddleware(
        ensure,
        observe,
        dispatch_monitor_seconds=0,
        monitor_failure_threshold=1,
    )
    await middleware._wait_for_backend_change("instance-a")

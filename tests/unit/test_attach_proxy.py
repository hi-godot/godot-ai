"""Retry-safety and timeout contracts for the attach stdio proxy."""

from __future__ import annotations

import asyncio
from dataclasses import replace
from types import SimpleNamespace
from typing import Any

import httpx
import pytest
from mcp.shared.exceptions import McpError
from mcp.types import CallToolResult, ErrorData, TextContent, Tool

from godot_ai import __version__
from godot_ai.attach import proxy as proxy_module
from godot_ai.attach.ensure import AttachStartupError, BackendStatus
from godot_ai.attach.proxy import (
    _OPERATION_TRACE,
    AttachProxyProvider,
    AttachProxyTool,
    AttachRecoveryMiddleware,
    OperationTrace,
    RecordingAsyncHTTPTransport,
    TransportFailure,
    _BackendChanged,
    _exception_chain,
    _http_client_factory,
    _is_proven_pre_dispatch_failure,
    _record_http_error_response,
    _record_transport_failure,
    _request_phase,
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


async def test_second_laundered_initialize_failure_is_not_outcome_unknown() -> None:
    calls = 0

    async def ensure() -> BackendStatus:
        return _status()

    async def call_next(_context: Any) -> ToolResult:
        nonlocal calls
        calls += 1
        request = httpx.Request(
            "POST",
            "http://127.0.0.1/mcp",
            json={"jsonrpc": "2.0", "id": 1, "method": "initialize"},
        )
        raw = httpx.ReadError("initialize stream lost", request=request)
        trace = _OPERATION_TRACE.get()
        assert trace is not None
        trace.failures.append(
            TransportFailure(
                phase="initialize",
                error=raw,
                connect_class=False,
            )
        )
        raise McpError(ErrorData(code=-32000, message="Connection closed"))

    result = await AttachRecoveryMiddleware(ensure).on_call_tool(_context(), call_next)
    error = result.to_mcp_result().structuredContent["error"]

    assert calls == 2
    assert error["code"] == "PLUGIN_DISCONNECTED"
    assert error["data"]["retryable"] is True


async def test_downstream_http_client_has_no_read_deadline() -> None:
    client = _http_client_factory()
    try:
        assert client.timeout.connect == 5.0
        assert client.timeout.read is None
        assert client.timeout.write == 30.0
        assert client.timeout.pool == 5.0
    finally:
        await client.aclose()


def test_exception_chain_descends_exception_groups() -> None:
    request = httpx.Request("POST", "http://127.0.0.1/mcp")
    leaf = httpx.ConnectTimeout("connect timed out", request=request)
    group = ExceptionGroup("transport", [ValueError("other"), leaf])

    assert leaf in _exception_chain(group)


def test_exception_chain_follows_causes_without_looping() -> None:
    root = RuntimeError("root")
    outer = ValueError("outer")
    outer.__cause__ = root
    root.__context__ = outer

    assert _exception_chain(outer) == [outer, root]


@pytest.mark.parametrize(
    ("payload", "expected"),
    [
        ([{"method": "tools/call"}], "http"),
        ({"method": "initialize"}, "initialize"),
        ({"method": "notifications/initialized"}, "initialized-notification"),
    ],
)
def test_request_phase_handles_non_object_and_initialized_notification(
    payload: Any,
    expected: str,
) -> None:
    request = httpx.Request("POST", "http://127.0.0.1/mcp", json=payload)

    assert _request_phase(request) == expected


def test_request_phase_handles_malformed_json() -> None:
    request = httpx.Request("POST", "http://127.0.0.1/mcp", content=b"{")

    assert _request_phase(request) == "http"


def test_transport_failure_without_operation_trace_is_ignored() -> None:
    request = httpx.Request("POST", "http://127.0.0.1/mcp")

    _record_transport_failure(request, httpx.ReadError("reset", request=request))


async def test_response_hook_records_http_status_error() -> None:
    request = httpx.Request(
        "POST",
        "http://127.0.0.1/mcp",
        json={"jsonrpc": "2.0", "id": 1, "method": "tools/list"},
    )
    response = httpx.Response(503, request=request)
    trace = OperationTrace()
    token = _OPERATION_TRACE.set(trace)
    try:
        await _record_http_error_response(response)
    finally:
        _OPERATION_TRACE.reset(token)

    assert len(trace.failures) == 1
    assert trace.failures[0].phase == "tools/list"
    assert trace.failures[0].status_code == 503
    assert isinstance(trace.failures[0].error, httpx.HTTPStatusError)


async def test_response_hook_ignores_success() -> None:
    request = httpx.Request("POST", "http://127.0.0.1/mcp")
    trace = OperationTrace()
    token = _OPERATION_TRACE.set(trace)
    try:
        await _record_http_error_response(httpx.Response(200, request=request))
    finally:
        _OPERATION_TRACE.reset(token)

    assert trace.failures == []


async def test_recording_transport_captures_raw_transport_error(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    async def reset_transport(
        _self: httpx.AsyncHTTPTransport,
        request: httpx.Request,
    ) -> httpx.Response:
        raise httpx.ReadError("reset", request=request)

    monkeypatch.setattr(httpx.AsyncHTTPTransport, "handle_async_request", reset_transport)
    trace = OperationTrace()
    token = _OPERATION_TRACE.set(trace)
    transport = RecordingAsyncHTTPTransport()
    request = httpx.Request(
        "POST",
        "http://127.0.0.1/mcp",
        json={"jsonrpc": "2.0", "id": 1, "method": "tools/call"},
    )
    try:
        with pytest.raises(httpx.ReadError, match="reset"):
            await transport.handle_async_request(request)
    finally:
        await transport.aclose()
        _OPERATION_TRACE.reset(token)

    assert len(trace.failures) == 1
    assert trace.failures[0].phase == "tools/call"
    assert trace.failures[0].connect_class is False


def test_shared_transport_trace_classifies_laundered_connect_timeout() -> None:
    request = httpx.Request(
        "POST",
        "http://127.0.0.1/mcp",
        json={"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {}},
    )
    raw = httpx.ConnectTimeout("connect timed out", request=request)
    trace = OperationTrace(
        failures=[
            TransportFailure(
                phase="tools/call",
                error=raw,
                connect_class=True,
            )
        ]
    )
    token = _OPERATION_TRACE.set(trace)
    try:
        wrapped = McpError(ErrorData(code=-32000, message="request timed out"))
        assert _is_proven_pre_dispatch_failure(wrapped) is True
    finally:
        _OPERATION_TRACE.reset(token)


async def test_recording_transport_does_not_turn_cancellation_into_failure(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    async def cancel_transport(
        _self: httpx.AsyncHTTPTransport,
        _request: httpx.Request,
    ) -> httpx.Response:
        raise asyncio.CancelledError

    monkeypatch.setattr(httpx.AsyncHTTPTransport, "handle_async_request", cancel_transport)
    trace = OperationTrace()
    token = _OPERATION_TRACE.set(trace)
    transport = RecordingAsyncHTTPTransport()
    try:
        with pytest.raises(asyncio.CancelledError):
            await transport.handle_async_request(httpx.Request("POST", "http://127.0.0.1/mcp"))
        assert trace.failures == []
    finally:
        await transport.aclose()
        _OPERATION_TRACE.reset(token)


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


async def test_tool_startup_error_preserves_code_data_hint_and_retryability() -> None:
    async def ensure() -> BackendStatus:
        raise AttachStartupError(
            "PORT_OCCUPIED",
            "foreign listener",
            hint="free the port",
            data={"port": 8123},
        )

    result = await AttachRecoveryMiddleware(ensure).on_call_tool(
        _context(),
        lambda _context: None,  # type: ignore[arg-type]
    )
    error = result.to_mcp_result().structuredContent["error"]

    assert error["code"] == "PORT_OCCUPIED"
    assert error["data"] == {
        "port": 8123,
        "retryable": False,
        "hint": "free the port",
        "sub_code": "PORT_OCCUPIED",
    }


async def test_safe_request_initial_startup_error_is_protocol_structured() -> None:
    async def ensure() -> BackendStatus:
        raise AttachStartupError(
            "ATTACH_LOCK_TIMEOUT",
            "startup lock busy",
            hint="retry shortly",
            retryable=True,
            data={"path": "attach.lock"},
        )

    with pytest.raises(McpError) as exc_info:
        await AttachRecoveryMiddleware(ensure).on_request(
            _context(method="tools/list"),
            lambda _context: None,  # type: ignore[arg-type]
        )

    assert exc_info.value.error.data == {
        "path": "attach.lock",
        "retryable": True,
        "hint": "retry shortly",
        "code": "ATTACH_LOCK_TIMEOUT",
        "sub_code": "ATTACH_LOCK_TIMEOUT",
    }


async def test_safe_request_second_backend_change_is_protocol_structured(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    async def ensure() -> BackendStatus:
        return _status()

    middleware = AttachRecoveryMiddleware(ensure)

    async def always_changed(*_args):
        raise _BackendChanged("instance-a")

    monkeypatch.setattr(middleware, "_run_with_instance_monitor", always_changed)
    with pytest.raises(McpError) as exc_info:
        await middleware.on_request(
            _context(method="tools/list"),
            lambda _context: None,  # type: ignore[arg-type]
        )

    assert exc_info.value.error.data["code"] == "PLUGIN_DISCONNECTED"
    assert exc_info.value.error.data["retryable"] is True


async def test_safe_request_retry_preserves_startup_error(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    ensures = 0

    async def ensure() -> BackendStatus:
        nonlocal ensures
        ensures += 1
        if ensures == 1:
            return _status()
        raise AttachStartupError(
            "BACKEND_START_TIMEOUT",
            "backend still starting",
            hint="retry",
            retryable=True,
            data={"log_path": "backend.log"},
        )

    middleware = AttachRecoveryMiddleware(ensure)

    async def changed_once(*_args):
        raise _BackendChanged("instance-a")

    monkeypatch.setattr(middleware, "_run_with_instance_monitor", changed_once)
    with pytest.raises(McpError) as exc_info:
        await middleware.on_request(
            _context(method="tools/list"),
            lambda _context: None,  # type: ignore[arg-type]
        )

    assert exc_info.value.error.data["code"] == "BACKEND_START_TIMEOUT"
    assert exc_info.value.error.data["log_path"] == "backend.log"


async def test_safe_request_preserves_startup_error_from_dispatch(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    async def ensure() -> BackendStatus:
        return _status()

    middleware = AttachRecoveryMiddleware(ensure)

    async def fail_during_dispatch(*_args):
        raise AttachStartupError(
            "PORT_OCCUPIED",
            "foreign listener",
            hint="free the port",
            data={"port": 8123},
        )

    monkeypatch.setattr(middleware, "_run_with_instance_monitor", fail_during_dispatch)
    with pytest.raises(McpError) as exc_info:
        await middleware.on_request(
            _context(method="tools/list"),
            lambda _context: None,  # type: ignore[arg-type]
        )

    assert exc_info.value.error.data["code"] == "PORT_OCCUPIED"
    assert exc_info.value.error.data["port"] == 8123


async def test_safe_request_second_transport_failure_is_protocol_structured(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    async def ensure() -> BackendStatus:
        return _status()

    middleware = AttachRecoveryMiddleware(ensure)

    async def always_reset(*_args):
        raise httpx.ReadError(
            "reset",
            request=httpx.Request("POST", "http://127.0.0.1/mcp"),
        )

    monkeypatch.setattr(middleware, "_run_with_instance_monitor", always_reset)
    with pytest.raises(McpError) as exc_info:
        await middleware.on_request(
            _context(method="tools/list"),
            lambda _context: None,  # type: ignore[arg-type]
        )

    assert exc_info.value.error.data["code"] == "PLUGIN_DISCONNECTED"
    assert exc_info.value.error.data["retryable"] is True


async def test_http_status_error_is_retried_for_safe_request() -> None:
    calls = 0

    async def ensure() -> BackendStatus:
        return _status()

    async def call_next(_context: Any) -> str:
        nonlocal calls
        calls += 1
        if calls == 1:
            request = httpx.Request("POST", "http://127.0.0.1/mcp")
            response = httpx.Response(503, request=request)
            raise httpx.HTTPStatusError("unavailable", request=request, response=response)
        return "tools"

    result = await AttachRecoveryMiddleware(ensure).on_request(
        _context(method="tools/list"),
        call_next,
    )

    assert result == "tools"
    assert calls == 2


async def test_cancelling_call_cleans_up_monitor_and_downstream_tasks() -> None:
    probes = 0
    call_cancelled = asyncio.Event()

    async def ensure() -> BackendStatus:
        return _status()

    async def observe() -> BackendStatus:
        nonlocal probes
        probes += 1
        return _status()

    async def call_next(_context: Any) -> ToolResult:
        try:
            await asyncio.Event().wait()
        finally:
            call_cancelled.set()

    task = asyncio.create_task(
        AttachRecoveryMiddleware(
            ensure,
            observe,
            dispatch_monitor_seconds=0.001,
        ).on_call_tool(_context(tool_name="test_run"), call_next)
    )
    while probes < 2:
        await asyncio.sleep(0.001)
    task.cancel()
    with pytest.raises(asyncio.CancelledError):
        await task
    await asyncio.wait_for(call_cancelled.wait(), timeout=1)
    probe_count = probes
    await asyncio.sleep(0.02)
    assert probes == probe_count


async def test_safe_request_cancellation_bypasses_recorded_transport_recovery() -> None:
    calls = 0

    async def ensure() -> BackendStatus:
        return _status()

    async def call_next(_context: Any) -> str:
        nonlocal calls
        calls += 1
        trace = _OPERATION_TRACE.get()
        assert trace is not None
        trace.failures.append(
            TransportFailure(
                phase="tools/list",
                error=httpx.HTTPStatusError(
                    "handled response",
                    request=httpx.Request("POST", "http://127.0.0.1/mcp"),
                    response=httpx.Response(503),
                ),
                connect_class=False,
                status_code=503,
            )
        )
        raise asyncio.CancelledError

    with pytest.raises(asyncio.CancelledError):
        await AttachRecoveryMiddleware(ensure).on_request(
            _context(method="tools/list"),
            call_next,
        )

    assert calls == 1


async def test_replay_cancellation_bypasses_recorded_transport_recovery() -> None:
    calls = 0
    ensures = 0

    async def ensure() -> BackendStatus:
        nonlocal ensures
        ensures += 1
        return _status()

    async def call_next(_context: Any) -> ToolResult:
        nonlocal calls
        calls += 1
        if calls == 1:
            raise httpx.ConnectError(
                "refused",
                request=httpx.Request("POST", "http://127.0.0.1/mcp"),
            )
        trace = _OPERATION_TRACE.get()
        assert trace is not None
        trace.failures.append(
            TransportFailure(
                phase="initialize",
                error=httpx.ConnectError(
                    "recorded",
                    request=httpx.Request("POST", "http://127.0.0.1/mcp"),
                ),
                connect_class=True,
            )
        )
        raise asyncio.CancelledError

    with pytest.raises(asyncio.CancelledError):
        await AttachRecoveryMiddleware(ensure).on_call_tool(_context(), call_next)

    assert calls == 2
    assert ensures == 2


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

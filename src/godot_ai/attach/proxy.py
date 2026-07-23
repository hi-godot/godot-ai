"""FastMCP stdio proxy with conservative backend recovery semantics."""

from __future__ import annotations

import asyncio
import contextlib
from collections.abc import Awaitable, Callable, Sequence
from typing import Any

import anyio
import httpx
from fastmcp import Client, FastMCP
from fastmcp.client.transports import StreamableHttpTransport
from fastmcp.server.middleware import CallNext, Middleware, MiddlewareContext
from fastmcp.server.providers.proxy import ProxyProvider, ProxyTool
from mcp.types import CallToolRequestParams, TextContent

from godot_ai.attach.ensure import AttachStartupError, BackendStatus
from godot_ai.fastmcp_compat import ToolResult
from godot_ai.middleware.godot_command_error import GodotCommandErrorToolResult
from godot_ai.protocol.errors import ErrorCode

DEFAULT_CONNECT_TIMEOUT_SECONDS = 5.0
DEFAULT_WRITE_TIMEOUT_SECONDS = 30.0
DEFAULT_POOL_TIMEOUT_SECONDS = 5.0
DEFAULT_INIT_TIMEOUT_SECONDS = 10.0
DEFAULT_DISPATCH_MONITOR_SECONDS = 1.0
DEFAULT_MONITOR_PROBE_TIMEOUT_SECONDS = 5.0
DEFAULT_MONITOR_FAILURE_THRESHOLD = 3

EnsureReady = Callable[[], Awaitable[BackendStatus]]
ObserveBackend = Callable[[], Awaitable[BackendStatus | None]]


class _BackendChanged(RuntimeError):
    """The monitored backend identity changed while an operation was in flight."""


class AttachProxyTool(ProxyTool):
    """Proxy one backend tool while preserving its complete MCP error result."""

    async def run(self, arguments: dict[str, Any], context: Any = None) -> ToolResult:
        backend_name = self._backend_name or self.name
        client = await self._get_client()
        async with client:
            meta: dict[str, Any] | None = None
            if context is not None and hasattr(context, "request_context"):
                request_meta = getattr(context.request_context, "meta", None)
                if request_meta:
                    meta = dict(request_meta)
            result = await client.call_tool_mcp(
                name=backend_name,
                arguments=arguments,
                meta=meta,
            )
        result_type = GodotCommandErrorToolResult if result.isError else ToolResult
        return result_type(
            content=result.content,
            structured_content=result.structuredContent,
            meta=result.meta,
        )


class AttachProxyProvider(ProxyProvider):
    """Use FastMCP's proxy surface except for its pre-3.4 error collapsing."""

    def __init__(self, client_factory: Callable[[], Client[Any]]) -> None:
        super().__init__(client_factory)
        self._attach_tools: dict[str, AttachProxyTool] = {}

    async def _list_tools(self) -> Sequence[AttachProxyTool]:
        upstream_tools = await super()._list_tools()
        tools = [
            AttachProxyTool.from_mcp_tool(self.client_factory, tool.to_mcp_tool())
            for tool in upstream_tools
        ]
        self._attach_tools = {tool.name: tool for tool in tools}
        return tools

    async def _get_tool(self, name: str, version: Any = None) -> AttachProxyTool | None:
        # Tool names are unique in the backend's static catalog. Version is a
        # FastMCP provider selector, not the Godot AI package version gate.
        if not self._attach_tools:
            await self._list_tools()
        return self._attach_tools.get(name)


def _http_client_factory(
    headers: dict[str, str] | None = None,
    auth: httpx.Auth | None = None,
    follow_redirects: bool = True,
    **_kwargs: Any,
) -> httpx.AsyncClient:
    """Build the downstream client with no post-dispatch read deadline.

    Connect/write/pool phases remain bounded. The read phase is deliberately
    unbounded because the backend owns tool budgets (``test_run`` is 300s) and
    a bridge-side deadline could turn a completed mutation into an ambiguous
    timeout at exactly the server budget boundary.
    """

    timeout = httpx.Timeout(
        connect=DEFAULT_CONNECT_TIMEOUT_SECONDS,
        read=None,
        write=DEFAULT_WRITE_TIMEOUT_SECONDS,
        pool=DEFAULT_POOL_TIMEOUT_SECONDS,
    )
    return httpx.AsyncClient(
        headers=headers,
        auth=auth,
        follow_redirects=follow_redirects,
        timeout=timeout,
    )


def _exception_chain(exc: BaseException) -> list[BaseException]:
    chain: list[BaseException] = []
    seen: set[int] = set()
    current: BaseException | None = exc
    while current is not None and id(current) not in seen:
        chain.append(current)
        seen.add(id(current))
        current = current.__cause__ or current.__context__
    return chain


def _is_proven_connect_failure(exc: BaseException) -> bool:
    return any(
        isinstance(item, (httpx.ConnectError, httpx.ConnectTimeout))
        for item in _exception_chain(exc)
    )


def _is_transport_failure(exc: BaseException) -> bool:
    transport_types = (
        httpx.TransportError,
        TimeoutError,
        anyio.ClosedResourceError,
        anyio.BrokenResourceError,
        anyio.EndOfStream,
    )
    return any(isinstance(item, transport_types) for item in _exception_chain(exc))


def _error_result(
    code: ErrorCode,
    message: str,
    hint: str,
    *,
    retryable: bool = False,
) -> ToolResult:
    payload = {
        "code": code.value,
        "message": message,
        "data": {
            "sub_code": code.value,
            "retryable": retryable,
            "hint": hint,
        },
    }
    return GodotCommandErrorToolResult(
        content=[TextContent(type="text", text=f"{message} {hint}")],
        structured_content={"error": payload},
    )


def _outcome_unknown_result(tool_name: str) -> ToolResult:
    hint = (
        "The call may have completed and was deliberately not retried. Inspect the target "
        "state before deciding whether another call is safe."
    )
    if tool_name == "test_run":
        hint += ' Use test_manage(op="results_get") to inspect surviving partial results.'
    return _error_result(
        ErrorCode.TRANSPORT_OUTCOME_UNKNOWN,
        f"Transport failed after dispatch of {tool_name!r} may have begun.",
        hint,
    )


def _new_session_result(exc: AttachStartupError) -> ToolResult:
    return _error_result(ErrorCode.NEW_CLIENT_SESSION_REQUIRED, exc.message, exc.hint)


def _backend_unavailable_result() -> ToolResult:
    return _error_result(
        ErrorCode.PLUGIN_DISCONNECTED,
        "The shared Godot AI backend is not accepting connections.",
        "The backend may be crash-looping. Inspect backend-<HTTP-port>.log in the "
        "Godot AI runtime directory, correct the reported failure, then retry the "
        "same call. Restarting the MCP client is not required.",
        retryable=True,
    )


class AttachRecoveryMiddleware(Middleware):
    """Recover safe requests and never replay an ambiguously dispatched call."""

    def __init__(
        self,
        ensure_ready: EnsureReady,
        observe_backend: ObserveBackend | None = None,
        *,
        dispatch_monitor_seconds: float = DEFAULT_DISPATCH_MONITOR_SECONDS,
        monitor_failure_threshold: int = DEFAULT_MONITOR_FAILURE_THRESHOLD,
    ) -> None:
        if monitor_failure_threshold < 1:
            raise ValueError("monitor_failure_threshold must be at least 1")
        self._ensure_ready = ensure_ready
        self._observe_backend = observe_backend
        self._dispatch_monitor_seconds = dispatch_monitor_seconds
        self._monitor_failure_threshold = monitor_failure_threshold

    async def on_request(
        self,
        context: MiddlewareContext[Any],
        call_next: CallNext[Any, Any],
    ) -> Any:
        # tools/call has its stricter handler below. Discovery, resources,
        ## prompts, and initialize are idempotent and may retry once after any
        ## recognized transport failure.
        if context.method == "tools/call":
            return await call_next(context)
        initial_status = await self._ensure_ready()
        try:
            return await self._run_with_instance_monitor(context, call_next, initial_status)
        except _BackendChanged:
            retry_status = await self._ensure_ready()
            return await self._run_with_instance_monitor(context, call_next, retry_status)
        except BaseException as exc:
            if not _is_transport_failure(exc):
                raise
            retry_status = await self._ensure_ready()
            return await self._run_with_instance_monitor(context, call_next, retry_status)

    async def on_call_tool(
        self,
        context: MiddlewareContext[CallToolRequestParams],
        call_next: CallNext[CallToolRequestParams, ToolResult],
    ) -> ToolResult:
        try:
            initial_status = await self._ensure_ready()
        except AttachStartupError as ensure_exc:
            return _new_session_result(ensure_exc)
        try:
            return await self._run_with_instance_monitor(context, call_next, initial_status)
        except _BackendChanged:
            return _outcome_unknown_result(context.message.name)
        except BaseException as exc:
            if not _is_proven_connect_failure(exc):
                if _is_transport_failure(exc):
                    return _outcome_unknown_result(context.message.name)
                raise

        ## ConnectError proves no HTTP connection was established and therefore
        ## no request bytes reached the backend. This is the sole tools/call
        ## replay path.
        try:
            retry_status = await self._ensure_ready()
        except AttachStartupError as ensure_exc:
            return _new_session_result(ensure_exc)
        try:
            return await self._run_with_instance_monitor(context, call_next, retry_status)
        except AttachStartupError as ensure_exc:
            return _new_session_result(ensure_exc)
        except _BackendChanged:
            return _outcome_unknown_result(context.message.name)
        except BaseException as retry_exc:
            if _is_proven_connect_failure(retry_exc):
                # The single safe replay was also refused before dispatch. Do
                # not mislabel this as an ambiguous mutation, and do not loop.
                return _backend_unavailable_result()
            if _is_transport_failure(retry_exc):
                return _outcome_unknown_result(context.message.name)
            raise

    async def _run_with_instance_monitor(
        self,
        context: MiddlewareContext[Any],
        call_next: CallNext[Any, Any],
        initial_status: BackendStatus,
    ) -> Any:
        """Run one operation while watching backend identity, without a time limit."""

        if self._observe_backend is None:
            return await call_next(context)

        call_task = asyncio.create_task(call_next(context))
        monitor_task = asyncio.create_task(
            self._wait_for_backend_change(initial_status.instance_id)
        )
        done, _pending = await asyncio.wait(
            {call_task, monitor_task},
            return_when=asyncio.FIRST_COMPLETED,
        )
        if call_task in done:
            monitor_task.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await monitor_task
            return await call_task

        # The backend disappeared, changed identity, or became incompatible
        # after dispatch. Cancel only the local downstream wait; never replay
        # the operation, whose effects may already have committed.
        call_task.cancel()
        with contextlib.suppress(asyncio.CancelledError, Exception):
            await call_task
        raise _BackendChanged(initial_status.instance_id)

    async def _wait_for_backend_change(self, initial_instance_id: str) -> None:
        observe_backend = self._observe_backend
        if observe_backend is None:
            raise RuntimeError("backend monitor started without an observer")
        consecutive_failures = 0
        while True:
            await asyncio.sleep(self._dispatch_monitor_seconds)
            try:
                status = await observe_backend()
            except Exception:  # noqa: BLE001 - an inconclusive observation is counted below
                status = None
            if status is None:
                consecutive_failures += 1
                if consecutive_failures >= self._monitor_failure_threshold:
                    return
                continue
            consecutive_failures = 0
            if status.instance_id != initial_instance_id:
                return


def create_attach_proxy(
    mcp_url: str,
    ensure_ready: EnsureReady,
    observe_backend: ObserveBackend,
) -> FastMCP[Any]:
    """Create a stdio-facing proxy using fresh downstream sessions per request."""

    def backend_client() -> Client[Any]:
        transport = StreamableHttpTransport(
            mcp_url,
            httpx_client_factory=_http_client_factory,
        )
        # A new disconnected client and transport per provider operation keeps
        # the bridge sessionless. MCP request deadlines are disabled; the HTTP
        # factory separately retains bounded connect/write/pool phases.
        return Client(
            transport,
            timeout=None,
            init_timeout=DEFAULT_INIT_TIMEOUT_SECONDS,
        )

    proxy = FastMCP("Godot AI attach")
    proxy.add_provider(AttachProxyProvider(backend_client))
    # First-added is outermost, so insert recovery at position zero to catch
    # provider initialization and operation failures.
    proxy.middleware.insert(
        0,
        AttachRecoveryMiddleware(ensure_ready, observe_backend),
    )
    return proxy

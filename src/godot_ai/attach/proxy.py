"""FastMCP stdio proxy with conservative backend recovery semantics."""

from __future__ import annotations

import asyncio
import contextvars
import json
from collections.abc import Awaitable, Callable, Sequence
from dataclasses import dataclass, field
from typing import Any

import anyio
import httpx
from fastmcp import Client, FastMCP
from fastmcp.client.transports import StreamableHttpTransport
from fastmcp.server.middleware import CallNext, Middleware, MiddlewareContext
from fastmcp.server.providers.proxy import ProxyProvider, ProxyTool
from mcp.shared.exceptions import McpError
from mcp.types import INTERNAL_ERROR, CallToolRequestParams, ErrorData, TextContent

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


@dataclass(frozen=True)
class TransportFailure:
    """One raw downstream transport failure captured before FastMCP wraps it."""

    phase: str
    error: BaseException
    connect_class: bool
    status_code: int | None = None


@dataclass
class OperationTrace:
    """Mutable trace shared with AnyIO child tasks through a ContextVar."""

    failures: list[TransportFailure] = field(default_factory=list)

    def begin_attempt(self) -> None:
        self.failures.clear()


_OPERATION_TRACE: contextvars.ContextVar[OperationTrace | None] = contextvars.ContextVar(
    "godot_ai_attach_operation_trace",
    default=None,
)


def _request_phase(request: httpx.Request) -> str:
    """Derive the phase from this request body, never shared mutable state."""

    try:
        payload = json.loads(request.content)
    except (json.JSONDecodeError, TypeError, UnicodeDecodeError, httpx.RequestNotRead):
        return "http"
    if not isinstance(payload, dict):
        return "http"
    method = payload.get("method")
    if method == "initialize":
        return "initialize"
    if method == "notifications/initialized":
        return "initialized-notification"
    return str(method) if isinstance(method, str) else "http"


def _record_transport_failure(
    request: httpx.Request,
    error: BaseException,
    *,
    status_code: int | None = None,
) -> None:
    trace = _OPERATION_TRACE.get()
    if trace is None:
        return
    trace.failures.append(
        TransportFailure(
            phase=_request_phase(request),
            error=error,
            connect_class=isinstance(error, (httpx.ConnectError, httpx.ConnectTimeout)),
            status_code=status_code,
        )
    )


class RecordingAsyncHTTPTransport(httpx.AsyncHTTPTransport):
    """Capture raw httpx failures before the MCP client task group launders them."""

    async def handle_async_request(self, request: httpx.Request) -> httpx.Response:
        try:
            return await super().handle_async_request(request)
        except Exception as exc:
            _record_transport_failure(request, exc)
            raise


async def _record_http_error_response(response: httpx.Response) -> None:
    """Record received HTTP errors without changing when the SDK raises them."""

    if not response.is_error:
        return
    try:
        response.raise_for_status()
    except httpx.HTTPStatusError as exc:
        _record_transport_failure(
            response.request,
            exc,
            status_code=response.status_code,
        )


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
        transport=RecordingAsyncHTTPTransport(),
        event_hooks={"response": [_record_http_error_response]},
        trust_env=False,
    )


def _exception_chain(exc: BaseException) -> list[BaseException]:
    chain: list[BaseException] = []
    seen: set[int] = set()
    pending: list[BaseException] = [exc]
    while pending:
        current = pending.pop()
        if id(current) in seen:
            continue
        chain.append(current)
        seen.add(id(current))
        if isinstance(current, BaseExceptionGroup):
            pending.extend(reversed(current.exceptions))
        linked = current.__cause__ or current.__context__
        if linked is not None:
            pending.append(linked)
    return chain


def _trace_failures() -> tuple[TransportFailure, ...]:
    trace = _OPERATION_TRACE.get()
    return tuple(trace.failures) if trace is not None else ()


def _is_proven_pre_dispatch_failure(exc: BaseException) -> bool:
    failures = _trace_failures()
    if failures:
        # Initialization failures prove that the operation request was never
        # sent. Once the operation request itself exists, only connect-class
        # failures prove that no request bytes reached the backend.
        return any(
            failure.phase == "initialize"
            or (failure.phase == "tools/call" and failure.connect_class)
            for failure in failures
        )
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
        httpx.HTTPStatusError,
    )
    return bool(_trace_failures()) or any(
        isinstance(item, transport_types) for item in _exception_chain(exc)
    )


def _error_result(
    code: ErrorCode | str,
    message: str,
    hint: str,
    *,
    retryable: bool = False,
    data: dict[str, Any] | None = None,
) -> ToolResult:
    code_value = code.value if isinstance(code, ErrorCode) else code
    details = dict(data or {})
    details.setdefault("sub_code", code_value)
    details.setdefault("retryable", retryable)
    details.setdefault("hint", hint)
    payload = {
        "code": code_value,
        "message": message,
        "data": details,
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


def _startup_error_result(exc: AttachStartupError) -> ToolResult:
    return _error_result(
        exc.code,
        exc.message,
        exc.hint,
        retryable=bool(exc.data.get("retryable", False)),
        data=exc.data,
    )


def _mcp_error(
    code: ErrorCode | str,
    message: str,
    hint: str,
    *,
    retryable: bool,
    data: dict[str, Any] | None = None,
) -> McpError:
    code_value = code.value if isinstance(code, ErrorCode) else code
    details = dict(data or {})
    details.setdefault("code", code_value)
    details.setdefault("sub_code", code_value)
    details.setdefault("retryable", retryable)
    details.setdefault("hint", hint)
    return McpError(ErrorData(code=INTERNAL_ERROR, message=message, data=details))


def _startup_mcp_error(exc: AttachStartupError) -> McpError:
    return _mcp_error(
        exc.code,
        exc.message,
        exc.hint,
        retryable=bool(exc.data.get("retryable", False)),
        data=exc.data,
    )


def _backend_unstable_mcp_error() -> McpError:
    return _mcp_error(
        ErrorCode.PLUGIN_DISCONNECTED,
        "The shared Godot AI backend changed or failed twice during this request.",
        "The request is safe to retry; restarting the MCP client is not required.",
        retryable=True,
    )


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
        token = _OPERATION_TRACE.set(OperationTrace())
        try:
            for attempt in range(2):
                try:
                    status = await self._ensure_ready()
                except AttachStartupError as exc:
                    raise _startup_mcp_error(exc) from None
                try:
                    return await self._run_with_instance_monitor(context, call_next, status)
                except AttachStartupError as exc:
                    raise _startup_mcp_error(exc) from None
                except _BackendChanged:
                    if attempt == 0:
                        continue
                    raise _backend_unstable_mcp_error() from None
                except BaseException as exc:
                    if not _is_transport_failure(exc):
                        raise
                    if attempt == 0:
                        continue
                    raise _backend_unstable_mcp_error() from None
            raise AssertionError("safe request recovery loop exhausted")  # pragma: no cover
        finally:
            _OPERATION_TRACE.reset(token)

    async def on_call_tool(
        self,
        context: MiddlewareContext[CallToolRequestParams],
        call_next: CallNext[CallToolRequestParams, ToolResult],
    ) -> ToolResult:
        token = _OPERATION_TRACE.set(OperationTrace())
        try:
            try:
                initial_status = await self._ensure_ready()
            except AttachStartupError as ensure_exc:
                return _startup_error_result(ensure_exc)
            try:
                return await self._run_with_instance_monitor(context, call_next, initial_status)
            except _BackendChanged:
                return _outcome_unknown_result(context.message.name)
            except BaseException as exc:
                if not _is_proven_pre_dispatch_failure(exc):
                    if _is_transport_failure(exc):
                        return _outcome_unknown_result(context.message.name)
                    raise

            # This is the sole tools/call replay path: initialization failed
            # before the operation existed, or the operation's HTTP connect
            # failed before any request bytes could be sent.
            try:
                retry_status = await self._ensure_ready()
            except AttachStartupError as ensure_exc:
                return _startup_error_result(ensure_exc)
            try:
                return await self._run_with_instance_monitor(context, call_next, retry_status)
            except AttachStartupError as ensure_exc:
                return _startup_error_result(ensure_exc)
            except _BackendChanged:
                return _outcome_unknown_result(context.message.name)
            except BaseException as retry_exc:
                if _is_proven_pre_dispatch_failure(retry_exc):
                    # The single safe replay also failed before dispatch. Do
                    # not mislabel it as an ambiguous mutation, and do not loop.
                    return _backend_unavailable_result()
                if _is_transport_failure(retry_exc):
                    return _outcome_unknown_result(context.message.name)
                raise
        finally:
            _OPERATION_TRACE.reset(token)

    async def _run_with_instance_monitor(
        self,
        context: MiddlewareContext[Any],
        call_next: CallNext[Any, Any],
        initial_status: BackendStatus,
    ) -> Any:
        """Run one operation while watching backend identity, without a time limit."""

        if self._observe_backend is None:
            trace = _OPERATION_TRACE.get()
            if trace is not None:
                trace.begin_attempt()
            return await call_next(context)

        trace = _OPERATION_TRACE.get()
        if trace is not None:
            trace.begin_attempt()
        call_task = asyncio.create_task(call_next(context))
        monitor_task = asyncio.create_task(
            self._wait_for_backend_change(initial_status.instance_id)
        )
        tasks = (call_task, monitor_task)
        try:
            done, _pending = await asyncio.wait(
                tasks,
                return_when=asyncio.FIRST_COMPLETED,
            )
            if call_task in done:
                return call_task.result()

            # The backend disappeared, changed identity, or became incompatible
            # after dispatch. Cancel only the local downstream wait; never replay
            # the operation, whose effects may already have committed.
            raise _BackendChanged(initial_status.instance_id)
        finally:
            for task in tasks:
                if not task.done():
                    task.cancel()
            await asyncio.gather(*tasks, return_exceptions=True)

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
        # FastMCP 3.0 exposes an event_store option, but end-to-end resumption
        # after a severed response stream hangs at the supported floor. Do not
        # enable it until that compatibility gap is fixed. A same-instance
        # network stream loss, or a server request task that dies without a
        # response, can therefore wait indefinitely; upstream cancellation is
        # the safe escape hatch and must remain cancellation-clean.
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

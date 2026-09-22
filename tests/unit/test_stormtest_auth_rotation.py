"""The storm harness retries only initialization refused by a rotated capability."""

import ast
import asyncio
import json
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import AsyncMock, Mock

import httpx2
import pytest
from fastmcp import Client
from fastmcp.client.transports import StreamableHttpTransport
from mcp.shared._httpx_utils import create_mcp_http_client
from mcp.shared.exceptions import MCPError
from mcp_types import CONNECTION_CLOSED

from tests.unit.test_stormtest_support import support

ROOT = Path(__file__).resolve().parents[2]
URL = "http://127.0.0.1:18589/mcp"


def load_functions(names, namespace):
    tree = ast.parse((ROOT / "script/stormtest.py").read_text(encoding="utf-8"))
    nodes = [node for node in tree.body
             if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)) and node.name in names]
    exec(compile(ast.Module(body=nodes, type_ignores=[]), "stormtest.py", "exec"), namespace)
    return namespace


def client_namespace(record, handler, *, real_client=False):
    def factory(**kwargs):
        client = create_mcp_http_client(**kwargs)
        client._transport = httpx2.MockTransport(handler)
        client._mounts = {}
        return client

    return load_functions({"_mcp_client", "_err_code"}, {
        "authorization_header": record,
        "json": json,
        "StreamableHttpTransport": StreamableHttpTransport,
        "Client": Client if real_client else lambda transport, **_kwargs: transport,
        "create_mcp_http_client": factory,
        "CALL_TIMEOUT": 2,
        "asyncio": asyncio,
        "transport_exception_code": support.transport_exception_code,
    })


@pytest.mark.parametrize("status,method,target,rotated,signals", [
    (401, "initialize", URL, True, True),
    (401, "server/discover", URL, True, True),
    (401, "initialize", URL, False, False),
    (401, "tools/call", URL, True, False),
    (401, "initialize", "http://127.0.0.1:18590/mcp", True, False),
    (403, "initialize", URL, True, False),
    (500, "initialize", URL, True, False),
])
def test_response_hook_never_retries_a_post_and_only_signals_rotated_initialization(
    status, method, target, rotated, signals,
):
    record = Mock(side_effect=["Bearer old-fixture", "Bearer new-fixture" if rotated
                               else "Bearer old-fixture"])
    sent = []

    def handler(request):
        sent.append(request)
        return httpx2.Response(status, json={"error": "refused"})

    namespace = client_namespace(record, handler)
    transport = namespace["_mcp_client"](URL)

    async def exercise():
        async with transport.httpx_client_factory(
            headers=transport.headers, follow_redirects=True,
        ) as client:
            assert not client.follow_redirects
            if signals:
                with pytest.raises(ConnectionError, match="capability rotated"):
                    await client.post(target, json={"jsonrpc": "2.0", "id": 1, "method": method})
            else:
                response = await client.post(
                    target, json={"jsonrpc": "2.0", "id": 1, "method": method})
                assert response.status_code == status

    asyncio.run(exercise())
    assert len(sent) == 1, "the hook must never replay any request"
    assert record.call_args_list[0].args == (URL,)
    checked = status == 401 and method in {"initialize", "server/discover"} and target == URL
    assert record.call_count == (2 if checked else 1)
    if checked:
        assert record.call_args_list[1].args == (URL,), "only the trusted target record is read"


@pytest.mark.parametrize("rotated", [False, True])
def test_real_sdk_initialization_preserves_unchanged_401_failure(rotated):
    requests = []
    reads = 0

    def record(_url):
        nonlocal reads
        reads += 1
        return "Bearer new-fixture" if rotated and reads > 1 else "Bearer old-fixture"

    def handler(request):
        requests.append(json.loads(request.content)["method"])
        return httpx2.Response(401, json={"error": "refused"})

    namespace = client_namespace(record, handler, real_client=True)

    async def exercise():
        with pytest.raises(Exception) as caught:
            async with namespace["_mcp_client"](URL):
                pytest.fail("unauthorized initialization must not succeed")
        code = namespace["_err_code"](caught.value)
        assert code == ("CONNECTION" if rotated else "MCPError")

    asyncio.run(exercise())
    assert set(requests) <= {"server/discover", "initialize"}
    assert len(requests) == (1 if rotated else 2)


def test_expired_reconnect_deadline_does_not_open_another_client(tmp_path):
    clock = Mock(side_effect=[0, 0.1, 1.1])
    opened = AsyncMock(side_effect=ConnectionError("MCP initialization capability rotated"))
    worker = SimpleNamespace(target={"id": "editor-a", "url": URL}, client=object())
    aborted = Mock()
    recorded = Mock()
    namespace = load_functions({"_repin_locked_target", "_err_code"}, {
        "MCPError": MCPError, "CONNECTION_CLOSED": CONNECTION_CLOSED,
        "Worker": object,
        "time": SimpleNamespace(monotonic=clock),
        "asyncio": SimpleNamespace(timeout=asyncio.timeout, TimeoutError=asyncio.TimeoutError,
                                   sleep=AsyncMock()),
        "RECONNECT_TIMEOUT": 1, "CALL_TIMEOUT": 1, "STOP": [False],
        "TARGET_IDENTITIES": {"editor-a": {"editor_pid": 123, "project_path": str(tmp_path)}},
        "_hard_close": AsyncMock(), "_open_client": opened,
        "StormConfigError": support.StormConfigError,
        "TOLERATED_RELOAD_ERRORS": support.TOLERATED_RELOAD_ERRORS,
        "transport_exception_code": support.transport_exception_code,
        "_abort": aborted, "_record_admin_error": recorded,
    })
    assert not asyncio.run(namespace["_repin_locked_target"](worker, "old-session"))
    assert opened.await_count == 1
    recorded.assert_called_once_with("CONNECTION", "qualification.repin")
    assert "within 1s" in aborted.call_args.args[0]


@pytest.mark.parametrize("code,message,retries", [
    (CONNECTION_CLOSED, "SSE stream ended without a response", True),
    (-32603, "SSE stream ended without a response", False),
    (CONNECTION_CLOSED, "another failure", False),
])
def test_repin_retries_exact_sdk_read_validation_eof_only(tmp_path, code, message, retries):
    error = MCPError(code, message)
    replacement = {"session_id": "project@new", "editor_pid": 123,
                   "project_path": str(tmp_path)}
    failed = SimpleNamespace(call_tool=AsyncMock(side_effect=error))
    good = SimpleNamespace(call_tool=AsyncMock(side_effect=[[replacement], {}]))
    worker = SimpleNamespace(target={"id": "editor-a", "url": URL,
                                    "session_id": "project@old"}, client=object())
    namespace = load_functions({"_repin_locked_target", "_err_code"}, {
        "MCPError": MCPError, "CONNECTION_CLOSED": CONNECTION_CLOSED,
        "Worker": object, "time": __import__("time"),
        "asyncio": SimpleNamespace(timeout=asyncio.timeout, TimeoutError=asyncio.TimeoutError,
                                   sleep=AsyncMock()),
        "RECONNECT_TIMEOUT": 1, "CALL_TIMEOUT": 1, "STOP": [False],
        "TARGET_IDENTITIES": {"editor-a": {"editor_pid": 123, "project_path": str(tmp_path)}},
        "QUALIFICATION_EVIDENCE": {"editor-a": {"repins": []}},
        "_hard_close": AsyncMock(), "_open_client": AsyncMock(side_effect=[failed, good]),
        "_sessions_from_result": lambda result: result,
        "_requires_single_editor_topology": lambda: True,
        "select_replacement_session": support.select_replacement_session,
        "StormConfigError": support.StormConfigError,
        "TOLERATED_RELOAD_ERRORS": support.TOLERATED_RELOAD_ERRORS,
        "transport_exception_code": support.transport_exception_code,
        "_abort": Mock(), "_record_admin_error": Mock(),
    })
    assert asyncio.run(namespace["_repin_locked_target"](worker, "project@old")) is retries
    failed.call_tool.assert_awaited_once_with("session_manage", {"op": "list", "params": {}})
    assert namespace["_open_client"].await_count == (2 if retries else 1)
    assert worker.target["session_id"] == ("project@new" if retries else "project@old")
    assert namespace["_err_code"](error) == "MCPError", "ordinary tool EOF remains a failure"
    assert namespace["_abort"].call_count == (0 if retries else 1)


def test_actual_sdk_result_validation_reports_closed_metadata_stream():
    methods = []

    def handler(request):
        if request.method != "POST":
            return httpx2.Response(405)
        body = json.loads(request.content)
        method = body["method"]
        methods.append(method)
        if method == "server/discover":
            return httpx2.Response(404)
        if method.startswith("notifications/"):
            return httpx2.Response(202)
        if method == "initialize":
            result = {"protocolVersion": "2025-03-26", "capabilities": {"tools": {}},
                      "serverInfo": {"name": "read-validation-fixture", "version": "1"}}
        elif method == "tools/call":
            result = {"content": [{"type": "text", "text": "[]"}]}
        elif method == "tools/list":
            return httpx2.Response(200, headers={"content-type": "text/event-stream"},
                                   content=b"")
        else:
            pytest.fail(f"unexpected request: {method}")
        return httpx2.Response(200, json={"jsonrpc": "2.0", "id": body["id"], "result": result})

    namespace = client_namespace(lambda _url: "Bearer fixture", handler, real_client=True)

    async def exercise():
        async with namespace["_mcp_client"](URL) as client:
            with pytest.raises(MCPError) as caught:
                await client.call_tool("session_manage", {"op": "list", "params": {}})
            assert caught.value.error.code == CONNECTION_CLOSED
            assert caught.value.error.message == "SSE stream ended without a response"
            assert namespace["_err_code"](caught.value) == "MCPError"

    asyncio.run(exercise())
    assert methods.count("tools/call") == 1
    assert methods.count("tools/list") == 1
    assert methods.index("tools/call") < methods.index("tools/list")

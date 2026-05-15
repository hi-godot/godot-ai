"""Tests for the ``telemetry_tool`` / ``telemetry_resource`` decorators and
the ``install_fastmcp_wraps`` server-level wrap.

The decorator wraps both sync and async functions, captures duration +
success/error, extracts ``op``/``action``/``sub_action`` and ``session_id``
from bound args, and never raises out of a tool path.
"""

from __future__ import annotations

import asyncio

import pytest

from godot_ai import telemetry as tel
from godot_ai.godot_client.client import GodotCommandError


@pytest.fixture
def isolated_collector(isolated_data_dir):
    """A fresh telemetry collector with ``_send`` redirected into a list
    so tests can assert on captured records. Builds on the shared
    ``isolated_data_dir`` fixture (``tests/unit/conftest.py``) for the
    env-clean + tmp-dir + reset_telemetry dance."""
    collector = tel.get_telemetry()
    sent: list[tel.TelemetryRecord] = []
    collector._send = sent.append  # type: ignore[method-assign]
    return collector, sent


def _wait_for(records: list, count: int, timeout: float = 2.0) -> None:
    import time

    deadline = time.monotonic() + timeout
    while len(records) < count and time.monotonic() < deadline:
        time.sleep(0.02)


class TestTelemetryToolSync:
    def test_records_success(self, isolated_collector) -> None:
        _, sent = isolated_collector

        @tel.telemetry_tool("my_tool")
        def my_tool(x: int) -> int:
            return x * 2

        assert my_tool(21) == 42
        _wait_for(sent, 1)

        assert len(sent) == 1
        rec = sent[0]
        assert rec.record_type is tel.RecordType.TOOL_EXECUTION
        assert rec.data["tool_name"] == "my_tool"
        assert rec.data["success"] is True
        assert "duration_ms" in rec.data
        assert "error" not in rec.data

    def test_records_failure(self, isolated_collector) -> None:
        _, sent = isolated_collector

        @tel.telemetry_tool("my_tool")
        def my_tool() -> None:
            raise ValueError("boom")

        with pytest.raises(ValueError, match="boom"):
            my_tool()
        _wait_for(sent, 1)

        rec = sent[0]
        assert rec.data["success"] is False
        assert rec.data["error"] == "ValueError"
        assert "boom" not in rec.data["error"]

    def test_records_godot_command_error_code_without_data(self, isolated_collector) -> None:
        _, sent = isolated_collector

        @tel.telemetry_tool("my_tool")
        def my_tool() -> None:
            raise GodotCommandError(
                code="RESOURCE_NOT_FOUND",
                message="Missing res://secret-project/player.gd",
                data={"candidate": "res://secret-project/player_backup.gd"},
            )

        with pytest.raises(GodotCommandError):
            my_tool()
        _wait_for(sent, 1)

        rec = sent[0]
        assert rec.data["success"] is False
        assert rec.data["error"] == "RESOURCE_NOT_FOUND"
        assert "secret-project" not in rec.data["error"]
        assert "candidate" not in rec.data["error"]

    def test_replaces_unknown_godot_command_error_code(self, isolated_collector) -> None:
        _, sent = isolated_collector

        @tel.telemetry_tool("my_tool")
        def my_tool() -> None:
            raise GodotCommandError(
                code="res://secret-project/error-code",
                message="Missing res://secret-project/player.gd",
            )

        with pytest.raises(GodotCommandError):
            my_tool()
        _wait_for(sent, 1)

        rec = sent[0]
        assert rec.data["success"] is False
        assert rec.data["error"] == "GodotCommandError"
        assert "secret-project" not in rec.data["error"]

    def test_extracts_op_as_sub_action(self, isolated_collector) -> None:
        _, sent = isolated_collector

        @tel.telemetry_tool("scene_manage")
        def manage(op: str, params: dict | None = None) -> dict:
            return {"ok": True}

        manage(op="save_as", params={"path": "res://x.tscn"})
        _wait_for(sent, 1)

        assert sent[0].data["sub_action"] == "save_as"

    def test_extracts_session_id(self, isolated_collector) -> None:
        _, sent = isolated_collector

        @tel.telemetry_tool("x")
        def x(session_id: str = "") -> None:
            return None

        x(session_id="my-game@a3f2")
        _wait_for(sent, 1)

        ## session_id is hashed before serialization.
        assert sent[0].session_id.endswith("@a3f2")
        assert "my-game" not in sent[0].session_id

    def test_records_class_name_for_long_error_message(self, isolated_collector) -> None:
        _, sent = isolated_collector
        long_msg = "x" * 500

        @tel.telemetry_tool("x")
        def x() -> None:
            raise RuntimeError(long_msg)

        with pytest.raises(RuntimeError):
            x()
        _wait_for(sent, 1)

        assert sent[0].data["error"] == "RuntimeError"


class TestTelemetryToolAsync:
    def test_async_records_success(self, isolated_collector) -> None:
        _, sent = isolated_collector

        @tel.telemetry_tool("async_tool")
        async def my_async() -> int:
            return 7

        result = asyncio.run(my_async())
        _wait_for(sent, 1)

        assert result == 7
        assert sent[0].data["success"] is True
        assert sent[0].data["tool_name"] == "async_tool"

    def test_async_records_failure(self, isolated_collector) -> None:
        _, sent = isolated_collector

        @tel.telemetry_tool("async_tool")
        async def my_async() -> None:
            raise RuntimeError("async boom")

        with pytest.raises(RuntimeError, match="async boom"):
            asyncio.run(my_async())
        _wait_for(sent, 1)

        assert sent[0].data["success"] is False
        assert sent[0].data["error"] == "RuntimeError"
        assert "async boom" not in sent[0].data["error"]


class TestTelemetryResource:
    def test_records_resource_retrieval(self, isolated_collector) -> None:
        _, sent = isolated_collector

        @tel.telemetry_resource("my_resource")
        def reader() -> dict:
            return {"ok": True}

        reader()
        _wait_for(sent, 1)

        rec = sent[0]
        assert rec.record_type is tel.RecordType.RESOURCE_RETRIEVAL
        assert rec.data["resource_name"] == "my_resource"
        assert rec.data["success"] is True

    def test_resource_failure_records_class_name_not_message(self, isolated_collector) -> None:
        _, sent = isolated_collector

        @tel.telemetry_resource("my_resource")
        def reader() -> dict:
            raise ConnectionError("project path /Users/alice/private-game disappeared")

        with pytest.raises(ConnectionError):
            reader()
        _wait_for(sent, 1)

        rec = sent[0]
        assert rec.record_type is tel.RecordType.RESOURCE_RETRIEVAL
        assert rec.data["success"] is False
        assert rec.data["error"] == "ConnectionError"
        assert "private-game" not in rec.data["error"]


class TestDecoratorNeverRaises:
    """If the telemetry pipeline itself blows up, the wrapped function
    must still return its result and propagate its own exceptions."""

    def test_emit_failure_does_not_break_caller(self, isolated_collector, monkeypatch) -> None:
        _, _ = isolated_collector

        def crash(*_a, **_kw) -> None:
            raise RuntimeError("emit boom")

        monkeypatch.setattr(tel, "record_tool_usage", crash)

        @tel.telemetry_tool("x")
        def x() -> int:
            return 1

        assert x() == 1


class TestInstallFastmcpWraps:
    """Verify that wrapping ``mcp.tool`` and ``mcp.resource`` on a real
    FastMCP instance instruments tools registered after the wrap."""

    def test_tools_registered_after_wrap_are_instrumented(self, isolated_collector) -> None:
        _, sent = isolated_collector
        from fastmcp import FastMCP

        mcp = FastMCP("test")
        tel.install_fastmcp_wraps(mcp)

        @mcp.tool()
        async def wrapped_tool(x: int) -> int:
            return x + 1

        asyncio.run(wrapped_tool(41))
        _wait_for(sent, 1)

        assert len(sent) == 1
        assert sent[0].data["tool_name"] == "wrapped_tool"
        assert sent[0].data["success"] is True

    def test_bare_decorator_form_works(self, isolated_collector) -> None:
        _, sent = isolated_collector
        from fastmcp import FastMCP

        mcp = FastMCP("test")
        tel.install_fastmcp_wraps(mcp)

        @mcp.tool
        async def bare(x: int) -> int:
            return x + 1

        asyncio.run(bare(0))
        _wait_for(sent, 1)
        assert sent[0].data["tool_name"] == "bare"

    def test_disabled_collector_skips_records_from_wrap(
        self, isolated_collector, monkeypatch
    ) -> None:
        collector, sent = isolated_collector
        collector.config.enabled = False

        from fastmcp import FastMCP

        mcp = FastMCP("test")
        tel.install_fastmcp_wraps(mcp)

        @mcp.tool()
        async def wrapped(x: int) -> int:
            return x

        asyncio.run(wrapped(1))
        _wait_for(sent, 0, timeout=0.3)

        assert sent == []

    def test_manage_tool_schema_builds_through_wrap(self, isolated_collector) -> None:
        """Issue #435 regression: ``<domain>_manage`` rollups have their
        ``op`` annotation set post-hoc to a dynamically-built ``Literal[...]``
        (see ``_meta_tool.py`` rationale). When the telemetry wrap put a
        ``functools.wraps``-decorated wrapper between FastMCP and the closure,
        FastMCP's ``without_injected_parameters`` → Pydantic schema build
        crashed with ``KeyError: 'op'`` on some Python / Pydantic combos
        because the wrapper's own ``__annotations__`` / ``__globals__`` lost
        the dynamic ``Literal``. The fix pins ``__signature__`` and a fresh
        ``__annotations__`` copy on the instrumented wrapper so FastMCP can
        introspect it directly.

        This test reproduces the failing path: register a manage tool through
        an ``install_fastmcp_wraps``-wrapped FastMCP and force schema
        generation by listing tools. Pre-fix this raised ``KeyError: 'op'``.
        """
        from fastmcp import FastMCP

        from godot_ai.tools._meta_tool import register_manage_tool

        mcp = FastMCP("test")
        tel.install_fastmcp_wraps(mcp)

        async def op_a(runtime, **_kwargs):  # type: ignore[no-untyped-def]
            return {"ok": True}

        async def op_b(runtime, **_kwargs):  # type: ignore[no-untyped-def]
            return {"ok": True}

        register_manage_tool(
            mcp,
            tool_name="test_manage",
            description="test manage rollup",
            ops={"alpha": op_a, "beta": op_b},
        )

        ## Forcing tool list materializes the Pydantic schema for every
        ## registered tool — that's the call that exploded in #435.
        tools = asyncio.run(mcp.list_tools())
        names = {t.name for t in tools}
        assert "test_manage" in names

        test_manage = next(t for t in tools if t.name == "test_manage")
        schema = test_manage.parameters or {}
        ## Schema must enumerate the op literal — proves Pydantic saw the
        ## ``op`` annotation rather than skipping or defaulting it.
        op_schema = schema.get("properties", {}).get("op", {})
        assert op_schema.get("enum") == ["alpha", "beta"], (
            f"op enum missing or wrong; got schema={op_schema!r}"
        )

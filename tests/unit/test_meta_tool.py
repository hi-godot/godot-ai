"""Unit tests for the ``register_manage_tool`` helper and ``dispatch_manage_op``."""

from __future__ import annotations

from typing import Any
from unittest.mock import AsyncMock

import pytest
from fastmcp import FastMCP

from godot_ai.godot_client.client import GodotCommandError
from godot_ai.protocol.errors import ErrorCode
from godot_ai.tools._meta_tool import (
    _coerce_stringified_json_values,
    dispatch_manage_op,
    register_manage_tool,
)

# ---------------------------------------------------------------------------
# Schema construction
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_register_exposes_op_literal_in_schema():
    mcp = FastMCP("test")
    register_manage_tool(
        mcp,
        tool_name="domain_manage",
        description="Domain rollup.",
        ops={
            "alpha": AsyncMock(return_value={"ok": True}),
            "beta": AsyncMock(return_value={"ok": True}),
        },
    )
    tools = await mcp._list_tools()
    assert len(tools) == 1
    tool = tools[0]
    assert tool.name == "domain_manage"
    schema = tool.parameters
    op_schema = schema["properties"]["op"]
    assert sorted(op_schema["enum"]) == ["alpha", "beta"]
    assert schema["properties"]["params"]["default"] is None
    assert schema["properties"]["session_id"]["default"] == ""
    assert schema["required"] == ["op"]


@pytest.mark.asyncio
async def test_register_marks_tool_deferred():
    mcp = FastMCP("test")
    register_manage_tool(
        mcp,
        tool_name="x_manage",
        description="x",
        ops={"a": AsyncMock(return_value={})},
    )
    tools = await mcp._list_tools()
    meta = getattr(tools[0], "meta", {}) or {}
    assert meta.get("defer_loading") is True


def test_register_rejects_empty_ops():
    mcp = FastMCP("test")
    with pytest.raises(ValueError, match="ops cannot be empty"):
        register_manage_tool(mcp, tool_name="x_manage", description="x", ops={})


# ---------------------------------------------------------------------------
# Dispatch — happy path. Handlers are invoked as ``handler(runtime, **params)``,
# so test handlers accept the same keyword args the dispatcher unpacks.
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_dispatch_routes_to_correct_handler():
    alpha = AsyncMock(return_value={"v": "alpha"})
    beta = AsyncMock(return_value={"v": "beta"})
    runtime = object()  # opaque

    result = await dispatch_manage_op(
        ops={"alpha": alpha, "beta": beta},
        tool_name="x_manage",
        runtime=runtime,
        op="beta",
        params={"k": 1},
    )
    assert result == {"v": "beta"}
    alpha.assert_not_called()
    beta.assert_awaited_once_with(runtime, k=1)


@pytest.mark.asyncio
async def test_dispatch_handles_sync_handlers():
    def sync_handler(rt, a):
        return {"sync": True, "a": a}

    result = await dispatch_manage_op(
        ops={"go": sync_handler},
        tool_name="x_manage",
        runtime=None,
        op="go",
        params={"a": 1},
    )
    assert result == {"sync": True, "a": 1}


@pytest.mark.asyncio
async def test_dispatch_defaults_params_to_empty_dict():
    captured: dict[str, Any] = {}

    async def handler(rt):
        captured["called"] = True
        return {}

    await dispatch_manage_op(
        ops={"go": handler},
        tool_name="x_manage",
        runtime=None,
        op="go",
        params=None,
    )
    assert captured["called"] is True


# ---------------------------------------------------------------------------
# Dispatch — error paths
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_dispatch_unknown_op_returns_suggestions():
    ops = {
        "set_color": AsyncMock(),
        "set_constant": AsyncMock(),
        "apply": AsyncMock(),
    }
    with pytest.raises(GodotCommandError) as exc:
        await dispatch_manage_op(
            ops=ops,
            tool_name="theme_manage",
            runtime=None,
            op="set_colour",  # British spelling typo
            params={},
        )
    err = exc.value
    assert err.code == ErrorCode.INVALID_PARAMS
    assert "set_color" in err.data["suggestions"]
    assert err.data["op"] == "set_colour"
    assert err.data["tool"] == "theme_manage"


@pytest.mark.asyncio
async def test_dispatch_unknown_op_with_no_close_match():
    ops = {"alpha": AsyncMock()}
    with pytest.raises(GodotCommandError) as exc:
        await dispatch_manage_op(
            ops=ops,
            tool_name="x_manage",
            runtime=None,
            op="zzzzz",
            params={},
        )
    assert exc.value.data["suggestions"] == []


@pytest.mark.asyncio
async def test_dispatch_rejects_non_dict_params():
    with pytest.raises(GodotCommandError) as exc:
        await dispatch_manage_op(
            ops={"a": AsyncMock()},
            tool_name="x_manage",
            runtime=None,
            op="a",
            params=["not", "a", "dict"],  # type: ignore[arg-type]
        )
    assert exc.value.code == ErrorCode.INVALID_PARAMS
    assert "must be an object/dict" in exc.value.message


@pytest.mark.asyncio
async def test_dispatch_unwraps_typeerror_from_handler():
    async def picky(rt, path):
        del rt, path  ## absorb unused args; the test only cares about the raise below
        raise TypeError("missing 1 required positional argument: 'value'")

    with pytest.raises(GodotCommandError) as exc:
        await dispatch_manage_op(
            ops={"go": picky},
            tool_name="x_manage",
            runtime=None,
            op="go",
            params={"path": "/foo"},
        )
    assert exc.value.code == ErrorCode.INVALID_PARAMS
    assert "x_manage.go" in exc.value.message
    assert exc.value.data["received"] == ["path"]


# ---------------------------------------------------------------------------
# JSON-string coercion
# ---------------------------------------------------------------------------


def test_coerce_array_string_to_list():
    out = _coerce_stringified_json_values({"paths": '["a", "b"]'})
    assert out["paths"] == ["a", "b"]


def test_coerce_object_string_to_dict():
    out = _coerce_stringified_json_values({"props": '{"x": 1, "y": 2}'})
    assert out["props"] == {"x": 1, "y": 2}


def test_coerce_leaves_plain_strings_untouched():
    ## Neither value is JSON list/dict-shaped — both must pass through untouched.
    out = _coerce_stringified_json_values({"name": "Alice", "label": "draft"})
    assert out["name"] == "Alice"
    assert out["label"] == "draft"


def test_coerce_leaves_non_json_prefixed_strings_untouched():
    out = _coerce_stringified_json_values({"q": "not-json", "n": "42"})
    assert out["q"] == "not-json"
    assert out["n"] == "42"  # numeric string isn't a list/dict prefix


def test_coerce_preserves_native_types():
    out = _coerce_stringified_json_values({"n": 1, "b": True, "lst": ["already"]})
    assert out["n"] == 1
    assert out["b"] is True
    assert out["lst"] == ["already"]


def test_coerce_only_attempts_array_or_object_prefixes():
    ## "true" is valid JSON but not list/dict-shaped — leave alone.
    out = _coerce_stringified_json_values({"flag": "true"})
    assert out["flag"] == "true"


def test_coerce_returns_input_unchanged_when_no_coercion_needed():
    ## Fast path: no string values, no prefix matches → return same dict (not a copy).
    params = {"n": 1, "b": True, "s": "plain", "lst": [1, 2]}
    out = _coerce_stringified_json_values(params)
    assert out is params


@pytest.mark.asyncio
async def test_dispatch_applies_coercion_before_handler():
    captured: dict[str, Any] = {}

    async def handler(rt, paths):
        del rt
        captured["paths"] = paths
        return {}

    await dispatch_manage_op(
        ops={"go": handler},
        tool_name="x_manage",
        runtime=None,
        op="go",
        params={"paths": '["one", "two"]'},
    )
    assert captured["paths"] == ["one", "two"]

"""Unit tests for the ``register_manage_tool`` helper and ``dispatch_manage_op``."""

from __future__ import annotations

from typing import Any, get_args
from unittest.mock import AsyncMock

import pytest
from fastmcp import FastMCP

from godot_ai.godot_client.client import GodotCommandError
from godot_ai.protocol.errors import ErrorCode
from godot_ai.tools._meta_tool import (
    _op_literal_for,
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
# Op-literal memoization (Audit v2 #18 / #362)
# ---------------------------------------------------------------------------


def test_op_literal_for_returns_same_object_for_equal_op_sets():
    ## Two registrations with the same op names — even in different insertion
    ## orders — must share one Literal so Pydantic doesn't rebuild equivalent
    ## schema fragments per domain.
    a = _op_literal_for(frozenset({"create", "delete", "rename"}))
    b = _op_literal_for(frozenset({"rename", "create", "delete"}))
    assert a is b


def test_op_literal_for_returns_distinct_object_for_different_op_sets():
    a = _op_literal_for(frozenset({"create", "delete"}))
    b = _op_literal_for(frozenset({"create", "delete", "rename"}))
    assert a is not b


def test_op_literal_for_args_are_sorted_for_determinism():
    literal = _op_literal_for(frozenset({"zeta", "alpha", "mu"}))
    assert get_args(literal) == ("alpha", "mu", "zeta")


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


@pytest.mark.asyncio
async def test_dispatch_wraps_missing_param_typeerror():
    async def needs_path(rt, path):
        del rt, path
        return {}

    with pytest.raises(GodotCommandError) as exc:
        await dispatch_manage_op(
            ops={"go": needs_path},
            tool_name="x_manage",
            runtime=None,
            op="go",
            params={},
        )

    assert exc.value.code == ErrorCode.INVALID_PARAMS
    assert "x_manage.go" in exc.value.message
    assert "path" in exc.value.message
    assert exc.value.data["received"] == []


@pytest.mark.asyncio
async def test_dispatch_wraps_extra_param_typeerror():
    async def no_params(rt):
        del rt
        return {}

    with pytest.raises(GodotCommandError) as exc:
        await dispatch_manage_op(
            ops={"go": no_params},
            tool_name="x_manage",
            runtime=None,
            op="go",
            params={"extra": "{not-json"},
        )

    assert exc.value.code == ErrorCode.INVALID_PARAMS
    assert "x_manage.go" in exc.value.message
    assert "extra" in exc.value.message
    assert exc.value.data["received"] == ["extra"]


# ---------------------------------------------------------------------------
# JSON-string coercion
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_dispatch_coerces_stringified_list_for_list_annotated_param():
    captured: dict[str, Any] = {}

    async def handler(rt, paths: list[str]):
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


@pytest.mark.asyncio
async def test_dispatch_coerces_stringified_dict_for_dict_annotated_param():
    captured: dict[str, Any] = {}

    async def handler(rt, props: dict[str, Any]):
        del rt
        captured["props"] = props
        return {}

    await dispatch_manage_op(
        ops={"go": handler},
        tool_name="x_manage",
        runtime=None,
        op="go",
        params={"props": '{"x": 1, "y": 2}'},
    )
    assert captured["props"] == {"x": 1, "y": 2}


@pytest.mark.asyncio
async def test_dispatch_coerces_stringified_list_for_optional_list_annotated_param():
    ## Optional[list[str]] is the most common shape for "may be omitted" list
    ## params. The Union/UnionType branch in `_json_container_kinds` must strip
    ## NoneType and still surface "list" so the JSON-string gets decoded.
    captured: dict[str, Any] = {}

    async def handler(rt, paths: list[str] | None = None):
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


@pytest.mark.asyncio
async def test_dispatch_leaves_json_shaped_string_for_str_annotated_param():
    captured: dict[str, Any] = {}

    async def handler(rt, label: str):
        del rt
        captured["label"] = label
        return {}

    await dispatch_manage_op(
        ops={"go": handler},
        tool_name="x_manage",
        runtime=None,
        op="go",
        params={"label": '{"not": "decoded"}'},
    )
    assert captured["label"] == '{"not": "decoded"}'


@pytest.mark.asyncio
async def test_dispatch_rejects_malformed_json_for_list_annotated_param():
    async def handler(rt, paths: list[str]):
        del rt, paths
        return {}

    with pytest.raises(GodotCommandError) as exc:
        await dispatch_manage_op(
            ops={"go": handler},
            tool_name="x_manage",
            runtime=None,
            op="go",
            params={"paths": '["unterminated"'},
        )

    err = exc.value
    assert err.code == ErrorCode.INVALID_PARAMS
    assert "malformed JSON" in err.message
    assert err.data["tool"] == "x_manage"
    assert err.data["op"] == "go"
    assert err.data["param"] == "paths"
    assert err.data["expected"] == "JSON array"


@pytest.mark.asyncio
async def test_dispatch_rejects_malformed_json_for_dict_annotated_param():
    async def handler(rt, props: dict[str, Any]):
        del rt, props
        return {}

    with pytest.raises(GodotCommandError) as exc:
        await dispatch_manage_op(
            ops={"go": handler},
            tool_name="x_manage",
            runtime=None,
            op="go",
            params={"props": '{"unterminated"'},
        )

    err = exc.value
    assert err.code == ErrorCode.INVALID_PARAMS
    assert "malformed JSON" in err.message
    assert err.data["tool"] == "x_manage"
    assert err.data["op"] == "go"
    assert err.data["param"] == "props"
    assert err.data["expected"] == "JSON object"


@pytest.mark.asyncio
async def test_dispatch_rejects_wrong_json_container_for_dict_annotated_param():
    async def handler(rt, props: dict[str, Any]):
        del rt, props
        return {}

    with pytest.raises(GodotCommandError) as exc:
        await dispatch_manage_op(
            ops={"go": handler},
            tool_name="x_manage",
            runtime=None,
            op="go",
            params={"props": '["not", "an", "object"]'},
        )

    err = exc.value
    assert err.code == ErrorCode.INVALID_PARAMS
    assert err.data["tool"] == "x_manage"
    assert err.data["op"] == "go"
    assert err.data["param"] == "props"
    assert err.data["expected"] == "JSON object"
    assert err.data["actual"] == "list"


@pytest.mark.asyncio
async def test_dispatch_preserves_native_list_and_dict_params():
    paths = ["one", "two"]
    props = {"x": 1}
    captured: dict[str, Any] = {}

    async def handler(rt, paths: list[str], props: dict[str, Any]):
        del rt
        captured["paths"] = paths
        captured["props"] = props
        return {}

    await dispatch_manage_op(
        ops={"go": handler},
        tool_name="x_manage",
        runtime=None,
        op="go",
        params={"paths": paths, "props": props},
    )
    assert captured["paths"] is paths
    assert captured["props"] is props

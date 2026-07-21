"""Unit tests for the ``register_manage_tool`` helper and ``dispatch_manage_op``."""

from __future__ import annotations

from typing import Annotated, Any
from unittest.mock import AsyncMock

import pytest
from fastmcp import FastMCP

from godot_ai.godot_client.client import GodotCommandError
from godot_ai.protocol.errors import ErrorCode
from godot_ai.tools._meta_tool import (
    MANAGE_TOOL_HANDLERS,
    MANAGE_TOOL_OPS,
    MANAGE_TOOL_RESOURCE_FORMS,
    _op_schema_type_for,
    dispatch_manage_op,
    register_manage_tool,
)


@pytest.fixture(autouse=True)
def _restore_registries():
    """Snapshot/restore the manage-tool registries.

    Several tests below register synthetic tools (``x_manage``, ``domain_manage``,
    etc.) directly via ``register_manage_tool`` rather than through
    ``create_server``. Without restoration those entries leak into the
    process-global registries and then trip ``test_resource_form_lint``,
    which sees handlers from ``unittest.mock`` and demands declarations.
    """
    saved_ops = dict(MANAGE_TOOL_OPS)
    saved_handlers = {k: dict(v) for k, v in MANAGE_TOOL_HANDLERS.items()}
    saved_forms = {k: dict(v) for k, v in MANAGE_TOOL_RESOURCE_FORMS.items()}
    try:
        yield
    finally:
        MANAGE_TOOL_OPS.clear()
        MANAGE_TOOL_OPS.update(saved_ops)
        MANAGE_TOOL_HANDLERS.clear()
        MANAGE_TOOL_HANDLERS.update(saved_handlers)
        MANAGE_TOOL_RESOURCE_FORMS.clear()
        MANAGE_TOOL_RESOURCE_FORMS.update(saved_forms)


# ---------------------------------------------------------------------------
# Schema construction
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_register_exposes_op_enum_in_schema():
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


def test_register_rejects_resource_form_for_unknown_op():
    mcp = FastMCP("test")
    with pytest.raises(ValueError, match="not in ops"):
        register_manage_tool(
            mcp,
            tool_name="x_manage",
            description="x",
            ops={"a": AsyncMock()},
            read_resource_forms={"b": "godot://x"},  # 'b' not in ops
        )


def test_register_rejects_non_godot_uri_in_resource_form():
    mcp = FastMCP("test")
    with pytest.raises(ValueError, match="must start with 'godot://'"):
        register_manage_tool(
            mcp,
            tool_name="x_manage",
            description="x",
            ops={"a": AsyncMock()},
            read_resource_forms={"a": "https://example.com"},
        )


def test_register_rejects_non_string_non_none_value_in_resource_form():
    mcp = FastMCP("test")
    with pytest.raises(ValueError, match="must be a 'godot://' URI string or None"):
        register_manage_tool(
            mcp,
            tool_name="x_manage",
            description="x",
            ops={"a": AsyncMock()},
            read_resource_forms={"a": 42},  # type: ignore[dict-item]
        )


def test_register_accepts_resource_form_with_uri_and_waiver():
    mcp = FastMCP("test")
    handler_a = AsyncMock(return_value={})
    handler_b = AsyncMock(return_value={})
    register_manage_tool(
        mcp,
        tool_name="acceptance_manage",
        description="x",
        ops={"a": handler_a, "b": handler_b},
        read_resource_forms={"a": "godot://thing", "b": None},
    )
    assert MANAGE_TOOL_RESOURCE_FORMS["acceptance_manage"] == {"a": "godot://thing", "b": None}
    assert MANAGE_TOOL_HANDLERS["acceptance_manage"]["a"] is handler_a


# ---------------------------------------------------------------------------
# Op-literal memoization (Audit v2 #18 / #362)
# ---------------------------------------------------------------------------


def test_op_schema_type_for_returns_same_object_for_equal_op_sets():
    ## Two registrations with the same op names — even in different insertion
    ## orders — must share one schema type so Pydantic doesn't rebuild equivalent
    ## schema fragments per domain.
    a = _op_schema_type_for(frozenset({"create", "delete", "rename"}))
    b = _op_schema_type_for(frozenset({"rename", "create", "delete"}))
    assert a is b


def test_op_schema_type_for_returns_distinct_object_for_different_op_sets():
    a = _op_schema_type_for(frozenset({"create", "delete"}))
    b = _op_schema_type_for(frozenset({"create", "delete", "rename"}))
    assert a is not b


def test_op_schema_type_for_enum_is_sorted_for_determinism():
    from pydantic import TypeAdapter

    schema_type = _op_schema_type_for(frozenset({"zeta", "alpha", "mu"}))
    assert TypeAdapter(schema_type).json_schema()["enum"] == ["alpha", "mu", "zeta"]


def test_op_schema_type_for_rejects_unknown_ops_at_runtime():
    from pydantic import TypeAdapter, ValidationError

    schema_type = _op_schema_type_for(frozenset({"create", "delete"}))
    adapter = TypeAdapter(schema_type)
    assert adapter.validate_python("create") == "create"
    with pytest.raises(ValidationError):
        adapter.validate_python("rename")


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
async def test_dispatch_propagates_async_body_typeerror_as_internal():
    """#714: the TypeError catch exists for BINDING errors (bad kwargs).

    A genuine TypeError raised inside an *async handler body* is an internal
    bug and must propagate as-is — the pre-fix behavior awaited inside the
    try and misreported it as INVALID_PARAMS blaming the caller's params.
    (This replaces the defect-locking test that pinned the old behavior,
    updated as one unit with the narrowed try per the audit item.)
    """

    async def buggy(rt, path):
        del rt, path
        raise TypeError("'NoneType' object is not subscriptable")

    with pytest.raises(TypeError, match="not subscriptable"):
        await dispatch_manage_op(
            ops={"go": buggy},
            tool_name="x_manage",
            runtime=None,
            op="go",
            params={"path": "/foo"},
        )


@pytest.mark.asyncio
async def test_dispatch_scalar_pin_rejects_type_confusion():
    """#714: annotated scalar params are validated Python-side before
    dispatch — a bool where an int belongs is the classic confusion that
    used to surface as an opaque plugin-side crash."""

    async def sized(rt, count: int):
        del rt
        return {"count": count}

    with pytest.raises(GodotCommandError) as exc:
        await dispatch_manage_op(
            ops={"go": sized},
            tool_name="x_manage",
            runtime=None,
            op="go",
            params={"count": True},
        )
    assert exc.value.code == ErrorCode.INVALID_PARAMS
    assert "'count'" in exc.value.message
    assert "int" in exc.value.message
    assert exc.value.data["param"] == "count"
    assert exc.value.data["received_type"] == "bool"


@pytest.mark.asyncio
async def test_dispatch_scalar_pin_accepts_valid_scalars():
    async def mixed(rt, name: str, count: int, ratio: float, flag: bool, maybe: str | None = None):
        del rt
        return {"name": name, "count": count, "ratio": ratio, "flag": flag, "maybe": maybe}

    result = await dispatch_manage_op(
        ops={"go": mixed},
        tool_name="x_manage",
        runtime=None,
        op="go",
        ## ratio as int is legitimate — JSON has one number type.
        params={"name": "a", "count": 3, "ratio": 2, "flag": True, "maybe": None},
    )
    assert result == {"name": "a", "count": 3, "ratio": 2, "flag": True, "maybe": None}


@pytest.mark.asyncio
async def test_dispatch_scalar_pin_unwraps_annotated_params():
    """Annotated[int, ...] params get the same pin as bare int.

    Annotated must be importable at module scope: with stringified
    annotations (PEP 563), get_type_hints resolves names against module
    globals, and an unresolvable annotation silently disables the pin.
    """

    async def sized(rt, count: Annotated[int, "node count"]):
        del rt
        return {"count": count}

    with pytest.raises(GodotCommandError) as exc:
        await dispatch_manage_op(
            ops={"go": sized},
            tool_name="x_manage",
            runtime=None,
            op="go",
            params={"count": "3"},
        )
    assert exc.value.code == ErrorCode.INVALID_PARAMS
    assert exc.value.data["param"] == "count"

    result = await dispatch_manage_op(
        ops={"go": sized},
        tool_name="x_manage",
        runtime=None,
        op="go",
        params={"count": 3},
    )
    assert result == {"count": 3}


@pytest.mark.asyncio
async def test_dispatch_scalar_pin_survives_get_type_hints_failure():
    """One unresolvable forward ref makes get_type_hints fail for the WHOLE
    handler ({} hints), which used to silently disable every pin on it. The
    dispatch loop now falls back to the raw signature annotation (mirroring
    _coerce_stringified_json_values), so a param annotated with a real type
    object keeps its pin even when a sibling annotation is broken.
    """

    async def sized(rt, count=0, broken=None):
        del rt, broken
        return {"count": count}

    ## A real type object for `count`, an unresolvable string for `broken` —
    ## get_type_hints raises NameError and returns nothing for either.
    sized.__annotations__ = {"count": int, "broken": "NoSuchTypeAnywhere"}

    with pytest.raises(GodotCommandError) as exc:
        await dispatch_manage_op(
            ops={"go": sized},
            tool_name="x_manage",
            runtime=None,
            op="go",
            params={"count": "not-an-int"},
        )
    assert exc.value.code == ErrorCode.INVALID_PARAMS
    assert exc.value.data["param"] == "count"

    result = await dispatch_manage_op(
        ops={"go": sized},
        tool_name="x_manage",
        runtime=None,
        op="go",
        params={"count": 3},
    )
    assert result == {"count": 3}


@pytest.mark.asyncio
async def test_dispatch_scalar_pin_rejects_container_for_str():
    async def named(rt, name: str):
        del rt
        return {"name": name}

    with pytest.raises(GodotCommandError) as exc:
        await dispatch_manage_op(
            ops={"go": named},
            tool_name="x_manage",
            runtime=None,
            op="go",
            params={"name": {"nested": True}},
        )
    assert exc.value.code == ErrorCode.INVALID_PARAMS
    assert exc.value.data["param"] == "name"


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
    assert "must be nested inside the 'params' object" in exc.value.message
    assert '{"op": "go", "params": {"path": ...}}' in exc.value.message
    assert exc.value.data["received"] == []
    assert exc.value.data["missing"] == ["path"]
    assert exc.value.data["example"] == {"op": "go", "params": {"path": "..."}}


@pytest.mark.asyncio
async def test_dispatch_signature_hint_skips_variadic_params():
    async def needs_path(rt, path, *args, **kwargs):
        del rt, path, args, kwargs
        return {}

    with pytest.raises(GodotCommandError) as exc:
        await dispatch_manage_op(
            ops={"go": needs_path},
            tool_name="x_manage",
            runtime=None,
            op="go",
            params={},
        )

    assert exc.value.data["accepted"] == ["path"]
    assert exc.value.data["required"] == ["path"]
    assert exc.value.data["missing"] == ["path"]


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
    assert "must be nested inside the 'params' object" not in exc.value.message
    assert exc.value.data["received"] == ["extra"]


@pytest.mark.asyncio
async def test_dispatch_extra_param_hint_lists_unexpected_and_accepted():
    """A no-arg op called with extra keys must surface both lists.

    Regression for the fleet-wide project_manage(op="stop") confusion: LLMs
    invent kwargs like force=True. The error must name the offending key and
    the (empty) set of accepted keys so the agent can self-correct.
    """

    async def no_params(rt):
        del rt
        return {}

    with pytest.raises(GodotCommandError) as exc:
        await dispatch_manage_op(
            ops={"stop": no_params},
            tool_name="project_manage",
            runtime=None,
            op="stop",
            params={"force": True, "reason": "user"},
        )

    err = exc.value
    assert err.code == ErrorCode.INVALID_PARAMS
    assert "Unexpected param(s)" in err.message
    assert "'force'" in err.message
    assert "'reason'" in err.message
    assert "Accepted params for op 'stop'" in err.message
    assert err.data["accepted"] == []
    assert err.data["unexpected"] == ["force", "reason"]
    assert err.data["received"] == ["force", "reason"]
    assert err.data["example"] == {"op": "stop", "params": {}}


@pytest.mark.asyncio
async def test_dispatch_nested_session_id_names_top_level_contract():
    async def needs_path(rt, path):
        del rt, path
        return {}

    with pytest.raises(GodotCommandError) as exc:
        await dispatch_manage_op(
            ops={"read": needs_path},
            tool_name="script_manage",
            runtime=None,
            op="read",
            params={"path": "res://x.gd", "session_id": "project@1234"},
        )

    message = exc.value.message
    assert "Unexpected param(s): 'session_id'" in message
    assert "'session_id' is a top-level sibling of 'op' and 'params'" in message
    assert "must be nested inside the 'params' object" not in message


@pytest.mark.asyncio
async def test_dispatch_nested_op_names_top_level_contract():
    async def needs_path(rt, path):
        del rt, path
        return {}

    with pytest.raises(GodotCommandError) as exc:
        await dispatch_manage_op(
            ops={"read": needs_path},
            tool_name="script_manage",
            runtime=None,
            op="read",
            params={"path": "res://x.gd", "op": "read"},
        )

    message = exc.value.message
    assert "Unexpected param(s): 'op'" in message
    assert "'op' is a top-level sibling of 'params' and 'session_id'" in message
    assert "must be nested inside the 'params' object" not in message


@pytest.mark.asyncio
async def test_dispatch_unexpected_key_example_uses_first_accepted_param():
    async def needs_path(rt, path):
        del rt, path
        return {}

    with pytest.raises(GodotCommandError) as exc:
        await dispatch_manage_op(
            ops={"read": needs_path},
            tool_name="script_manage",
            runtime=None,
            op="read",
            params={"path": "res://x.gd", "force": True},
        )

    assert exc.value.data["missing"] == []
    assert exc.value.data["example"] == {
        "op": "read",
        "params": {"path": "..."},
    }


@pytest.mark.asyncio
async def test_dispatch_extra_param_hint_lists_handler_kwargs():
    """Op with several accepted kwargs surfaces those in the hint."""

    async def with_kwargs(rt, mode="main", scene="", autosave=True):
        del rt, mode, scene, autosave
        return {}

    with pytest.raises(GodotCommandError) as exc:
        await dispatch_manage_op(
            ops={"run": with_kwargs},
            tool_name="project_manage",
            runtime=None,
            op="run",
            params={"mode": "main", "bogus": 1},
        )

    err = exc.value
    assert "'bogus'" in err.message
    assert "'mode'" in err.message
    assert "'scene'" in err.message
    assert "'autosave'" in err.message
    assert err.data["accepted"] == ["mode", "scene", "autosave"]
    assert err.data["unexpected"] == ["bogus"]


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
async def test_dispatch_never_decodes_union_with_str_param():
    """#714: a str-accepting union arm means a JSON-shaped string is a
    legitimate literal — `list[str] | str` params must never be decoded,
    or a text payload starting with "[" gets mangled into a list."""
    captured: dict[str, Any] = {}

    async def handler(rt, target: list[str] | str):
        del rt
        captured["target"] = target
        return {}

    await dispatch_manage_op(
        ops={"go": handler},
        tool_name="x_manage",
        runtime=None,
        op="go",
        params={"target": '["literal", "text"]'},
    )
    assert captured["target"] == '["literal", "text"]'


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

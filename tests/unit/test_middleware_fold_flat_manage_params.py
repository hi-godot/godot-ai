"""Unit tests for flat manage-param compatibility (#765)."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

import pytest
from fastmcp.exceptions import ToolError
from mcp.types import CallToolRequestParams
from pydantic import BaseModel, ConfigDict, ValidationError

from godot_ai.middleware import FoldFlatManageParams, ParseStringifiedParams
from godot_ai.tools._meta_tool import MANAGE_TOOL_OPS


@dataclass
class _FakeContext:
    message: CallToolRequestParams


@pytest.fixture
def register_script_manage():
    previous = MANAGE_TOOL_OPS.get("script_manage")
    MANAGE_TOOL_OPS["script_manage"] = ("read", "find_symbols")
    yield
    if previous is None:
        MANAGE_TOOL_OPS.pop("script_manage", None)
    else:
        MANAGE_TOOL_OPS["script_manage"] = previous


async def _record_arguments(seen: list[dict[str, Any] | None]):
    async def _call_next(context: _FakeContext) -> str:
        seen.append(context.message.arguments)
        return "ok"

    return _call_next


async def _raise_call_next(exc: BaseException):
    async def _call_next(_context: _FakeContext):
        raise exc

    return _call_next


def _validation_error(*, params: Any = None, **extra: Any) -> ValidationError:
    class _ManageCall(BaseModel):
        model_config = ConfigDict(extra="forbid")

        op: str
        params: dict[str, Any] | None = None

    try:
        _ManageCall.model_validate({"op": "read", "params": params, **extra})
    except ValidationError as exc:
        return exc
    raise AssertionError("expected validation to fail")


class TestFoldFlatManageParams:
    async def test_folds_flat_key(self, register_script_manage):
        seen: list[dict | None] = []
        ctx = _FakeContext(
            CallToolRequestParams(
                name="script_manage",
                arguments={"op": "read", "path": "res://x.gd"},
            )
        )

        result = await FoldFlatManageParams().on_call_tool(ctx, await _record_arguments(seen))

        assert result == "ok"
        assert seen == [{"op": "read", "params": {"path": "res://x.gd"}}]

    async def test_merges_with_existing_params(self, register_script_manage):
        seen: list[dict | None] = []
        ctx = _FakeContext(
            CallToolRequestParams(
                name="script_manage",
                arguments={
                    "op": "read",
                    "params": {"encoding": "utf-8"},
                    "path": "res://x.gd",
                },
            )
        )

        await FoldFlatManageParams().on_call_tool(ctx, await _record_arguments(seen))

        assert seen == [
            {
                "op": "read",
                "params": {"encoding": "utf-8", "path": "res://x.gd"},
            }
        ]

    async def test_equal_duplicate_is_deduplicated(self, register_script_manage):
        seen: list[dict | None] = []
        ctx = _FakeContext(
            CallToolRequestParams(
                name="script_manage",
                arguments={
                    "op": "read",
                    "path": "res://x.gd",
                    "params": {"path": "res://x.gd"},
                },
            )
        )

        await FoldFlatManageParams().on_call_tool(ctx, await _record_arguments(seen))

        assert seen == [{"op": "read", "params": {"path": "res://x.gd"}}]

    async def test_conflicting_duplicate_has_specific_error(self, register_script_manage):
        ctx = _FakeContext(
            CallToolRequestParams(
                name="script_manage",
                arguments={"op": "read", "path": "A", "params": {"path": "B"}},
            )
        )

        with pytest.raises(ToolError) as info:
            await FoldFlatManageParams().on_call_tool(ctx, await _record_arguments([]))

        message = str(info.value)
        assert "both at the top level ('A') and inside 'params' ('B')" in message
        assert "Keep it in 'params' only" in message
        assert ctx.message.arguments == {
            "op": "read",
            "path": "A",
            "params": {"path": "B"},
        }

    async def test_json_boolean_and_number_are_not_equal_duplicates(self, register_script_manage):
        ctx = _FakeContext(
            CallToolRequestParams(
                name="script_manage",
                arguments={"op": "read", "flag": True, "params": {"flag": 1}},
            )
        )

        with pytest.raises(ToolError, match="passed both at the top level"):
            await FoldFlatManageParams().on_call_tool(ctx, await _record_arguments([]))

    async def test_non_dict_params_with_flat_keys_has_complete_error(self, register_script_manage):
        ctx = _FakeContext(
            CallToolRequestParams(
                name="script_manage",
                arguments={"op": "read", "params": "bad", "path": "res://x.gd"},
            )
        )

        with pytest.raises(ToolError) as info:
            await FoldFlatManageParams().on_call_tool(ctx, await _record_arguments([]))

        message = str(info.value)
        assert "'params' must be an object/dict (got str)" in message
        assert "top-level op param(s) 'path' belong inside it" in message
        assert '"params": {"path": "res://x.gd"}' in message

    async def test_non_dict_params_without_flat_keys_is_untouched(self, register_script_manage):
        seen: list[dict | None] = []
        ctx = _FakeContext(
            CallToolRequestParams(
                name="script_manage",
                arguments={"op": "read", "params": "bad"},
            )
        )

        await FoldFlatManageParams().on_call_tool(ctx, await _record_arguments(seen))

        assert seen == [{"op": "read", "params": "bad"}]

    async def test_wrapper_fields_are_never_folded(self, register_script_manage):
        seen: list[dict | None] = []
        ctx = _FakeContext(
            CallToolRequestParams(
                name="script_manage",
                arguments={
                    "op": "read",
                    "params": {"path": "res://x.gd"},
                    "session_id": "project@1234",
                },
            )
        )

        await FoldFlatManageParams().on_call_tool(ctx, await _record_arguments(seen))

        assert seen == [
            {
                "op": "read",
                "params": {"path": "res://x.gd"},
                "session_id": "project@1234",
            }
        ]

    async def test_non_manage_tool_is_untouched(self, register_script_manage):
        seen: list[dict | None] = []
        ctx = _FakeContext(
            CallToolRequestParams(
                name="script_create",
                arguments={"path": "res://x.gd", "content": "extends Node"},
            )
        )

        await FoldFlatManageParams().on_call_tool(ctx, await _record_arguments(seen))

        assert seen == [{"path": "res://x.gd", "content": "extends Node"}]

    async def test_runs_after_stringified_params_decode(self, register_script_manage):
        seen: list[dict | None] = []
        ctx = _FakeContext(
            CallToolRequestParams(
                name="script_manage",
                arguments={
                    "op": "read",
                    "params": '{"encoding": "utf-8"}',
                    "path": "res://x.gd",
                },
            )
        )
        fold = FoldFlatManageParams()

        async def call_fold(inner_context: _FakeContext):
            return await fold.on_call_tool(inner_context, await _record_arguments(seen))

        await ParseStringifiedParams().on_call_tool(ctx, call_fold)

        assert seen == [
            {
                "op": "read",
                "params": {"encoding": "utf-8", "path": "res://x.gd"},
            }
        ]

    async def test_rewrites_only_pure_top_level_extra_errors(self, register_script_manage):
        exc = _validation_error(path="res://x.gd")
        ctx = _FakeContext(CallToolRequestParams(name="script_manage", arguments={"op": "read"}))

        with pytest.raises(ToolError) as info:
            await FoldFlatManageParams().on_call_tool(ctx, await _raise_call_next(exc))

        message = str(info.value)
        assert "unexpected top-level op param(s): 'path'" in message
        assert "Op-specific parameters go inside 'params'" in message

    async def test_does_not_narrow_mixed_validation_errors(self, register_script_manage):
        exc = _validation_error(params=42, path="res://x.gd")
        assert {error["type"] for error in exc.errors()} == {
            "dict_type",
            "extra_forbidden",
        }
        ctx = _FakeContext(CallToolRequestParams(name="script_manage", arguments={"op": "read"}))

        with pytest.raises(ValidationError) as info:
            await FoldFlatManageParams().on_call_tool(ctx, await _raise_call_next(exc))

        assert info.value is exc

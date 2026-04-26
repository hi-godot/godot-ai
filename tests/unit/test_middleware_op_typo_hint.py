"""Unit tests for the HintOpTypoOnManage middleware (#211)."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Literal

import pytest
from fastmcp.exceptions import ToolError
from mcp.types import CallToolRequestParams
from pydantic import TypeAdapter, ValidationError

from godot_ai.middleware import HintOpTypoOnManage
from godot_ai.tools._meta_tool import MANAGE_TOOL_OPS


@dataclass
class _FakeContext:
    message: CallToolRequestParams


@pytest.fixture
def register_node_manage():
    """Populate the registry like ``register_manage_tool`` would at boot."""
    ops = ("get_children", "delete", "rename", "duplicate")
    MANAGE_TOOL_OPS["node_manage"] = ops
    yield ops
    MANAGE_TOOL_OPS.pop("node_manage", None)


def _make_op_validation_error(typed: str, ops: tuple[str, ...]) -> ValidationError:
    """Trigger a real Pydantic literal_error for a Literal[ops] field.

    Mirrors what FastMCP raises when a ``<domain>_manage`` call's ``op``
    fails the schema's ``Literal[...]`` constraint, so the middleware sees
    the same error shape it would in production.
    """
    op_literal = Literal[ops]  # type: ignore[valid-type]
    ## Wrapping in dict[str, Literal[...]] reshapes the failing loc to look
    ## like FastMCP's call schema (the field is ``op`` rather than the empty
    ## top-level loc Pydantic would produce on a bare TypeAdapter).
    wrapper_ta = TypeAdapter(dict[str, op_literal])  # type: ignore[valid-type]
    try:
        wrapper_ta.validate_python({"op": typed})
    except ValidationError as wrapped:
        return wrapped
    raise AssertionError("Pydantic accepted typed value unexpectedly")


async def _raise_call_next(exc: BaseException):
    async def _call_next(_context):
        raise exc

    return _call_next


async def _ok_call_next(_context):
    return "ok"


class TestHintOpTypoOnManage:
    async def test_passes_through_when_handler_succeeds(self, register_node_manage):
        mw = HintOpTypoOnManage()
        ctx = _FakeContext(
            message=CallToolRequestParams(name="node_manage", arguments={"op": "delete"})
        )
        assert await mw.on_call_tool(ctx, _ok_call_next) == "ok"

    async def test_rewrites_op_typo_with_did_you_mean_hint(self, register_node_manage):
        mw = HintOpTypoOnManage()
        exc = _make_op_validation_error("get_childen", register_node_manage)
        ctx = _FakeContext(
            message=CallToolRequestParams(
                name="node_manage",
                arguments={"op": "get_childen", "params": {"path": "/Main"}},
            )
        )
        with pytest.raises(ToolError) as info:
            await mw.on_call_tool(ctx, await _raise_call_next(exc))

        msg = str(info.value)
        assert "'get_childen'" in msg
        assert "did you mean" in msg.lower()
        assert "'get_children'" in msg
        ## The hint should keep the full valid-op list for the agent.
        assert "'delete'" in msg
        assert "'rename'" in msg

    async def test_falls_back_to_valid_list_when_no_close_match(self):
        ops = ("create", "delete")
        MANAGE_TOOL_OPS["thing_manage"] = ops
        try:
            mw = HintOpTypoOnManage()
            exc = _make_op_validation_error("xyzzy", ops)
            ctx = _FakeContext(
                message=CallToolRequestParams(name="thing_manage", arguments={"op": "xyzzy"})
            )
            with pytest.raises(ToolError) as info:
                await mw.on_call_tool(ctx, await _raise_call_next(exc))

            msg = str(info.value)
            assert "'xyzzy'" in msg
            assert "did you mean" not in msg.lower()
            assert "'create'" in msg
            assert "'delete'" in msg
        finally:
            MANAGE_TOOL_OPS.pop("thing_manage", None)

    async def test_ignores_unregistered_tools(self):
        ## Named verbs (e.g. ``editor_state``) that aren't registered through
        ## ``register_manage_tool`` shouldn't have their errors rewritten —
        ## they don't carry an ``op`` parameter and the user's actual mistake
        ## might be something else entirely.
        mw = HintOpTypoOnManage()
        exc = _make_op_validation_error("creat", ("create", "delete"))
        ctx = _FakeContext(
            message=CallToolRequestParams(name="editor_state", arguments={"op": "creat"})
        )
        with pytest.raises(ValidationError):
            await mw.on_call_tool(ctx, await _raise_call_next(exc))

    async def test_passes_through_non_op_validation_errors(self, register_node_manage):
        ## A literal_error on a different field (e.g. a typed param value)
        ## must not be masked — the user gets Pydantic's normal message.
        op_literal = Literal["create", "delete"]  # type: ignore[valid-type]
        wrapper_ta = TypeAdapter(dict[str, op_literal])  # type: ignore[valid-type]
        try:
            wrapper_ta.validate_python({"some_other_field": "bad"})
        except ValidationError as exc:
            real = exc

        mw = HintOpTypoOnManage()
        ctx = _FakeContext(
            message=CallToolRequestParams(
                name="node_manage",
                arguments={"op": "create", "some_other_field": "bad"},
            )
        )
        with pytest.raises(ValidationError):
            await mw.on_call_tool(ctx, await _raise_call_next(real))

    async def test_passes_through_non_validation_exceptions(self, register_node_manage):
        mw = HintOpTypoOnManage()
        ctx = _FakeContext(
            message=CallToolRequestParams(name="node_manage", arguments={"op": "create"})
        )
        with pytest.raises(RuntimeError, match="boom"):
            await mw.on_call_tool(ctx, await _raise_call_next(RuntimeError("boom")))

    async def test_handles_missing_op_argument(self, register_node_manage):
        ## ``op`` missing entirely is a different shape of error (a
        ## ``missing`` type on most schemas, but Pydantic can still raise
        ## a literal_error against an empty input). The middleware should
        ## still emit a useful message even with no typed-op to compare.
        mw = HintOpTypoOnManage()
        exc = _make_op_validation_error("", register_node_manage)
        ctx = _FakeContext(message=CallToolRequestParams(name="node_manage", arguments=None))
        with pytest.raises(ToolError) as info:
            await mw.on_call_tool(ctx, await _raise_call_next(exc))
        assert "Valid ops" in str(info.value)

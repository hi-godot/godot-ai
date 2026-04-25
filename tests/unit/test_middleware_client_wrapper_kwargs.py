"""Unit tests for the StripClientWrapperKwargs middleware (#193)."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

from mcp.types import CallToolRequestParams

from godot_ai.middleware import CLIENT_WRAPPER_KWARGS, StripClientWrapperKwargs


@dataclass
class _FakeContext:
    message: CallToolRequestParams


async def _record_arguments_call_next(seen: list[dict[str, Any] | None]):
    async def _call_next(context: _FakeContext) -> str:
        seen.append(context.message.arguments)
        return "ok"

    return _call_next


class TestStripClientWrapperKwargs:
    async def test_strips_known_wrapper_kwarg(self):
        seen: list[dict | None] = []
        mw = StripClientWrapperKwargs()
        ctx = _FakeContext(
            message=CallToolRequestParams(
                name="session_list",
                arguments={"task_progress": "- [x] step", "session_id": "s1"},
            )
        )
        result = await mw.on_call_tool(ctx, await _record_arguments_call_next(seen))

        assert result == "ok"
        assert seen == [{"session_id": "s1"}]

    async def test_passes_through_when_no_wrapper_kwarg_present(self):
        seen: list[dict | None] = []
        mw = StripClientWrapperKwargs()
        original = {"session_id": "s1"}
        ctx = _FakeContext(
            message=CallToolRequestParams(name="session_activate", arguments=original)
        )
        await mw.on_call_tool(ctx, await _record_arguments_call_next(seen))

        ## Same dict identity — middleware mustn't reallocate when nothing to strip.
        assert seen[0] is ctx.message.arguments

    async def test_handles_none_arguments(self):
        seen: list[dict | None] = []
        mw = StripClientWrapperKwargs()
        ctx = _FakeContext(message=CallToolRequestParams(name="editor_state", arguments=None))
        await mw.on_call_tool(ctx, await _record_arguments_call_next(seen))
        assert seen == [None]

    async def test_handles_empty_arguments(self):
        seen: list[dict | None] = []
        mw = StripClientWrapperKwargs()
        ctx = _FakeContext(message=CallToolRequestParams(name="editor_state", arguments={}))
        await mw.on_call_tool(ctx, await _record_arguments_call_next(seen))
        assert seen == [{}]

    async def test_unknown_extra_kwarg_passes_through_unchanged(self):
        ## Allowlist — typos and server-specific params reach the tool so
        ## pydantic still surfaces real client bugs as validation errors.
        seen: list[dict | None] = []
        mw = StripClientWrapperKwargs()
        ctx = _FakeContext(
            message=CallToolRequestParams(
                name="session_list",
                arguments={"task_progres": "typo", "bogus": 1},
            )
        )
        await mw.on_call_tool(ctx, await _record_arguments_call_next(seen))
        assert seen == [{"task_progres": "typo", "bogus": 1}]

    def test_allowlist_contains_task_progress(self):
        ## Pinned: removing task_progress without replacing the workaround
        ## reintroduces the Cline failure mode from #193.
        assert "task_progress" in CLIENT_WRAPPER_KWARGS

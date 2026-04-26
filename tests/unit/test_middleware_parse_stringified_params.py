"""Unit tests for the ParseStringifiedParams middleware (#206)."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

from mcp.types import CallToolRequestParams

from godot_ai.middleware import ParseStringifiedParams


@dataclass
class _FakeContext:
    message: CallToolRequestParams


async def _record_arguments_call_next(seen: list[dict[str, Any] | None]):
    async def _call_next(context: _FakeContext) -> str:
        seen.append(context.message.arguments)
        return "ok"

    return _call_next


class TestParseStringifiedParams:
    async def test_decodes_string_params_on_manage_call(self):
        seen: list[dict | None] = []
        mw = ParseStringifiedParams()
        ctx = _FakeContext(
            message=CallToolRequestParams(
                name="resource_manage",
                arguments={
                    "op": "create",
                    "params": '{"type": "BoxMesh", "properties": {"size": {"x": 5}}}',
                },
            )
        )
        result = await mw.on_call_tool(ctx, await _record_arguments_call_next(seen))

        assert result == "ok"
        assert seen == [
            {
                "op": "create",
                "params": {"type": "BoxMesh", "properties": {"size": {"x": 5}}},
            }
        ]

    async def test_passes_through_dict_params_unchanged(self):
        seen: list[dict | None] = []
        mw = ParseStringifiedParams()
        original = {"op": "list", "params": {"limit": 10}}
        ctx = _FakeContext(message=CallToolRequestParams(name="session_manage", arguments=original))
        await mw.on_call_tool(ctx, await _record_arguments_call_next(seen))

        ## Same dict identity: middleware mustn't reallocate when there's
        ## nothing to decode.
        assert seen[0] is ctx.message.arguments
        assert seen[0] == original

    async def test_does_not_touch_non_manage_tool_calls(self):
        ## Flat-arg tools that legitimately take a string ``params`` slot
        ## (none today, but the boundary should hold) must reach the handler
        ## with the raw string. Limiting decode to ``*_manage`` gives us a
        ## single, narrow slot to reason about.
        seen: list[dict | None] = []
        mw = ParseStringifiedParams()
        ctx = _FakeContext(
            message=CallToolRequestParams(
                name="node_set_property",
                arguments={"params": '{"x": 1}'},
            )
        )
        await mw.on_call_tool(ctx, await _record_arguments_call_next(seen))
        assert seen == [{"params": '{"x": 1}'}]

    async def test_invalid_json_left_for_pydantic_to_reject(self):
        ## A genuine string-typed param that happens to look like JSON but
        ## doesn't parse should reach Pydantic untouched, so the user gets
        ## a normal validation error instead of a decoder traceback.
        seen: list[dict | None] = []
        mw = ParseStringifiedParams()
        ctx = _FakeContext(
            message=CallToolRequestParams(
                name="resource_manage",
                arguments={"op": "create", "params": "{not valid json"},
            )
        )
        await mw.on_call_tool(ctx, await _record_arguments_call_next(seen))
        assert seen == [{"op": "create", "params": "{not valid json"}]

    async def test_handles_none_arguments(self):
        seen: list[dict | None] = []
        mw = ParseStringifiedParams()
        ctx = _FakeContext(message=CallToolRequestParams(name="editor_state", arguments=None))
        await mw.on_call_tool(ctx, await _record_arguments_call_next(seen))
        assert seen == [None]

    async def test_handles_missing_params_key(self):
        seen: list[dict | None] = []
        mw = ParseStringifiedParams()
        ctx = _FakeContext(
            message=CallToolRequestParams(name="session_manage", arguments={"op": "list"})
        )
        await mw.on_call_tool(ctx, await _record_arguments_call_next(seen))
        assert seen == [{"op": "list"}]

    async def test_decodes_json_array_params(self):
        ## ``params`` is typed dict-or-None on the rollups, so a JSON-array
        ## payload will still fail Pydantic — but the middleware shouldn't
        ## be the one rejecting it. Decode it and let validation handle it.
        seen: list[dict | None] = []
        mw = ParseStringifiedParams()
        ctx = _FakeContext(
            message=CallToolRequestParams(
                name="node_manage", arguments={"op": "delete", "params": "[1, 2, 3]"}
            )
        )
        await mw.on_call_tool(ctx, await _record_arguments_call_next(seen))
        assert seen == [{"op": "delete", "params": [1, 2, 3]}]

    async def test_non_string_params_untouched(self):
        ## Already-decoded, list, or other types pass straight through —
        ## downstream validation will accept dicts and reject the rest.
        seen: list[dict | None] = []
        mw = ParseStringifiedParams()
        ctx = _FakeContext(
            message=CallToolRequestParams(
                name="node_manage", arguments={"op": "delete", "params": 42}
            )
        )
        await mw.on_call_tool(ctx, await _record_arguments_call_next(seen))
        assert seen == [{"op": "delete", "params": 42}]

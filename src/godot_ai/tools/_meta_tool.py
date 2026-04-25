"""Helper for registering rolled-up `<domain>_manage` MCP tools.

A `<domain>_manage` tool collapses many per-verb tools into a single
dispatched tool that takes `op` (the action name) plus a `params` dict.
The shape mirrors `batch_execute`'s `(command, params)` ergonomic and
keeps the tool count small for clients with hard tool-count caps that
ignore Anthropic's `defer_loading` hint.

Each registered tool exposes `Literal["op_a", "op_b", ...]` for `op`,
so MCP clients with schema-driven autocomplete still see every valid
verb. Unknown ops surface as a structured error with fuzzy
`data.suggestions`.
"""

from __future__ import annotations

import difflib
import inspect
import json
from collections.abc import Awaitable, Callable
from typing import Any, Literal

from fastmcp import Context, FastMCP

from godot_ai.godot_client.client import GodotCommandError
from godot_ai.protocol.errors import ErrorCode
from godot_ai.runtime.direct import DirectRuntime
from godot_ai.runtime.interface import Runtime
from godot_ai.tools import DEFER_META

## Op handlers may be async (the common case) or sync (e.g. session_*).
## ``dispatch_manage_op`` awaits the result if it's awaitable.
OpHandler = Callable[[Runtime, dict[str, Any]], Awaitable[dict] | dict]


def register_manage_tool(
    mcp: FastMCP,
    *,
    tool_name: str,
    description: str,
    ops: dict[str, OpHandler],
) -> None:
    """Register a `<domain>_manage` tool that dispatches by op name.

    Args:
        mcp: FastMCP instance to register on.
        tool_name: Tool name (e.g. ``"theme_manage"``).
        description: Tool docstring; should list every op with its
            required params so agents can compose calls without leaving
            tool-search.
        ops: Mapping of op name to an async ``(runtime, params)`` callable
            that delegates into a shared handler. Each callable is
            responsible for unpacking ``params`` (typically via ``**params``)
            and calling the handler with keyword args.

    The registered tool signature is::

        await manage(ctx, op, params={}, session_id="")

    Unknown ops raise ``GodotCommandError`` with ``INVALID_PARAMS`` and
    ``data.suggestions`` populated by ``difflib.get_close_matches``.
    """
    if not ops:
        raise ValueError(f"register_manage_tool: ops cannot be empty (tool {tool_name!r})")

    op_names = tuple(ops.keys())
    op_literal = Literal[op_names]  # type: ignore[valid-type]

    async def manage(
        ctx: Context,
        op,
        params=None,
        session_id="",
    ) -> dict:
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await dispatch_manage_op(
            ops=ops,
            tool_name=tool_name,
            runtime=runtime,
            op=op,
            params=params,
        )

    # Set annotations explicitly with real type objects so pydantic doesn't
    # try to resolve `op_literal` (a local) against module globals — which
    # is what happens with `from __future__ import annotations`.
    manage.__annotations__ = {
        "ctx": Context,
        "op": op_literal,
        "params": dict[str, Any] | None,
        "session_id": str,
        "return": dict,
    }
    manage.__defaults__ = (None, "")
    manage.__name__ = tool_name
    manage.__qualname__ = tool_name
    manage.__doc__ = description
    mcp.tool(meta=DEFER_META)(manage)


def _coerce_stringified_json_values(params: dict[str, Any]) -> dict[str, Any]:
    """JSON-decode string values that look like ``[...]`` / ``{...}``.

    Mirrors the behaviour of ``godot_ai.tools.JsonCoerced`` but applied at
    the rolled-up tool layer. Some MCP clients (Claude Code as of 2026-04)
    stringify complex-typed arguments before sending; without this coercion
    a list-typed handler arg would arrive as ``str`` and fail to dispatch.

    Conservative — only attempts to parse strings whose first non-whitespace
    char is ``[`` or ``{``, and only replaces the value when ``json.loads``
    succeeds. Anything else is returned untouched.
    """
    coerced: dict[str, Any] = {}
    for key, val in params.items():
        if isinstance(val, str):
            stripped = val.lstrip()
            if stripped.startswith(("[", "{")):
                try:
                    coerced[key] = json.loads(val)
                    continue
                except json.JSONDecodeError:
                    pass
        coerced[key] = val
    return coerced


async def dispatch_manage_op(
    *,
    ops: dict[str, OpHandler],
    tool_name: str,
    runtime: Runtime,
    op: str,
    params: dict[str, Any] | None,
) -> dict:
    """Run one op against ``runtime`` with ``params``.

    Extracted from the closure so unit tests can drive it without spinning
    up a full FastMCP context.
    """
    handler = ops.get(op)
    if handler is None:
        suggestions = difflib.get_close_matches(op, list(ops.keys()), n=3, cutoff=0.5)
        message = f"{tool_name}: unknown op {op!r}"
        if suggestions:
            message += f" — did you mean: {', '.join(suggestions)}?"
        raise GodotCommandError(
            code=ErrorCode.INVALID_PARAMS,
            message=message,
            data={"tool": tool_name, "op": op, "suggestions": suggestions},
        )

    call_params = params or {}
    if not isinstance(call_params, dict):
        raise GodotCommandError(
            code=ErrorCode.INVALID_PARAMS,
            message=f"{tool_name}: 'params' must be an object/dict",
            data={"tool": tool_name, "op": op, "type": type(call_params).__name__},
        )

    call_params = _coerce_stringified_json_values(call_params)

    try:
        result = handler(runtime, call_params)
        if inspect.isawaitable(result):
            result = await result
        return result
    except TypeError as exc:
        raise GodotCommandError(
            code=ErrorCode.INVALID_PARAMS,
            message=f"{tool_name}.{op}: {exc}",
            data={"tool": tool_name, "op": op, "received": list(call_params.keys())},
        ) from exc

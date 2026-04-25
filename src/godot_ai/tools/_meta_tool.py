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

Op handlers are registered as bare callables: each entry in ``ops`` is a
shared handler function (sync or async) accepting ``runtime`` plus the
handler's own keyword args. The dispatcher unpacks ``params`` itself, so
domain registrations stay free of identity-lambda boilerplate.
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
## ``dispatch_manage_op`` awaits the result if it's awaitable. The first
## positional arg is always the runtime; remaining kwargs come from the
## caller's ``params`` dict, unpacked by the dispatcher.
OpHandler = Callable[..., Awaitable[dict] | dict]


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
        ops: Mapping of op name to a handler function. Each handler takes
            ``runtime`` as its first arg and accepts the same keyword args
            as the underlying shared handler in ``handlers/<domain>.py``.
            The dispatcher unpacks ``params`` via ``**`` before calling.

    Unknown ops raise ``GodotCommandError`` with ``INVALID_PARAMS`` and
    ``data.suggestions`` populated by ``difflib.get_close_matches``.
    """
    if not ops:
        raise ValueError(f"register_manage_tool: ops cannot be empty (tool {tool_name!r})")

    op_literal = Literal[tuple(ops.keys())]  # type: ignore[valid-type]

    async def manage(ctx: Context, op, params=None, session_id="") -> dict:
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await dispatch_manage_op(
            ops=ops,
            tool_name=tool_name,
            runtime=runtime,
            op=op,
            params=params,
        )

    ## ``from __future__ import annotations`` would stringify ``op_literal``
    ## and pydantic resolves forward refs against module globals — where the
    ## local Literal does not exist. Setting ``__annotations__`` post-hoc
    ## with real type objects bypasses that resolution path.
    manage.__annotations__ = {
        "ctx": Context,
        "op": op_literal,
        "params": dict[str, Any] | None,
        "session_id": str,
        "return": dict,
    }
    manage.__name__ = tool_name
    manage.__qualname__ = tool_name
    manage.__doc__ = description
    mcp.tool(meta=DEFER_META)(manage)


def _coerce_stringified_json_values(params: dict[str, Any]) -> dict[str, Any]:
    """JSON-decode string values that look like ``[...]`` / ``{...}``.

    Narrower scope than ``godot_ai.tools.JsonCoerced``: that pydantic
    validator runs on every typed param regardless of shape, while this
    function gates on the value's first non-whitespace char. The narrowing
    is intentional — at the meta-tool layer ``params`` values are untyped,
    and naive JSON-decoding of every string would mangle plain-string
    args like a class name (``"BoxMesh"``) into something else.

    Some MCP clients (Claude Code as of 2026-04) stringify complex-typed
    arguments before sending; without this coercion a list-typed handler
    arg arrives as ``str`` and the handler errors.

    Returns ``params`` unchanged when nothing needs coercion (the common
    case) so the dispatcher avoids a needless dict copy.
    """
    needs_coercion = False
    for val in params.values():
        if isinstance(val, str) and val[:1] in ("[", "{"):
            needs_coercion = True
            break
    if not needs_coercion:
        return params

    coerced: dict[str, Any] = {}
    for key, val in params.items():
        if isinstance(val, str) and val[:1] in ("[", "{"):
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

    Note: when called via FastMCP, op-name validation has already happened
    at the Pydantic schema boundary (the wrapper's ``op`` parameter is a
    ``Literal`` of registered op names). The ``difflib`` suggestion path
    below only fires for direct dispatcher calls — e.g. unit tests, or
    a hypothetical future caller that bypasses the schema. Pydantic's
    own ``literal_error`` message already enumerates valid alternatives.

    Extracted from the closure so unit tests can drive it without spinning
    up a full FastMCP context. Handlers are called as
    ``handler(runtime, **params)`` — the ``ops`` map holds bare handler
    references rather than identity-lambda adapters.
    """
    handler = ops.get(op)
    if handler is None:
        suggestions = difflib.get_close_matches(op, ops, n=3, cutoff=0.5)
        message = f"{tool_name}: unknown op {op!r}"
        if suggestions:
            message += f" — did you mean: {', '.join(suggestions)}?"
        raise GodotCommandError(
            code=ErrorCode.INVALID_PARAMS,
            message=message,
            data={"tool": tool_name, "op": op, "suggestions": suggestions},
        )

    call_params = params if params is not None else {}
    if not isinstance(call_params, dict):
        raise GodotCommandError(
            code=ErrorCode.INVALID_PARAMS,
            message=f"{tool_name}: 'params' must be an object/dict",
            data={"tool": tool_name, "op": op, "type": type(call_params).__name__},
        )

    call_params = _coerce_stringified_json_values(call_params)

    try:
        result = handler(runtime, **call_params)
        if inspect.isawaitable(result):
            result = await result
        return result
    except TypeError as exc:
        raise GodotCommandError(
            code=ErrorCode.INVALID_PARAMS,
            message=f"{tool_name}.{op}: {exc}",
            data={"tool": tool_name, "op": op, "received": list(call_params.keys())},
        ) from exc

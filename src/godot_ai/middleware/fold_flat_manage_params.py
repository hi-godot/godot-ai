"""Accept flat op params on registered ``<domain>_manage`` tools (#765).

The canonical rollup shape keeps op-specific arguments inside ``params``::

    {"op": "read", "params": {"path": "res://player.gd"}}

Agents frequently send ``path`` beside ``op`` instead. FastMCP's strict tool
schema rejects that shape before the dispatcher can explain the contract. This
middleware folds transmitted flat keys into ``params`` before validation while
keeping ``op``, ``params``, and ``session_id`` as reserved wrapper fields.
"""

from __future__ import annotations

import json
import logging
from typing import Any

from fastmcp.exceptions import ToolError
from fastmcp.exceptions import ValidationError as FastMCPValidationError
from fastmcp.server.middleware import CallNext, Middleware, MiddlewareContext
from fastmcp.tools.base import ToolResult
from mcp.types import CallToolRequestParams
from pydantic import ValidationError as PydanticValidationError

from godot_ai.middleware._validation_errors import find_pydantic_validation_error
from godot_ai.tools._meta_tool import MANAGE_TOOL_OPS

logger = logging.getLogger(__name__)

_RESERVED_KEYS = frozenset({"op", "params", "session_id"})
_EXTRA_ERROR_TYPES = frozenset({"extra_forbidden", "unexpected_keyword_argument"})
_VALUE_REPR_LIMIT = 120


def _truncate(value: Any, limit: int = _VALUE_REPR_LIMIT) -> str:
    """Return a bounded repr for values echoed in client-facing errors."""
    rendered = repr(value)
    if len(rendered) <= limit:
        return rendered
    if rendered[:1] in {"'", '"'} and rendered[-1:] == rendered[:1]:
        return rendered[: limit - 2] + "…" + rendered[-1]
    return rendered[: limit - 1] + "…"


def _call_example(arguments: dict[str, Any], key: str) -> str:
    """Build a concrete canonical-shape example from the caller's values."""
    value = arguments.get(key, "<value>")
    example_value = _truncate(value) if len(repr(value)) > _VALUE_REPR_LIMIT else value
    example = {
        "op": arguments.get("op", "<op>"),
        "params": {key: example_value},
    }
    try:
        return json.dumps(example, ensure_ascii=False)
    except (TypeError, ValueError):
        return f'{{"op": {json.dumps(example["op"])}, "params": {{{json.dumps(key)}: "..."}}}}'


def _flat_keys(arguments: dict[str, Any]) -> list[str]:
    """Return top-level keys that are candidates for folding into params."""
    return [key for key in arguments if key not in _RESERVED_KEYS]


def _same_json_value(left: Any, right: Any) -> bool:
    """Compare MCP argument values without conflating JSON booleans and numbers."""
    try:
        return json.dumps(left, sort_keys=True) == json.dumps(right, sort_keys=True)
    except (TypeError, ValueError):
        return type(left) is type(right) and left == right


def _extra_params_hint(
    exc: BaseException,
    *,
    tool_name: str,
    arguments: dict[str, Any] | None,
) -> str | None:
    """Return a nesting hint only for a pure top-level-extra validation error."""
    validation_error = find_pydantic_validation_error(exc)
    if validation_error is None:
        return None

    errors = validation_error.errors()
    if not errors:
        return None

    keys: list[str] = []
    for error in errors:
        location = error.get("loc")
        if (
            error.get("type") not in _EXTRA_ERROR_TYPES
            or not isinstance(location, tuple)
            or len(location) != 1
            or not isinstance(location[0], str)
        ):
            return None
        keys.append(location[0])

    raw_arguments = arguments if isinstance(arguments, dict) else {}
    first_key = keys[0]
    example = _call_example(raw_arguments, first_key)
    key_label = ", ".join(repr(key) for key in keys)
    return (
        f"{tool_name}: unexpected top-level op param(s): {key_label}. "
        "Op-specific parameters go inside 'params'; 'op' and 'session_id' "
        f"stay top-level. Correct shape: {example}"
    )


class FoldFlatManageParams(Middleware):
    """Fold transmitted flat op params before FastMCP validates the call."""

    async def on_call_tool(
        self,
        context: MiddlewareContext[CallToolRequestParams],
        call_next: CallNext[CallToolRequestParams, ToolResult],
    ) -> ToolResult:
        tool_name = context.message.name
        arguments = context.message.arguments

        if tool_name in MANAGE_TOOL_OPS and isinstance(arguments, dict):
            flat_keys = _flat_keys(arguments)
            if flat_keys:
                raw_params = arguments.get("params")
                if raw_params is not None and not isinstance(raw_params, dict):
                    example = _call_example(arguments, flat_keys[0])
                    raise ToolError(
                        f"{tool_name}: 'params' must be an object/dict "
                        f"(got {type(raw_params).__name__}); top-level op param(s) "
                        f"{', '.join(repr(key) for key in flat_keys)} belong inside it. "
                        f"Correct shape: {example}"
                    )

                params = raw_params if isinstance(raw_params, dict) else {}

                ## Validate every duplicate before mutating either dictionary so
                ## a later conflict cannot leave an earlier key half-folded.
                for key in flat_keys:
                    if key in params and not _same_json_value(params[key], arguments[key]):
                        raise ToolError(
                            f"{tool_name}: param {key!r} was passed both at the "
                            f"top level ({_truncate(arguments[key])}) and inside "
                            f"'params' ({_truncate(params[key])}). Keep it in "
                            "'params' only."
                        )

                for key in flat_keys:
                    if key not in params:
                        params[key] = arguments[key]
                    del arguments[key]
                arguments["params"] = params
                logger.debug("Folded flat params on %s: %s", tool_name, flat_keys)

        try:
            return await call_next(context)
        except (PydanticValidationError, FastMCPValidationError, ToolError) as exc:
            if tool_name not in MANAGE_TOOL_OPS:
                raise
            hint = _extra_params_hint(
                exc,
                tool_name=tool_name,
                arguments=arguments,
            )
            if hint is None:
                raise
            logger.debug("Rewrote flat-param validation error on %s: %s", tool_name, hint)
            raise ToolError(hint) from exc

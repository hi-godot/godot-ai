"""Augment Pydantic literal_error on ``<domain>_manage`` op typos with a hint.

The ``op`` parameter on every rolled-up ``<domain>_manage`` tool is typed
``Literal[...]`` of the registered op names (see ``tools/_meta_tool.py``).
Pydantic validates this at the FastMCP schema boundary, so a typo like
``node_manage(op="get_childen")`` surfaces as a plain ``literal_error``:

    Input should be 'get_children', 'delete', 'rename', ...

That message lists the alternatives but doesn't single out the closest
match. Op-name typos are the most common rollup-misuse pattern (see #211),
and the in-house ``difflib`` suggester in ``dispatch_manage_op`` never gets
to fire — Pydantic rejects the call before any handler runs.

This middleware catches the ``ValidationError`` for tools registered via
``register_manage_tool`` when the failing field is ``op``, looks the
candidate ops up in ``MANAGE_TOOL_OPS`` (the same registry that built the
``Literal`` schema), and re-raises a ``ToolError`` whose message starts
with a ``difflib.get_close_matches``-derived "Did you mean: ..." hint. The
schema itself is unchanged, so tool-search-aware clients still see the
full ``Literal`` enum.

Two propagation shapes must be handled: through fastmcp 3.4.2, the raw
``pydantic.ValidationError`` flows up through the middleware chain; from
3.4.3 (fastmcp #4128), ``FunctionTool`` wraps it in fastmcp's own
``ValidationError`` with the pydantic error as ``__cause__``. Both shapes
are unwrapped to the same pydantic error before building the hint.
"""

from __future__ import annotations

import difflib
import logging

from fastmcp.exceptions import ToolError
from fastmcp.exceptions import ValidationError as FastMCPValidationError
from fastmcp.server.middleware import CallNext, Middleware, MiddlewareContext
from mcp.types import CallToolRequestParams
from pydantic import ValidationError as PydanticValidationError

from godot_ai.fastmcp_compat import ToolResult
from godot_ai.middleware._validation_errors import find_pydantic_validation_error
from godot_ai.tools._meta_tool import MANAGE_TOOL_OPS

logger = logging.getLogger(__name__)


class HintOpTypoOnManage(Middleware):
    async def on_call_tool(
        self,
        context: MiddlewareContext[CallToolRequestParams],
        call_next: CallNext[CallToolRequestParams, ToolResult],
    ) -> ToolResult:
        try:
            return await call_next(context)
        except (PydanticValidationError, FastMCPValidationError) as exc:
            candidates = MANAGE_TOOL_OPS.get(context.message.name)
            if candidates is None:
                raise
            hint = _build_hint_from_validation_error(exc, context.message.arguments, candidates)
            if hint is None:
                raise
            logger.debug("Rewrote op typo error on %s: %s", context.message.name, hint)
            raise ToolError(hint) from exc
        except ToolError as exc:
            candidates = MANAGE_TOOL_OPS.get(context.message.name)
            if candidates is None:
                raise
            hint = _build_hint_from_tool_error(exc, context.message.arguments, candidates)
            if hint is None:
                raise
            logger.debug("Rewrote wrapped op typo error on %s: %s", context.message.name, hint)
            raise ToolError(hint) from exc


def _build_hint(
    exc: PydanticValidationError, arguments: dict | None, candidates: tuple[str, ...]
) -> str | None:
    """Return a ``Did you mean`` message for an op literal_error, else None.

    Returns None — leaving Pydantic's normal message — in three cases:
      1. The error doesn't include a ``literal_error`` on the ``op`` field.
      2. The same call has additional validation errors (e.g. a wrong-typed
         ``params``); rewriting would mask them.
      3. The user's ``op`` value isn't a string in a way ``difflib`` can
         compare; we still emit a clear "op must be a string" hint instead
         of silently swapping in an empty placeholder.
    """
    errors = exc.errors()
    if len(errors) != 1:
        return None
    err = errors[0]
    if err.get("type") != "literal_error" or err.get("loc") != ("op",):
        return None

    return _build_hint_for_raw_op(arguments, candidates)


def _build_hint_from_validation_error(
    exc: PydanticValidationError | FastMCPValidationError,
    arguments: dict | None,
    candidates: tuple[str, ...],
) -> str | None:
    validation_error = find_pydantic_validation_error(exc)
    if validation_error is None:
        return None
    return _build_hint(validation_error, arguments, candidates)


def _build_hint_from_tool_error(
    exc: ToolError, arguments: dict | None, candidates: tuple[str, ...]
) -> str | None:
    """Return a hint when FastMCP wraps the op ``ValidationError`` as ToolError."""
    validation_error = find_pydantic_validation_error(exc)
    if validation_error is not None:
        return _build_hint(validation_error, arguments, candidates)

    message = str(exc)
    if not _looks_like_single_op_literal_error(message):
        return None
    return _build_hint_for_raw_op(arguments, candidates)


def _looks_like_single_op_literal_error(message: str) -> bool:
    lines = message.splitlines()
    if not lines or not lines[0].startswith("1 validation error "):
        return False
    loc_lines = [line for line in lines[1:] if line and not line[:1].isspace()]
    if loc_lines != ["op"]:
        return False
    return "type=literal_error" in message


def _build_hint_for_raw_op(arguments: dict | None, candidates: tuple[str, ...]) -> str:
    raw_op = arguments.get("op") if isinstance(arguments, dict) else None
    valid_list = ", ".join(repr(c) for c in candidates)

    if not isinstance(raw_op, str):
        return (
            f"op must be a string, got {type(raw_op).__name__} {raw_op!r}. Valid ops: {valid_list}."
        )

    suggestions = difflib.get_close_matches(raw_op, candidates, n=3, cutoff=0.5)
    if suggestions:
        sug_list = ", ".join(repr(s) for s in suggestions)
        return f"Unknown op {raw_op!r} — did you mean {sug_list}? Valid ops: {valid_list}."
    return f"Unknown op {raw_op!r}. Valid ops: {valid_list}."

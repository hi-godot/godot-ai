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
"""

from __future__ import annotations

import difflib
import logging

from fastmcp.exceptions import ToolError
from fastmcp.server.middleware import CallNext, Middleware, MiddlewareContext
from fastmcp.tools.base import ToolResult
from mcp.types import CallToolRequestParams
from pydantic import ValidationError

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
        except ValidationError as exc:
            candidates = MANAGE_TOOL_OPS.get(context.message.name)
            if candidates is None:
                raise
            hint = _build_hint(exc, context.message.arguments, candidates)
            if hint is None:
                raise
            logger.debug("Rewrote op typo error on %s: %s", context.message.name, hint)
            raise ToolError(hint) from exc


def _build_hint(
    exc: ValidationError, arguments: dict | None, candidates: tuple[str, ...]
) -> str | None:
    """Return a ``Did you mean`` message for an op literal_error, else None.

    Returns None — leaving Pydantic's normal message — when the error isn't
    a ``literal_error`` on the ``op`` field. Other validation errors fall
    through unchanged so unrelated bugs aren't masked.
    """
    if not any(
        err.get("type") == "literal_error" and err.get("loc") == ("op",) for err in exc.errors()
    ):
        return None

    typed_op = ""
    if isinstance(arguments, dict):
        raw_op = arguments.get("op")
        if isinstance(raw_op, str):
            typed_op = raw_op

    suggestions = difflib.get_close_matches(typed_op, candidates, n=3, cutoff=0.5)
    valid_list = ", ".join(repr(c) for c in candidates)
    if suggestions:
        sug_list = ", ".join(repr(s) for s in suggestions)
        return f"Unknown op {typed_op!r} — did you mean {sug_list}? Valid ops: {valid_list}."
    return f"Unknown op {typed_op!r}. Valid ops: {valid_list}."

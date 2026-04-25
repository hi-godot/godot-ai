"""Decode stringified ``params`` on ``<domain>_manage`` calls before validation.

PR #203 collapsed ~118 per-verb tools into 39 named verbs plus per-domain
``<domain>_manage`` rollups. Each rollup takes ``op: Literal[...]`` and
``params: dict[str, Any] | None``, validated strictly by Pydantic.

Some MCP clients (Cline observed in the wild) auto-serialize nested-object
arguments before sending. Their ``tools/call`` arrives with
``arguments["params"]`` as a JSON string, and Pydantic strict-mode rejects
the call before any handler runs. This middleware intercepts ``*_manage``
calls and JSON-decodes a string ``params`` slot in place, so downstream
validation sees the dict the client meant to send. See #206.
"""

from __future__ import annotations

import json
import logging

from fastmcp.server.middleware import CallNext, Middleware, MiddlewareContext
from fastmcp.tools.base import ToolResult
from mcp.types import CallToolRequestParams

logger = logging.getLogger(__name__)


class ParseStringifiedParams(Middleware):
    async def on_call_tool(
        self,
        context: MiddlewareContext[CallToolRequestParams],
        call_next: CallNext[CallToolRequestParams, ToolResult],
    ) -> ToolResult:
        arguments = context.message.arguments
        if arguments and context.message.name.endswith("_manage"):
            raw = arguments.get("params")
            if isinstance(raw, str):
                try:
                    parsed = json.loads(raw)
                except json.JSONDecodeError:
                    ## Leave untouched so Pydantic surfaces a normal
                    ## validation error rather than a confusing one
                    ## triggered by a half-decoded value.
                    pass
                else:
                    arguments["params"] = parsed
                    logger.debug(
                        "Decoded stringified params on %s (%d chars)",
                        context.message.name,
                        len(raw),
                    )
        return await call_next(context)

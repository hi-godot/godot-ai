"""Strip known client-injected wrapper kwargs before pydantic tool validation.

FastMCP tool schemas are pydantic-strict (`extra="forbid"`); without this
middleware, any client that decorates every `tools/call` with an extra
kwarg (e.g. Cline's `task_progress`) costs every call a wasted retry. A
narrow allowlist is preferred over a blanket `extra="ignore"` so typo'd
real parameter names still surface as validation errors. See #193.
"""

from __future__ import annotations

import logging

from fastmcp.server.middleware import CallNext, Middleware, MiddlewareContext
from fastmcp.tools.base import ToolResult
from mcp.types import CallToolRequestParams

logger = logging.getLogger(__name__)


## Add a new entry only when a real client is observed injecting it on
## every call against an unrelated server (i.e. it's a wrapper convention,
## not a server-specific param the user mistyped).
CLIENT_WRAPPER_KWARGS: frozenset[str] = frozenset({"task_progress"})


class StripClientWrapperKwargs(Middleware):
    async def on_call_tool(
        self,
        context: MiddlewareContext[CallToolRequestParams],
        call_next: CallNext[CallToolRequestParams, ToolResult],
    ) -> ToolResult:
        arguments = context.message.arguments
        if arguments:
            stripped: list[str] = []
            for key in CLIENT_WRAPPER_KWARGS:
                if key in arguments:
                    del arguments[key]
                    stripped.append(key)
            if stripped:
                logger.debug(
                    "Stripped client wrapper kwarg(s) %s from %s",
                    stripped,
                    context.message.name,
                )
        return await call_next(context)

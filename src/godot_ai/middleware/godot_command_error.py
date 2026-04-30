"""Preserve structured Godot command errors in MCP tool responses."""

from __future__ import annotations

from typing import Any

from fastmcp.server.middleware import CallNext, Middleware, MiddlewareContext
from fastmcp.tools.base import ToolResult
from mcp.types import CallToolRequestParams, CallToolResult, TextContent

from godot_ai.godot_client.client import GodotCommandError


class GodotCommandErrorToolResult(ToolResult):
    """ToolResult variant that can mark the MCP response as an error."""

    def to_mcp_result(self) -> CallToolResult:
        return CallToolResult(
            content=self.content,
            structuredContent=self.structured_content,
            isError=True,
        )


class PreserveGodotCommandErrorData(Middleware):
    async def on_call_tool(
        self,
        context: MiddlewareContext[CallToolRequestParams],
        call_next: CallNext[CallToolRequestParams, ToolResult],
    ) -> ToolResult:
        try:
            return await call_next(context)
        except GodotCommandError as exc:
            error_payload: dict[str, Any] = exc.to_payload()
            return GodotCommandErrorToolResult(
                content=[TextContent(type="text", text=str(exc))],
                structured_content={"error": error_payload},
            )

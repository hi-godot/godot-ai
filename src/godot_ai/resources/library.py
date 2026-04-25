"""MCP list resources — editor state, animations, materials, input map, etc.

Read-only collections that change rarely. Each resource mirrors a tool form
under the equivalent ``<domain>_manage`` op; clients that surface resources
should prefer this URI for active-session reads.
"""

from __future__ import annotations

from typing import Any

from fastmcp import Context, FastMCP

from godot_ai.handlers import editor as editor_handlers
from godot_ai.handlers import input_map as input_map_handlers
from godot_ai.handlers import material as material_handlers
from godot_ai.handlers import testing as testing_handlers
from godot_ai.resources import safe_payload
from godot_ai.runtime.direct import DirectRuntime


def register_library_resources(mcp: FastMCP) -> None:
    @mcp.resource("godot://editor/state", mime_type="application/json")
    async def get_editor_state(ctx: Context) -> dict[str, Any]:
        """Editor version, project name, current scene, readiness, play state."""
        runtime = DirectRuntime.from_context(ctx)
        return await safe_payload(editor_handlers.editor_state(runtime))

    @mcp.resource("godot://materials", mime_type="application/json")
    async def get_materials(ctx: Context) -> dict[str, Any]:
        """All Material resources under res:// (every Material subclass + .tres)."""
        runtime = DirectRuntime.from_context(ctx)
        return await safe_payload(material_handlers.material_list(runtime))

    @mcp.resource("godot://input_map", mime_type="application/json")
    async def get_input_map(ctx: Context) -> dict[str, Any]:
        """All input map actions and their bound events. Excludes built-in ui_*."""
        runtime = DirectRuntime.from_context(ctx)
        return await safe_payload(input_map_handlers.input_map_list(runtime))

    @mcp.resource("godot://performance", mime_type="application/json")
    async def get_performance(ctx: Context) -> dict[str, Any]:
        """Performance singleton snapshot (FPS, memory, draw calls, frame time)."""
        runtime = DirectRuntime.from_context(ctx)
        return await safe_payload(editor_handlers.performance_monitors_get(runtime))

    @mcp.resource("godot://test/results", mime_type="application/json")
    async def get_test_results(ctx: Context) -> dict[str, Any]:
        """Most recent ``test_run`` results without re-executing tests."""
        runtime = DirectRuntime.from_context(ctx)
        return await safe_payload(testing_handlers.test_results_get(runtime))

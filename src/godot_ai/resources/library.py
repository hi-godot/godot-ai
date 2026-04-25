"""MCP list resources — animations, materials, input map, performance, test results.

Read-only collections that change rarely. Each resource mirrors a tool form
under the equivalent ``<domain>_manage`` op; clients that surface resources
should prefer this URI for active-session reads.
"""

from __future__ import annotations

import json

from fastmcp import Context, FastMCP

from godot_ai.handlers import editor as editor_handlers
from godot_ai.handlers import input_map as input_map_handlers
from godot_ai.handlers import material as material_handlers
from godot_ai.handlers import testing as testing_handlers
from godot_ai.runtime.direct import DirectRuntime


async def _safe_json(coro) -> str:
    try:
        return json.dumps(await coro)
    except Exception as exc:
        return json.dumps({"error": str(exc), "connected": False})


def register_library_resources(mcp: FastMCP) -> None:
    @mcp.resource("godot://editor/state", mime_type="application/json")
    async def get_editor_state(ctx: Context) -> str:
        """Editor version, project name, current scene, readiness, play state."""
        runtime = DirectRuntime.from_context(ctx)
        return await _safe_json(editor_handlers.editor_state(runtime))

    @mcp.resource("godot://materials", mime_type="application/json")
    async def get_materials(ctx: Context) -> str:
        """All Material resources under res:// (every Material subclass + .tres)."""
        runtime = DirectRuntime.from_context(ctx)
        return await _safe_json(material_handlers.material_list(runtime))

    @mcp.resource("godot://input_map", mime_type="application/json")
    async def get_input_map(ctx: Context) -> str:
        """All input map actions and their bound events. Excludes built-in ui_*."""
        runtime = DirectRuntime.from_context(ctx)
        return await _safe_json(input_map_handlers.input_map_list(runtime))

    @mcp.resource("godot://performance", mime_type="application/json")
    async def get_performance(ctx: Context) -> str:
        """Performance singleton snapshot (FPS, memory, draw calls, frame time)."""
        runtime = DirectRuntime.from_context(ctx)
        return await _safe_json(editor_handlers.performance_monitors_get(runtime))

    @mcp.resource("godot://test/results", mime_type="application/json")
    async def get_test_results(ctx: Context) -> str:
        """Most recent ``test_run`` results without re-executing tests."""
        runtime = DirectRuntime.from_context(ctx)
        return await _safe_json(testing_handlers.test_results_get(runtime))

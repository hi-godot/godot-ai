"""MCP tools for Environment authoring."""

from __future__ import annotations

from fastmcp import Context, FastMCP

from godot_ai.handlers import environment as environment_handlers
from godot_ai.runtime.direct import DirectRuntime
from godot_ai.tools import DEFER_META


def register_environment_tools(mcp: FastMCP) -> None:
    @mcp.tool(meta=DEFER_META)
    async def environment_create(
        ctx: Context,
        path: str = "",
        preset: str = "default",
        properties: dict | None = None,
        sky: bool | None = None,
        resource_path: str = "",
        overwrite: bool = False,
        session_id: str = "",
    ) -> dict:
        """Create an Environment + Sky + ProceduralSkyMaterial chain for 3D scenes.

        Instantiates the full Environment stack (background mode, ambient
        light, optional procedural sky, optional volumetric fog), tuned to a
        named preset. Either assigns to a WorldEnvironment node in one
        undoable action, or saves the Environment to a .tres file.

        Presets:
        - "default" / "clear": bright procedural sky, daylight ambient.
        - "sunset": warm orange horizon, warm ambient.
        - "night": dark blue sky, low ambient.
        - "fog": clear sky + volumetric fog enabled.

        Pass `properties` (e.g. {"ambient_light_energy": 1.5}) to override
        preset values on the Environment itself.

        Args:
            path: Scene path of a WorldEnvironment node (e.g. "/Main/World").
                Mutually exclusive with resource_path.
            preset: One of "default", "clear", "sunset", "night", "fog".
            properties: Optional dict of Environment property overrides.
            sky: Optional override for whether to create a Sky chain.
                Defaults based on preset (true for all built-in presets).
            resource_path: res:// destination for a saved Environment .tres.
            overwrite: Allow replacing an existing file at resource_path.
            session_id: Optional Godot session to target.
        """
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await environment_handlers.environment_create(
            runtime,
            path=path,
            preset=preset,
            properties=properties,
            sky=sky,
            resource_path=resource_path,
            overwrite=overwrite,
        )

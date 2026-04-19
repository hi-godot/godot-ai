"""MCP tools for editor state inspection."""

from __future__ import annotations

from typing import Annotated

from fastmcp import Context, FastMCP

from godot_ai.handlers import editor as editor_handlers
from godot_ai.runtime.direct import DirectRuntime
from godot_ai.tools import DEFER_META, JsonCoerced


def register_editor_tools(mcp: FastMCP) -> None:
    @mcp.tool()
    async def editor_state(ctx: Context, session_id: str = "") -> dict:
        """Get current Godot editor (IDE) state: version, readiness, open scene.

        Returns Godot version, project name, current scene path,
        and whether the project is currently playing.

        Args:
            session_id: Optional Godot session to target. Empty = active session.
        """
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await editor_handlers.editor_state(runtime)

    @mcp.tool(meta=DEFER_META)
    async def editor_selection_get(ctx: Context, session_id: str = "") -> dict:
        """Get the currently selected nodes in the Godot editor.

        Returns a list of selected node paths.

        Args:
            session_id: Optional Godot session to target. Empty = active session.
        """
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await editor_handlers.editor_selection_get(runtime)

    @mcp.tool(meta=DEFER_META)
    async def logs_read(
        ctx: Context,
        count: int = 50,
        offset: int = 0,
        source: str = "plugin",
        since_run_id: str = "",
        session_id: str = "",
    ) -> dict:
        """Read recent log lines from the Godot editor or running game.

        Three sources are supported:

        - "plugin" (default): MCP plugin's own recv/send/event traffic.
          Buffer caps at 500 lines. Returns the historical
          `{lines: [str], total_count, offset, limit, has_more}` shape.
        - "game": stdout/stderr/push_error/push_warning from the playing
          game. Captured via a Logger subclass inside the
          `_mcp_game_helper` autoload (Godot 4.5+) and ferried over the
          editor-debugger channel. Buffer caps at 2000 lines, clears on
          each project_run, and survives play-stop. Each entry is a
          `{source: "game", level: "info"|"warn"|"error", text}` dict.
          The response also carries `run_id` (rotates per play),
          `is_running`, and `dropped_count` (ring evictions since the
          run started).
        - "all": plugin lines first, then game lines, with `source` on
          each entry so callers can split. No timestamp merge — pull
          per-source if you need chronology.

        Tail pattern: poll `logs_read(source="game", offset=N,
        since_run_id=R)`. When `stale_run_id: true` comes back, reset
        your offset to 0 and capture the new `run_id`.

        Args:
            count: Maximum number of lines to return. Default 50.
            offset: Number of lines to skip from the start. Default 0.
            source: "plugin", "game", or "all". Default "plugin".
            since_run_id: When set on a "game"/"all" call, the response
                carries `stale_run_id: true` if the buffer has rotated to a
                new run since this id was captured. Reset your offset on stale.
            session_id: Optional Godot session to target. Empty = active session.
        """
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await editor_handlers.logs_read(
            runtime,
            count=count,
            offset=offset,
            source=source,
            since_run_id=since_run_id,
        )

    @mcp.tool(output_schema=None, meta=DEFER_META)
    async def editor_screenshot(
        ctx: Context,
        source: str = "viewport",
        max_resolution: int = 640,
        include_image: bool = True,
        view_target: str = "",
        coverage: bool = False,
        elevation: float | None = None,
        azimuth: float | None = None,
        fov: float | None = None,
        session_id: str = "",
    ):
        """Capture a screenshot / image / picture of the Godot editor viewport or running game view.

        Takes a screenshot and optionally returns it as an inline image.

        Sources:
        - "viewport": Captures the 3D editor viewport (default).
        - "game": Captures the running game's own framebuffer (only available
          when the project is running). Works regardless of whether Game
          Embed Mode is on or off, and regardless of whether the game
          workspace is docked or floating — the game is always a separate
          OS process, and the plugin reaches it via Godot's debugger
          channel (the same channel the profiler and remote scene tree
          use). Requires the `_mcp_game_helper` autoload, which the plugin
          registers automatically when it's enabled.

        When include_image is True (default), returns the image as an MCP
        ImageContent block that vision-capable AI models can analyze directly.
        When False, returns only metadata (dimensions, format).

        When view_target is provided, the editor's 3D viewport camera is
        temporarily repositioned to frame the specified Node3D, then restored
        after capture. This may cause a brief visible camera change in the
        viewport. Response always includes AABB geometry metadata (center,
        size, longest ground axis) for planning follow-up shots.

        Recommended workflow for 3D subjects:
        1. Call with coverage=True to get reference shots + AABB metadata.
        2. Evaluate the images — what's visible, what's hidden, what needs
           a closer look?
        3. Call again with specific elevation/azimuth/fov for closeups and
           detail shots YOU choose. Use tight fov (20-30) to zoom in.
        4. Repeat until you have the coverage you need (up to ~15 shots).

        Args:
            source: Capture source — "viewport" or "game". Default "viewport".
            max_resolution: Maximum resolution (longest edge) for the returned image.
                Images larger than this are downscaled. Default 640. Set to 0 for full resolution.
            include_image: Whether to include the image data in the response. Default True.
            view_target: Comma-separated scene paths of Node3D nodes to frame
                (e.g. "/Main/Player" or "/Main/Snowman,/Main/Snowman2").
                A temporary camera renders the scene from an angle that frames all targets.
            coverage: When True and view_target is set, capture two reference shots
                (establishing perspective + orthographic top-down) plus AABB geometry
                metadata (center, size, longest ground axis). Use these to orient yourself,
                then iterate with elevation/azimuth/fov for the closeups and detail shots
                YOU choose — the tool won't guess what's interesting to look at closely.
                Ignored without view_target.
            elevation: Camera elevation angle in degrees (0=level, 90=directly above).
                Use for targeted follow-up shots after reviewing coverage images.
                Only applies when view_target is set. Default 25.
            azimuth: Camera azimuth angle in degrees (0=front, 90=right side, 180=behind).
                Use for targeted follow-up shots after reviewing coverage images.
                Only applies when view_target is set. Default 30.
            fov: Camera field of view in degrees. Lower values (25-35) zoom in like a telephoto
                for detail shots. Higher values (60-75) zoom out for context/establishing shots.
                Only applies when view_target is set. Default uses editor's current FOV.
            session_id: Optional Godot session to target. Empty = active session.
        """
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await editor_handlers.editor_screenshot(
            runtime,
            source=source,
            max_resolution=max_resolution,
            include_image=include_image,
            view_target=view_target,
            coverage=coverage,
            elevation=elevation,
            azimuth=azimuth,
            fov=fov,
        )

    @mcp.tool(meta=DEFER_META)
    async def performance_monitors_get(
        ctx: Context,
        monitors: Annotated[list[str] | None, JsonCoerced] = None,
        session_id: str = "",
    ) -> dict:
        """Get Godot performance monitor values (FPS, memory, draw calls, frame time).

        Returns values from Godot's Performance singleton: FPS, memory usage,
        object counts, render stats, physics stats, and navigation stats.

        Without filters, returns all monitors. Pass a list of monitor names
        to get specific ones.

        Available monitors include:
        - time/fps, time/process, time/physics_process
        - memory/static, memory/static_max
        - object/count, object/resource_count, object/node_count, object/orphan_node_count
        - render/total_objects_in_frame, render/total_draw_calls_in_frame, render/video_mem_used
        - physics_2d/active_objects, physics_3d/active_objects
        - navigation/active_maps, navigation/region_count, navigation/agent_count

        Args:
            monitors: Optional list of monitor names to return. If omitted, returns all.
            session_id: Optional Godot session to target. Empty = active session.
        """
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await editor_handlers.performance_monitors_get(runtime, monitors=monitors)

    @mcp.tool(meta=DEFER_META)
    async def logs_clear(ctx: Context, session_id: str = "") -> dict:
        """Clear the MCP log buffer in the Godot editor.

        Removes all captured log lines. Returns the number of lines cleared.

        Args:
            session_id: Optional Godot session to target. Empty = active session.
        """
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await editor_handlers.logs_clear(runtime)

    @mcp.tool(meta=DEFER_META)
    async def editor_quit(ctx: Context, session_id: str = "") -> dict:
        """Gracefully quit (close / shutdown) the Godot editor (IDE).

        Sends a quit signal to the editor on the next frame, allowing
        any pending responses to be sent first. The editor will close
        cleanly without triggering crash dialogs.

        Args:
            session_id: Optional Godot session to target. Empty = active session.
        """
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await editor_handlers.editor_quit(runtime)

    @mcp.tool(meta=DEFER_META)
    async def editor_reload_plugin(ctx: Context, session_id: str = "") -> dict:
        """Reload the Godot editor plugin and wait for it to reconnect.

        Sends a reload command to the plugin, which disables and re-enables
        itself on the next frame. The tool then waits for the new session
        to connect before returning.

        Requires the MCP server to be running externally (not started by
        the plugin), otherwise the reload will kill the server process.
        Start with: python -m godot_ai --transport streamable-http --port 8000 --reload

        Args:
            session_id: Optional Godot session to target. Empty = active session.
        """
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await editor_handlers.editor_reload_plugin(runtime)

    @mcp.tool(meta=DEFER_META)
    async def editor_selection_set(
        ctx: Context,
        paths: Annotated[list[str], JsonCoerced],
        session_id: str = "",
    ) -> dict:
        """Select nodes in the Godot editor by their scene paths.

        Replaces the current selection with the specified nodes. Any
        paths that don't resolve to existing nodes are reported in
        the not_found list.

        Args:
            paths: List of scene paths to select (e.g. ["/Main/Camera3D", "/Main/Player"]).
            session_id: Optional Godot session to target. Empty = active session.
        """
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await editor_handlers.editor_selection_set(runtime, paths=paths)

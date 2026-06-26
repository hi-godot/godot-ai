"""MCP tools for editor state, logs, screenshots, and reload.

Top-level: ``editor_state`` (core), ``editor_screenshot``, ``editor_reload_plugin``,
``logs_read``. Selection get/set, performance monitors, quit, logs_clear collapse
into ``editor_manage``.
"""

from __future__ import annotations

from fastmcp import Context, FastMCP

from godot_ai.handlers import editor as editor_handlers
from godot_ai.runtime.direct import DirectRuntime
from godot_ai.tools import DEFER_META
from godot_ai.tools._meta_tool import register_manage_tool

_DESCRIPTION = """\
Editor selection, performance monitors, quit, log clearing, game eval.

Resource forms (prefer for active-session reads):
  godot://editor/state, godot://selection/current, godot://performance

Ops:
  • state()
        Editor version, project name, current scene, readiness, play state.
  • selection_get()
        Currently selected node paths in the editor.
  • selection_set(paths)
        Replace the selection with the given list of scene paths.
  • monitors_get(monitors=None)
        Performance singleton values (FPS, memory, draw calls, etc.). Pass
        a list of monitor names to filter; None returns everything.
  • quit()
        Gracefully quit the Godot editor on next frame.
  • logs_clear(clear_debugger_errors=False)
        Clear the MCP log buffer. Returns cleared_count. Pass
        clear_debugger_errors=True to also clear the Debugger dock's
        visible Errors-tab rows (user-facing UI, so opt-in only); the
        response then includes debugger_errors_cleared.
  • game_eval(code)
        Execute GDScript in the running game with return values. Uses
        'await' so user code can await internally. Errors return fast and
        actionable: EVAL_COMPILE_ERROR for a syntax/parse error,
        EVAL_RUNTIME_ERROR (with the real message + line) for a runtime
        error; EVAL_GAME_NOT_READY if the game isn't ready yet — still
        launching (retry once it's up) or the _mcp_game_helper autoload is
        missing/disabled; a genuine infinite loop / never-firing await still
        times out. 'await' only progresses while the game window is focused."""


def register_editor_tools(mcp: FastMCP, *, include_non_core: bool = True) -> None:
    @mcp.tool()
    async def editor_state(ctx: Context, session_id: str = "") -> dict:
        """Get current Godot editor state: version, readiness, open scene, play state.

        Resource form: ``godot://editor/state`` — prefer for active-session reads.
        Also reachable as ``editor_manage(op="state")`` (same handler) for clients
        that prefer a single rolled-up tool.

        Side effect: refreshes the server's session readiness cache from the
        live editor reply. Useful as a recovery step after a write call is
        rejected as ``EDITOR_NOT_READY (state=playing)`` when you already know
        the game has stopped — calling ``editor_state`` once syncs the cache
        and the next write proceeds. Issue #262.

        Args:
            session_id: Optional Godot session to target. Empty = active session.
        """
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await editor_handlers.editor_state(runtime)

    if not include_non_core:
        return

    @mcp.tool(meta=DEFER_META)
    async def logs_read(
        ctx: Context,
        count: int = 50,
        offset: int = 0,
        source: str = "plugin",
        since_run_id: str = "",
        since_cursor: int | None = None,
        include_details: bool = False,
        session_id: str = "",
    ) -> dict:
        """Read recent log lines from the Godot editor, plugin, or running game.

        Resource form: ``godot://logs/recent`` — prefer for active-session reads.

        Sources:
        - "plugin" (default): MCP plugin recv/send/event traffic. Buffer 500.
        - "game": stdout/stderr/push_error/push_warning from playing game
          via ``_mcp_game_helper`` autoload (Godot 4.5+). Buffer 2000, with
          lines retained across runs and tagged by run_id. Default reads return
          current-run lines only; pass ``since_run_id`` from an earlier response
          to read that prior run. Entries: {source, level, text, run_id};
          response carries run_id, current_run_id, is_running, game_status,
          dropped_count, stale_run_id.
        - "editor": editor-process script errors and the Debugger dock's
          visible Errors-tab rows — parse errors, GDScript reload warnings,
          @tool/EditorPlugin runtime errors, push_error/push_warning.
          Logger-backed entries require Godot 4.5+; Errors-tab rows are read
          from the editor UI when available. Use when the editor Output or
          Debugger Errors panel shows red/yellow rows but other sources turned
          up nothing. Buffer 500 for logger-backed entries; Debugger rows are
          live UI state. Entries: {source, level, text, path, line, function}.
          Filtered to .gd/.cs in the user project for Logger-backed entries;
          addons/godot_ai/ dropped. Logger entries fired before plugin enable
          are not captured.
        - "all": plugin → editor → game lines (with source per entry).

        Tail pattern: for game logs, poll the current run with offset=N and
        keep the returned run_id. ``current_run_id`` identifies the active run;
        ``run_id`` identifies the run being read. Passing
        ``since_run_id=old_run_id`` reads retained lines for that prior run, and
        ``stale_run_id: true`` means the requested run is not the current run.
        For editor logs, read once to capture
        ``next_cursor`` and pass it back as ``since_cursor`` on later calls.
        ``since_cursor`` reads Logger-backed editor entries only; live Debugger
        Errors-tab rows are included in regular source="editor" reads but do
        not have stable cursors. When ``since_cursor`` is set, it supersedes
        ``offset``. ``truncated: true`` means older entries fell out of the
        ring before the poll; continue from the returned ``next_cursor`` and
        treat ``oldest_cursor`` as the earliest retained sequence.
        Set ``include_details=True`` for Errors-tab style metadata on game/editor
        entries: original code/rationale, error type, resolved source, and
        stack frames. Default false preserves compact responses.

        Args:
            count: Max lines to return. Default 50.
            offset: Lines to skip. Default 0.
            source: "plugin" | "game" | "editor" | "all". Default "plugin".
            since_run_id: Game-log run id from a previous response; reads that
                retained run instead of the current run.
            since_cursor: Editor-log cursor from a previous source="editor" response.
            include_details: Include rich error metadata for game/editor entries.
            session_id: Optional Godot session to target. Empty = active session.
        """
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await editor_handlers.logs_read(
            runtime,
            count=count,
            offset=offset,
            source=source,
            since_run_id=since_run_id,
            since_cursor=since_cursor,
            include_details=include_details,
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
        """Capture a screenshot of the Godot editor viewport or running game.

        Picking a source: the default ``"viewport"`` captures the editor's 3D
        viewport, which is empty if the edited scene has no Node3D anywhere in
        the tree (or no scene is open). Those cases return ``EDITOR_NOT_READY``
        with ``error.data = {editor_state: "viewport_not_3d", scene_root_type}``
        and an actionable ``error.message`` — switch to ``"cinematic"`` if the
        scene has a Camera3D, or open a scene with 3D content.

        Sources:
        - "viewport" (default): editor 3D viewport. Requires Node3D content in
          the edited scene (root or any descendant); see above for the
          no-3D-content / no-scene error shape.
        - "cinematic": render edited scene through its active Camera3D (no
          editor gizmos). Prefers a Camera3D marked ``current``; falls back to
          the first Camera3D found in a depth-first walk. NODE_NOT_FOUND only
          when the scene contains no Camera3D at all.
        - "game": running game's framebuffer (only when project is running).

        ``include_image=True`` (default) returns an MCP ImageContent block.
        ``view_target`` (comma-separated Node3D paths) reframes editor camera;
        AABB metadata always returned. ``coverage=True`` with view_target
        captures perspective + orthographic top-down references.

        Args:
            source: "viewport" | "cinematic" | "game". Default "viewport".
            max_resolution: Longest-edge resolution. Default 640. 0 = full res.
            include_image: Return image data. Default True.
            view_target: Node3D scene path(s) to frame, comma-separated.
            coverage: With view_target, capture two reference shots + AABB.
            elevation: Camera elevation in degrees (0=level, 90=overhead).
            azimuth: Camera azimuth in degrees (0=front, 90=right).
            fov: Camera FOV in degrees. Tight 20-30 = zoom; 60-75 = context.
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
    async def editor_reload_plugin(ctx: Context, session_id: str = "") -> dict:
        """Reload the Godot editor plugin.

        Disables and re-enables the plugin on the next frame. The response
        shape depends on whether this MCP server was spawned by the plugin
        or launched externally:

        - **Plugin-managed (default install)**: returns a pre-flight ack
          ``{status: "reload_initiated", transport_will_drop: true,
          old_session_id, guidance}`` immediately. The reload kills this
          server, so the WebSocket transport drops; reconnect and call
          ``session_manage(op="list")`` to find the new session_id.

        - **Externally launched** (e.g. ``python -m godot_ai --transport
          streamable-http --port 8000 --reload``): waits for the new
          session to register and returns
          ``{status: "reloaded", old_session_id, new_session_id}``.

        Args:
            session_id: Optional Godot session to target. Empty = active session.
        """
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await editor_handlers.editor_reload_plugin(runtime)

    register_manage_tool(
        mcp,
        tool_name="editor_manage",
        description=_DESCRIPTION,
        ops={
            "state": editor_handlers.editor_state,
            "selection_get": editor_handlers.editor_selection_get,
            "selection_set": editor_handlers.editor_selection_set,
            "monitors_get": editor_handlers.performance_monitors_get,
            "quit": editor_handlers.editor_quit,
            "logs_clear": editor_handlers.logs_clear,
            "game_eval": editor_handlers.game_eval,
        },
        read_resource_forms={
            "state": "godot://editor/state",
            "selection_get": "godot://selection/current",
            "monitors_get": "godot://performance",
            ## quit is destructive but skips require_writable so a stuck
            ## editor can still be quit; logs_clear truncates logs. Neither
            ## has a resource counterpart.
            "quit": None,
            "logs_clear": None,
            "game_eval": None,
        },
    )

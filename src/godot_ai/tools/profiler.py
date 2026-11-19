"""MCP tool for capturing the running game's Profiler, Visual Profiler and Monitors data."""

from __future__ import annotations

from fastmcp import FastMCP

from godot_ai.handlers import profiler as profiler_handlers
from godot_ai.tools._meta_tool import register_manage_tool

_DESCRIPTION = """\
Performance profiling of the running game: what the editor's Profiler,
Visual Profiler and Monitors panels show (frame time, script function time,
CPU/GPU render time per pass, FPS, memory, draw calls), returned as JSON.

Works on any game attached to this editor's debugger: one started with
project_run, or one launched outside the editor with --remote-debug while
Debug > Keep Debug Server Open is on.

Ops:
  - start(profilers=["scripts", "visual", "monitors"], max_functions=128,
          include_native=False)
        Turn on the game's built-in profilers and record their frames.
        "scripts": per-function self/total time and calls, plus frame,
        process, physics and script time. "visual": CPU and GPU time per
        render pass. "monitors": the Performance monitors the game sends
        about once a second. max_functions (16..512) is how many of each
        frame's slowest functions (by total time) the game reports; script_ms
        is the sum of their self time, so raise it when a frame has more
        functions than that. Calling start again restarts the capture.
  - stop()
        Turn the game-side profilers off. Captured frames stay readable.
  - status()
        Whether a capture is running, its duration, frame counts, and frames
        dropped as impossible.
  - get(top_n=20, sort_by="self", last_frames=0, per_frame=False)
        Aggregate the capture (during or after it): frame/process/physics/
        script time stats (avg, min, p50, p90, p99, max, ms), the top_n script
        functions by "self", "total" or "calls" (window totals, per-frame
        averages and medians, script path and line), server step averages,
        render CPU/GPU stats and per-pass averages by Visual Profiler path
        (leaf=true for passes, false for categories), monitor stats, and
        the project's frame-rate cap (capped=true when frames sat at it).
        last_frames=N limits script and visual aggregates to the newest N
        frames; per_frame=True adds one timing row per frame number."""


def register_profiler_tools(mcp: FastMCP) -> None:
    register_manage_tool(
        mcp,
        tool_name="profiler_manage",
        description=_DESCRIPTION,
        ops={
            "start": profiler_handlers.profiler_start,
            "stop": profiler_handlers.profiler_stop,
            "status": profiler_handlers.profiler_status,
            "get": profiler_handlers.profiler_get,
        },
        read_resource_forms={
            "start": None,
            "stop": None,
            "status": None,
            "get": None,
        },
    )

"""Shared handlers for the running game's Profiler / Visual Profiler / Monitors capture."""

from __future__ import annotations

from typing import Any

from godot_ai.runtime.direct import DirectRuntime


async def profiler_start(
    runtime: DirectRuntime,
    profilers: list[str] | None = None,
    max_functions: int = 128,
    include_native: bool = False,
) -> dict:
    params: dict[str, Any] = {"max_functions": max_functions, "include_native": include_native}
    if profilers is not None:
        params["profilers"] = profilers
    return await runtime.send_command("profiler_start", params)


async def profiler_stop(runtime: DirectRuntime) -> dict:
    return await runtime.send_command("profiler_stop", {})


async def profiler_status(runtime: DirectRuntime) -> dict:
    return await runtime.send_command("profiler_status", {})


async def profiler_get(
    runtime: DirectRuntime,
    top_n: int = 20,
    sort_by: str = "self",
    last_frames: int = 0,
    per_frame: bool = False,
) -> dict:
    return await runtime.send_command(
        "profiler_get",
        {"top_n": top_n, "sort_by": sort_by, "last_frames": last_frames, "per_frame": per_frame},
    )

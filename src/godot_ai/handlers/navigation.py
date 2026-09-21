"""Shared handlers for navigation authoring (baking, path queries)."""

from __future__ import annotations

from typing import Any

from godot_ai.handlers._readiness import require_writable_async
from godot_ai.runtime.direct import DirectRuntime

## The plugin's deferred budget for one bake request
## (`_BAKE_DEFERRED_TIMEOUT_MS` in navigation_handler.gd; a source-shape test
## keeps the two together) plus the same transport margin custom.py adds.
NAVIGATION_BAKE_PLUGIN_TIMEOUT_MS = 30000
NAVIGATION_BAKE_TIMEOUT_SEC = NAVIGATION_BAKE_PLUGIN_TIMEOUT_MS / 1000.0 + 2.0


async def navigation_bake(
    runtime: DirectRuntime,
    path: str,
    scene_file: str = "",
    force_sync: bool = True,
) -> dict:
    """Bake a region's navmesh/polygon on a background thread.

    The plugin answers out-of-band (deferred) once the bake settles, so this
    handler claims the plugin's deferred budget plus a transport margin.
    """
    await require_writable_async(runtime)
    params: dict[str, Any] = {"path": path, "force_sync": force_sync}
    if scene_file:
        params["scene_file"] = scene_file
    return await runtime.send_command(
        "navigation_bake",
        params,
        timeout=NAVIGATION_BAKE_TIMEOUT_SEC,
    )


async def navigation_path_get(
    runtime: DirectRuntime,
    from_point: dict[str, Any] | list[Any],
    to_point: dict[str, Any] | list[Any],
    dimension: str = "3d",
    optimize: bool = True,
    navigation_layers: int = 1,
    region_path: str = "",
    force_sync: bool = False,
) -> dict:
    """Query a path on an explicitly selected navigation map (read-only).

    ``region_path`` selects the region whose map to query; when empty the
    edited scene root's world map is used. ``force_sync`` opts in to the
    map's async-iteration toggle + forced sync for same-frame freshness.
    """
    params: dict[str, Any] = {
        "from_point": from_point,
        "to_point": to_point,
        "dimension": dimension,
        "optimize": optimize,
        "navigation_layers": navigation_layers,
        "force_sync": force_sync,
    }
    if region_path:
        params["region_path"] = region_path
    return await runtime.send_command("navigation_path_get", params)

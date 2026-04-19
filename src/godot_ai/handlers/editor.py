"""Shared handlers for editor tools and resources."""

from __future__ import annotations

import base64
import json
import logging

from fastmcp.tools.base import Image as McpImage
from mcp.types import TextContent

from godot_ai.handlers._readiness import require_writable
from godot_ai.runtime.interface import Runtime
from godot_ai.sessions.registry import Session
from godot_ai.tools._pagination import paginate

logger = logging.getLogger(__name__)


async def editor_state(runtime: Runtime) -> dict:
    return await runtime.send_command("get_editor_state")


async def editor_selection_get(runtime: Runtime) -> dict:
    return await runtime.send_command("get_selection")


async def editor_screenshot(
    runtime: Runtime,
    source: str = "viewport",
    max_resolution: int = 640,
    include_image: bool = True,
    view_target: str = "",
    coverage: bool = False,
    elevation: float | None = None,
    azimuth: float | None = None,
    fov: float | None = None,
) -> dict | list:
    params: dict = {"source": source}
    if max_resolution > 0:
        params["max_resolution"] = max_resolution
    if view_target:
        params["view_target"] = view_target
    if coverage:
        params["coverage"] = True
    if elevation is not None:
        params["elevation"] = elevation
    if azimuth is not None:
        params["azimuth"] = azimuth
    if fov is not None:
        params["fov"] = fov

    result = await runtime.send_command("take_screenshot", params, timeout=15.0)

    # --- Coverage response: multiple images ---
    if result.get("coverage") and "images" in result:
        images_meta = []
        for img in result["images"]:
            meta_entry = {
                "label": img["label"],
                "elevation": img["elevation"],
                "azimuth": img["azimuth"],
                "fov": img["fov"],
                "width": img["width"],
                "height": img["height"],
            }
            if img.get("ortho"):
                meta_entry["ortho"] = True
            images_meta.append(meta_entry)
        metadata = {
            "source": result["source"],
            "view_target": view_target,
            "coverage": True,
            "image_count": len(result["images"]),
            "images": images_meta,
        }
        if "view_target_count" in result:
            metadata["view_target_count"] = result["view_target_count"]
        if "view_target_not_found" in result:
            metadata["view_target_not_found"] = result["view_target_not_found"]
        for aabb_key in ("aabb_center", "aabb_size", "aabb_longest_ground_axis"):
            if aabb_key in result:
                metadata[aabb_key] = result[aabb_key]

        if not include_image:
            return metadata

        blocks: list = [TextContent(type="text", text=json.dumps(metadata))]
        for img in result["images"]:
            image_bytes = base64.b64decode(img.get("image_base64", ""))
            blocks.append(McpImage(data=image_bytes, format=img.get("format", "png")))
        return blocks

    # --- Single-image response ---
    metadata = {
        "source": result["source"],
        "width": result["width"],
        "height": result["height"],
        "original_width": result["original_width"],
        "original_height": result["original_height"],
        "format": result["format"],
    }
    if view_target:
        metadata["view_target"] = view_target
        if "view_target_count" in result:
            metadata["view_target_count"] = result["view_target_count"]
        if "view_target_not_found" in result:
            metadata["view_target_not_found"] = result["view_target_not_found"]
    for key in (
        "elevation",
        "azimuth",
        "fov",
        "aabb_center",
        "aabb_size",
        "aabb_longest_ground_axis",
    ):
        if key in result:
            metadata[key] = result[key]

    if not include_image:
        return metadata

    image_b64 = result.get("image_base64", "")
    image_bytes = base64.b64decode(image_b64)
    fmt = result.get("format", "png")

    return [
        TextContent(type="text", text=json.dumps(metadata)),
        McpImage(data=image_bytes, format=fmt),
    ]


async def performance_monitors_get(runtime: Runtime, monitors: list[str] | None = None) -> dict:
    params: dict = {}
    if monitors:
        params["monitors"] = monitors
    return await runtime.send_command("get_performance_monitors", params)


async def logs_clear(runtime: Runtime) -> dict:
    return await runtime.send_command("clear_logs")


_VALID_LOG_SOURCES = ("plugin", "game", "all")


async def logs_read(
    runtime: Runtime,
    count: int = 50,
    offset: int = 0,
    source: str = "plugin",
    since_run_id: str = "",
) -> dict:
    if source not in _VALID_LOG_SOURCES:
        raise ValueError(f"Invalid source '{source}' — use 'plugin', 'game', or 'all'")

    if source == "plugin":
        ## Backward-compatible shape: callers asking for the default
        ## source still receive the historical {lines: [str], ...}
        ## payload, so existing dashboards and tests don't break.
        result = await runtime.send_command("get_logs", {"count": 500, "source": "plugin"})
        ## The plugin response can be either the legacy `{lines: [str]}`
        ## (older plugin versions) or the new structured shape
        ## `{lines: [{source, level, text}], ...}`. Normalize to legacy
        ## strings here so the public Python API doesn't shift under
        ## existing callers.
        raw_lines = result.get("lines", [])
        flat: list[str] = []
        for entry in raw_lines:
            if isinstance(entry, dict):
                flat.append(str(entry.get("text", "")))
            else:
                flat.append(str(entry))
        return paginate(flat, offset, count, key="lines")

    ## game / all: ask the plugin to apply offset+count itself so the
    ## ring buffer's run_id, dropped_count, and is_running stay
    ## authoritative on the editor side.
    result = await runtime.send_command(
        "get_logs", {"count": count, "offset": offset, "source": source}
    )
    run_id = result.get("run_id", "")
    if since_run_id and run_id and run_id != since_run_id:
        ## A new game run has started since the caller's last poll —
        ## tell them to reset their cursor instead of returning stale
        ## lines from the previous play session.
        return {
            "source": source,
            "lines": [],
            "total_count": 0,
            "returned_count": 0,
            "offset": 0,
            "limit": count,
            "has_more": False,
            "run_id": run_id,
            "is_running": result.get("is_running", False),
            "dropped_count": result.get("dropped_count", 0),
            "stale_run_id": True,
        }
    lines = result.get("lines", [])
    total = int(result.get("total_count", len(lines)))
    return {
        "source": source,
        "lines": lines,
        "total_count": total,
        "returned_count": len(lines),
        "offset": offset,
        "limit": count,
        "has_more": offset + count < total,
        "run_id": run_id,
        "is_running": result.get("is_running", False),
        "dropped_count": result.get("dropped_count", 0),
        "stale_run_id": False,
    }


def _find_replacement_session(
    sessions: list[Session],
    known_ids: set[str],
    project_path: str,
) -> Session | None:
    for session in sessions:
        if session.session_id in known_ids:
            continue
        if session.project_path != project_path:
            continue
        return session
    return None


async def editor_reload_plugin(runtime: Runtime) -> dict:
    active = runtime.get_active_session()
    if active is None:
        raise ConnectionError("No active Godot session")
    old_id = active.session_id
    known_ids = {session.session_id for session in runtime.list_sessions()}

    try:
        ## Pin to old_id explicitly so the reload command can't race
        ## active-session changes (e.g. another editor disconnecting mid-call).
        await runtime.send_command("reload_plugin", session_id=old_id, timeout=2.0)
    except (ConnectionError, TimeoutError) as exc:
        logger.debug("Expected disconnect during reload: %s", exc)

    # Check if a replacement session already appeared during the reload command
    # (handles the race where the new session registers before we start waiting)
    new_session = _find_replacement_session(
        list(runtime.list_sessions()),
        known_ids=known_ids,
        project_path=active.project_path,
    )
    if new_session is None:
        new_session = await runtime.wait_for_session(exclude_id=old_id, timeout=15.0)

    runtime.set_active_session(new_session.session_id)
    return {
        "status": "reloaded",
        "old_session_id": old_id,
        "new_session_id": new_session.session_id,
    }


async def editor_quit(runtime: Runtime) -> dict:
    return await runtime.send_command("quit_editor")


async def editor_selection_set(runtime: Runtime, paths: list[str]) -> dict:
    require_writable(runtime)
    return await runtime.send_command("set_selection", {"paths": paths})


async def selection_resource_data(runtime: Runtime) -> dict:
    return await editor_selection_get(runtime)


async def logs_resource_data(runtime: Runtime) -> dict:
    return await runtime.send_command("get_logs", {"count": 100})

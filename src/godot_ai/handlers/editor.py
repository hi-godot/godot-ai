"""Shared handlers for editor tools and resources."""

from __future__ import annotations

import asyncio
import base64
import json
import logging

from fastmcp.tools.base import Image as McpImage
from mcp.types import TextContent

from godot_ai import runtime_info
from godot_ai.handlers._readiness import require_writable_async, sync_readiness_from_snapshot
from godot_ai.runtime.direct import DirectRuntime
from godot_ai.tools._pagination import paginate

logger = logging.getLogger(__name__)

SCREENSHOT_TIMEOUT_SEC = 15.0
GAME_SCREENSHOT_TIMEOUT_SEC = 35.0

## Brief delay between handing the structured pre-flight ack back to
## FastMCP and firing `reload_plugin` over the WebSocket on the
## plugin-managed path. Gives the HTTP/SSE response a chance to flush
## before the plugin tears down our own process. Tests override this
## to 0 so they don't wait. See `editor_reload_plugin` below.
PLUGIN_MANAGED_RELOAD_DELAY_SEC = 0.5

## Strong references to in-flight `_dispatch_reload_async` tasks. The
## event loop only holds weak references to tasks created via
## `create_task`, so without this set a GC cycle landing during the
## post-ack delay could collect the task and silently skip the WS
## reload command — leaving the caller with a "reload_initiated" ack
## but no actual reload. A done-callback removes the task on exit.
_pending_reload_tasks: set[asyncio.Task] = set()


async def editor_state(runtime: DirectRuntime) -> dict:
    """Read live editor state and self-heal the session readiness cache.

    The plugin emits ``readiness_changed`` events when ``_check_state_changes``
    notices a transition, but ``_process`` is paused around save/play frames
    (see ``McpConnection.pause_processing``), so the event can lag actual state
    by one or more ticks. During that window the server's ``session.readiness``
    cache stays at the previous value and a write call gated by
    ``require_writable`` is rejected even though the editor is already
    writeable. Issue #262 reproduced exactly that with an ``editor_state ->
    scene_save`` sequence: editor_state returned ``is_playing: false`` while
    the cache still said ``playing``, blocking the save.

    The plugin's ``get_editor_state`` reads ``EditorInterface.is_playing_scene``
    and ``McpConnection.get_readiness`` directly, so its ``readiness`` field is
    authoritative. Copy it onto the session so a subsequent ``require_writable``
    can't disagree with the value the agent just observed.
    """
    result = await runtime.send_command("get_editor_state")
    sync_readiness_from_snapshot(runtime, result.get("readiness"))
    return result


async def editor_selection_get(runtime: DirectRuntime) -> dict:
    return await runtime.send_command("get_selection")


async def editor_screenshot(
    runtime: DirectRuntime,
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

    timeout = GAME_SCREENSHOT_TIMEOUT_SEC if source == "game" else SCREENSHOT_TIMEOUT_SEC
    result = await runtime.send_command(
        "take_screenshot",
        params,
        timeout=timeout,
    )

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
        "camera_path",
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


async def performance_monitors_get(
    runtime: DirectRuntime, monitors: list[str] | None = None
) -> dict:
    params: dict = {}
    if monitors:
        params["monitors"] = monitors
    return await runtime.send_command("get_performance_monitors", params)


async def logs_clear(runtime: DirectRuntime) -> dict:
    return await runtime.send_command("clear_logs")


_VALID_LOG_SOURCES = ("plugin", "game", "editor", "all")


async def logs_read(
    runtime: DirectRuntime,
    count: int = 50,
    offset: int = 0,
    source: str = "plugin",
    since_run_id: str = "",
) -> dict:
    if source not in _VALID_LOG_SOURCES:
        raise ValueError(f"Invalid source '{source}' — use 'plugin', 'game', 'editor', or 'all'")

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


async def editor_reload_plugin(runtime: DirectRuntime) -> dict:
    active = runtime.get_active_session()
    if active is None:
        raise ConnectionError("No active Godot session")
    old_id = active.session_id

    if runtime_info.is_plugin_managed():
        ## Plugin-managed server: the reload will kill our own process
        ## before any sync `wait_for_session` result can reach the
        ## caller (issue #393). Hand the structured ack back to FastMCP
        ## now so the HTTP response flushes, then dispatch the reload
        ## command from a background task. `new_session_id` is dropped
        ## from this shape because it lives in the *next* server's
        ## registry, which this process can never see.
        task = asyncio.create_task(_dispatch_reload_async(runtime, old_id))
        _pending_reload_tasks.add(task)
        task.add_done_callback(_pending_reload_tasks.discard)
        return {
            "status": "reload_initiated",
            "transport_will_drop": True,
            "old_session_id": old_id,
            "guidance": (
                "Server is plugin-managed; the WebSocket transport will drop "
                "as part of the reload. Reconnect, then call "
                "session_manage(op='list') to find the new session_id."
            ),
        }

    known_ids = {session.session_id for session in runtime.list_sessions()}

    try:
        ## Pin to old_id explicitly so the reload command can't race
        ## active-session changes (e.g. another editor disconnecting mid-call).
        await runtime.send_command("reload_plugin", session_id=old_id, timeout=2.0)
    except (ConnectionError, TimeoutError) as exc:
        logger.debug("Expected disconnect during reload: %s", exc)

    new_session = await runtime.wait_for_session(
        exclude_id=old_id,
        timeout=15.0,
        known_ids=known_ids,
        project_path=active.project_path,
    )

    runtime.set_active_session(new_session.session_id)
    return {
        "status": "reloaded",
        "old_session_id": old_id,
        "new_session_id": new_session.session_id,
    }


async def _dispatch_reload_async(runtime: DirectRuntime, old_id: str) -> None:
    if PLUGIN_MANAGED_RELOAD_DELAY_SEC > 0:
        await asyncio.sleep(PLUGIN_MANAGED_RELOAD_DELAY_SEC)
    try:
        await runtime.send_command("reload_plugin", session_id=old_id, timeout=2.0)
    except (ConnectionError, TimeoutError) as exc:
        logger.debug("Expected disconnect during plugin-managed reload: %s", exc)
    except Exception:
        logger.exception("Unexpected error dispatching plugin-managed reload")


async def editor_quit(runtime: DirectRuntime) -> dict:
    return await runtime.send_command("quit_editor")


async def editor_selection_set(runtime: DirectRuntime, paths: list[str]) -> dict:
    await require_writable_async(runtime)
    return await runtime.send_command("set_selection", {"paths": paths})


async def selection_resource_data(runtime: DirectRuntime) -> dict:
    return await editor_selection_get(runtime)


async def logs_resource_data(runtime: DirectRuntime) -> dict:
    return await runtime.send_command("get_logs", {"count": 100})


async def game_eval(runtime: DirectRuntime, code: str) -> dict:
    """Execute GDScript in the running game. Use 'return' for values.

    Runtime errors in the eval code are not caught — if eval times out,
    check ``logs_read(source='game')`` for push_error output.
    """
    return await runtime.send_command(
        "game_eval", {"code": code}, timeout=15.0
    )


async def game_get_property(runtime: DirectRuntime, node_path: str, property: str) -> dict:
    """Read a property from a node in the running game."""
    return await runtime.send_command(
        "game_get_property",
        {"node_path": node_path, "property": property},
        timeout=10.0,
    )


async def game_set_property(runtime: DirectRuntime, node_path: str, property: str,
                             value, type_hint: str = "") -> dict:
    """Set a property on a node in the running game."""
    return await runtime.send_command(
        "game_set_property",
        {"node_path": node_path, "property": property, "value": value,
         "type_hint": type_hint},
        timeout=10.0,
    )


async def game_call_method(runtime: DirectRuntime, node_path: str, method: str,
                            args: list | None = None) -> dict:
    """Call a method on any node in the running game with optional arguments."""
    return await runtime.send_command(
        "game_call_method",
        {"node_path": node_path, "method": method, "args": args or []},
        timeout=10.0,
    )
async def game_call_method(runtime: DirectRuntime, node_path: str, method: str,
                            args: list | None = None) -> dict:
    """Call a method on any node in the running game with optional arguments."""
    return await runtime.send_command(
        "game_call_method",
        {"node_path": node_path, "method": method, "args": args or []},
        timeout=10.0,
    )


async def game_click(runtime: DirectRuntime, x: float, y: float,
                      button: int = 1) -> dict:
    """Simulate a mouse click at (x,y) in the running game. button: 1=left, 2=right, 3=middle."""
    return await runtime.send_command(
        "game_click", {"x": x, "y": y, "button": button}, timeout=10.0)


async def game_key_press(runtime: DirectRuntime, key: str = "",
                          action: str = "", pressed: bool = True) -> dict:
    """Simulate a key press or input action in the running game."""
    return await runtime.send_command(
        "game_key_press",
        {"key": key, "action": action, "pressed": pressed},
        timeout=10.0,
    )


async def game_mouse_move(runtime: DirectRuntime, x: float, y: float,
                           relative_x: float = 0.0, relative_y: float = 0.0) -> dict:
    """Simulate mouse movement in the running game."""
    return await runtime.send_command(
        "game_mouse_move",
        {"x": x, "y": y, "relative_x": relative_x, "relative_y": relative_y},
        timeout=5.0,
    )


async def game_key_hold(runtime: DirectRuntime, key: str = "",
                         action: str = "") -> dict:
    """Hold a key or input action in the running game (no auto-release)."""
    return await runtime.send_command(
        "game_key_hold", {"key": key, "action": action}, timeout=10.0)


async def game_key_release(runtime: DirectRuntime, key: str = "",
                            action: str = "") -> dict:
    """Release a held key or input action in the running game."""
    return await runtime.send_command(
        "game_key_release", {"key": key, "action": action}, timeout=10.0)


async def game_scroll(runtime: DirectRuntime, x: float = 0.0, y: float = 0.0) -> dict:
    """Simulate mouse scroll wheel in the running game. y>0=up, y<0=down."""
    return await runtime.send_command(
        "game_scroll", {"x": x, "y": y}, timeout=5.0)


async def game_list_signals(runtime: DirectRuntime, node_path: str = "") -> dict:
    """List all signals and their connections on a runtime node."""
    return await runtime.send_command(
        "game_list_signals", {"node_path": node_path}, timeout=10.0)


async def game_connect_signal(runtime: DirectRuntime, node_path: str = "",
                               signal_name: str = "", target_node_path: str = "",
                               target_method: str = "") -> dict:
    """Connect a signal from node_path to a method on target_node_path at runtime."""
    return await runtime.send_command(
        "game_connect_signal", {
            "node_path": node_path,
            "signal_name": signal_name,
            "target_node_path": target_node_path,
            "target_method": target_method,
        }, timeout=10.0)


async def game_disconnect_signal(runtime: DirectRuntime, node_path: str = "",
                                  signal_name: str = "", target_node_path: str = "",
                                  target_method: str = "") -> dict:
    """Disconnect a signal connection at runtime."""
    return await runtime.send_command(
        "game_disconnect_signal", {
            "node_path": node_path,
            "signal_name": signal_name,
            "target_node_path": target_node_path,
            "target_method": target_method,
        }, timeout=10.0)


async def game_emit_signal(runtime: DirectRuntime, node_path: str = "",
                            signal_name: str = "", args: list | None = None) -> dict:
    """Emit a signal on a runtime node with optional arguments."""
    return await runtime.send_command(
        "game_emit_signal", {
            "node_path": node_path,
            "signal_name": signal_name,
            "args": args or [],
        }, timeout=10.0)


async def game_pause(runtime: DirectRuntime, paused: bool = True) -> dict:
    """Pause or resume the running game."""
    return await runtime.send_command(
        "game_pause", {"paused": paused}, timeout=5.0)


async def game_get_scene_tree(runtime: DirectRuntime) -> dict:
    """Get the full runtime scene tree."""
    return await runtime.send_command(
        "game_get_scene_tree", {}, timeout=10.0)


async def game_get_node_info(runtime: DirectRuntime, node_path: str = "") -> dict:
    """Get detailed info about a runtime node (properties, signals, methods, children)."""
    return await runtime.send_command(
        "game_get_node_info", {"node_path": node_path}, timeout=10.0)


async def game_spawn_node(runtime: DirectRuntime, type: str = "",
                           name: str = "", parent_path: str = "/root",
                           properties: dict | None = None) -> dict:
    """Spawn a new node at runtime."""
    return await runtime.send_command(
        "game_spawn_node", {
            "type": type,
            "name": name,
            "parent_path": parent_path,
            "properties": properties or {},
        }, timeout=10.0)


async def game_remove_node(runtime: DirectRuntime, node_path: str = "") -> dict:
    """Remove a node at runtime via queue_free()."""
    return await runtime.send_command(
        "game_remove_node", {"node_path": node_path}, timeout=10.0)


async def game_instantiate_scene(runtime: DirectRuntime, scene_path: str = "",
                                  parent_path: str = "/root") -> dict:
    """Instantiate a PackedScene at runtime."""
    return await runtime.send_command(
        "game_instantiate_scene", {
            "scene_path": scene_path,
            "parent_path": parent_path,
        }, timeout=10.0)


async def game_get_performance(runtime: DirectRuntime) -> dict:
    """Get performance metrics from the running game (FPS, memory, objects, draw calls)."""
    return await runtime.send_command(
        "game_get_performance", {}, timeout=5.0)


async def game_get_ui_elements(runtime: DirectRuntime) -> dict:
    """Scan the runtime UI tree and return visible Control elements."""
    return await runtime.send_command(
        "game_get_ui_elements", {}, timeout=10.0)


async def game_get_nodes_in_group(runtime: DirectRuntime, group: str = "") -> dict:
    """Get all nodes in a group at runtime."""
    return await runtime.send_command(
        "game_get_nodes_in_group", {"group": group}, timeout=10.0)


async def game_find_nodes_by_class(runtime: DirectRuntime, class_name: str = "",
                                    root_path: str = "/root") -> dict:
    """Find all nodes of a given class at runtime."""
    return await runtime.send_command(
        "game_find_nodes_by_class", {
            "class_name": class_name,
            "root_path": root_path,
        }, timeout=10.0)


async def game_get_camera(runtime: DirectRuntime) -> dict:
    """Get active camera info (2D/3D) at runtime."""
    return await runtime.send_command(
        "game_get_camera", {}, timeout=5.0)


async def game_set_camera(runtime: DirectRuntime, position: dict | None = None,
                           rotation: dict | None = None,
                           fov: float | None = None, zoom: dict | None = None) -> dict:
    """Set camera properties at runtime."""
    params: dict = {}
    if position: params["position"] = position
    if rotation: params["rotation"] = rotation
    if fov is not None: params["fov"] = fov
    if zoom: params["zoom"] = zoom
    return await runtime.send_command(
        "game_set_camera", params, timeout=5.0)


async def game_raycast(runtime: DirectRuntime, from_: dict, to: dict,
                        collision_mask: int = 0xFFFFFFFF) -> dict:
    """Perform a 3D or 2D raycast at runtime."""
    return await runtime.send_command(
        "game_raycast", {
            "from": from_,
            "to": to,
            "collision_mask": collision_mask,
        }, timeout=10.0)


async def game_play_animation(runtime: DirectRuntime, node_path: str = "",
                               action: str = "play",
                               animation: str = "") -> dict:
    """Control an AnimationPlayer (play/stop/pause/list) at runtime."""
    return await runtime.send_command(
        "game_play_animation", {
            "node_path": node_path,
            "action": action,
            "animation": animation,
        }, timeout=10.0)


async def game_serialize_state(runtime: DirectRuntime, node_path: str = "/root",
                                action: str = "save", max_depth: int = 5,
                                data: dict | None = None) -> dict:
    """Serialize or restore runtime node state."""
    return await runtime.send_command(
        "game_serialize_state", {
            "node_path": node_path,
            "action": action,
            "max_depth": max_depth,
            "data": data or {},
        }, timeout=15.0)


async def game_get_audio(runtime: DirectRuntime) -> dict:
    """List audio buses and AudioStreamPlayer nodes at runtime."""
    return await runtime.send_command(
        "game_get_audio", {}, timeout=10.0)


async def game_audio_play(runtime: DirectRuntime, node_path: str = "",
                           action: str = "play", stream: str = "",
                           volume: float | None = None, pitch: float | None = None,
                           bus: str = "", from_position: float = 0.0) -> dict:
    """Control AudioStreamPlayer (play/stop/pause/resume) at runtime."""
    params: dict = {"node_path": node_path, "action": action}
    if stream: params["stream"] = stream
    if volume is not None: params["volume"] = volume
    if pitch is not None: params["pitch"] = pitch
    if bus: params["bus"] = bus
    if from_position: params["from_position"] = from_position
    return await runtime.send_command(
        "game_audio_play", params, timeout=10.0)


async def game_audio_bus(runtime: DirectRuntime, bus_name: str = "Master",
                          volume: float | None = None, mute: bool | None = None,
                          solo: bool | None = None) -> dict:
    """Get/set audio bus volume, mute, solo at runtime."""
    params: dict = {"bus_name": bus_name}
    if volume is not None: params["volume"] = volume
    if mute is not None: params["mute"] = mute
    if solo is not None: params["solo"] = solo
    return await runtime.send_command(
        "game_audio_bus", params, timeout=5.0)


async def game_environment(runtime: DirectRuntime, action: str = "get",
                            background_color: dict | None = None,
                            ambient_light_color: dict | None = None,
                            ambient_light_energy: float | None = None,
                            fog_enabled: bool | None = None,
                            fog_density: float | None = None,
                            glow_enabled: bool | None = None,
                            glow_intensity: float | None = None,
                            brightness: float | None = None,
                            contrast: float | None = None,
                            top_color: dict | None = None,
                            horizon_color: dict | None = None) -> dict:
    """Get/set environment settings or create procedural sky at runtime."""
    params: dict = {"action": action}
    if background_color: params["background_color"] = background_color
    if ambient_light_color: params["ambient_light_color"] = ambient_light_color
    if ambient_light_energy is not None: params["ambient_light_energy"] = ambient_light_energy
    if fog_enabled is not None: params["fog_enabled"] = fog_enabled
    if fog_density is not None: params["fog_density"] = fog_density
    if glow_enabled is not None: params["glow_enabled"] = glow_enabled
    if glow_intensity is not None: params["glow_intensity"] = glow_intensity
    if brightness is not None: params["brightness"] = brightness
    if contrast is not None: params["contrast"] = contrast
    if top_color: params["top_color"] = top_color
    if horizon_color: params["horizon_color"] = horizon_color
    return await runtime.send_command(
        "game_environment", params, timeout=10.0)


async def game_physics_body(runtime: DirectRuntime, node_path: str = "",
                             gravity_scale: float | None = None,
                             mass: float | None = None,
                             freeze: bool | None = None,
                             sleeping: bool | None = None,
                             linear_velocity: dict | None = None,
                             angular_velocity: float | dict | None = None,
                             friction: float | None = None,
                             bounce: float | None = None) -> dict:
    """Get/set physics body properties (gravity, mass, velocity, friction) at runtime."""
    params: dict = {"node_path": node_path}
    if gravity_scale is not None: params["gravity_scale"] = gravity_scale
    if mass is not None: params["mass"] = mass
    if freeze is not None: params["freeze"] = freeze
    if sleeping is not None: params["sleeping"] = sleeping
    if linear_velocity: params["linear_velocity"] = linear_velocity
    if angular_velocity is not None: params["angular_velocity"] = angular_velocity
    if friction is not None: params["friction"] = friction
    if bounce is not None: params["bounce"] = bounce
    return await runtime.send_command(
        "game_physics_body", params, timeout=10.0)


async def game_light_3d(runtime: DirectRuntime, action: str = "create",
                         parent_path: str = "/root",
                         light_type: str = "omni",
                         color: dict | None = None, energy: float | None = None,
                         shadows: bool | None = None, range_: float | None = None,
                         name: str = "", node_path: str = "") -> dict:
    """Create or configure 3D lights (directional/omni/spot) at runtime."""
    params: dict = {"action": action}
    if action == "create":
        params["parent_path"] = parent_path
        params["light_type"] = light_type
        if color: params["color"] = color
        if energy is not None: params["energy"] = energy
        if shadows is not None: params["shadows"] = shadows
        if range_ is not None: params["range"] = range_
        if name: params["name"] = name
    else:
        params["node_path"] = node_path
        if color: params["color"] = color
        if energy is not None: params["energy"] = energy
        if shadows is not None: params["shadows"] = shadows
    return await runtime.send_command(
        "game_light_3d", params, timeout=10.0)


async def game_mesh_instance(runtime: DirectRuntime, parent_path: str = "/root",
                              mesh_type: str = "box",
                              size: dict | None = None, radius: float | None = None,
                              height: float | None = None,
                              material: str = "", name: str = "") -> dict:
    """Create primitive 3D meshes (box/sphere/cylinder/capsule/plane) at runtime."""
    params: dict = {"parent_path": parent_path, "mesh_type": mesh_type}
    if size: params["size"] = size
    if radius is not None: params["radius"] = radius
    if height is not None: params["height"] = height
    if material: params["material"] = material
    if name: params["name"] = name
    return await runtime.send_command(
        "game_mesh_instance", params, timeout=10.0)


async def game_navigate_path(runtime: DirectRuntime, start: dict, end: dict,
                              optimize: bool = True) -> dict:
    """Pathfind between two points using the navigation map (2D or 3D)."""
    return await runtime.send_command(
        "game_navigate_path", {"start": start, "end": end, "optimize": optimize},
        timeout=10.0)


async def game_navigation_3d(runtime: DirectRuntime, action: str = "create",
                              parent_path: str = "/root", node_path: str = "",
                              cell_size: float | None = None,
                              agent_radius: float | None = None,
                              agent_height: float | None = None,
                              name: str = "") -> dict:
    """Create or bake NavigationRegion3D at runtime."""
    params: dict = {"action": action}
    if action == "create":
        params["parent_path"] = parent_path
        if cell_size is not None: params["cell_size"] = cell_size
        if agent_radius is not None: params["agent_radius"] = agent_radius
        if agent_height is not None: params["agent_height"] = agent_height
        if name: params["name"] = name
    else:
        params["node_path"] = node_path
    return await runtime.send_command(
        "game_navigation_3d", params, timeout=15.0)


async def game_animation_tree(runtime: DirectRuntime, node_path: str = "",
                               action: str = "get_state",
                               state_name: str = "", param_value: float = 0.0) -> dict:
    """Control AnimationTree (travel/get_state/set_param) at runtime."""
    return await runtime.send_command(
        "game_animation_tree", {
            "node_path": node_path, "action": action,
            "state_name": state_name, "param_value": param_value,
        }, timeout=10.0)


async def game_create_animation(runtime: DirectRuntime, node_path: str = "",
                                 animation_name: str = "", length: float = 1.0,
                                 loop_mode: int = 0, library: str = "",
                                 tracks: list | None = None) -> dict:
    """Create Animation resource with tracks/keyframes at runtime."""
    return await runtime.send_command(
        "game_create_animation", {
            "node_path": node_path, "animation_name": animation_name,
            "length": length, "loop_mode": loop_mode, "library": library,
            "tracks": tracks or [],
        }, timeout=15.0)


async def game_skeleton_ik(runtime: DirectRuntime, node_path: str = "",
                            action: str = "start",
                            target: dict | None = None) -> dict:
    """Control SkeletonIK3D (start/stop/set_target) at runtime."""
    params: dict = {"node_path": node_path, "action": action}
    if target: params["target"] = target
    return await runtime.send_command(
        "game_skeleton_ik", params, timeout=10.0)


async def game_time_scale(runtime: DirectRuntime, action: str = "get",
                           time_scale: float = 1.0) -> dict:
    """Get or set Engine.time_scale at runtime."""
    return await runtime.send_command(
        "game_time_scale", {"action": action, "time_scale": time_scale},
        timeout=5.0)


async def game_window(runtime: DirectRuntime, action: str = "get",
                       width: int | None = None, height: int | None = None,
                       title: str = "") -> dict:
    """Get or set window size/title at runtime."""
    params: dict = {"action": action}
    if width is not None: params["width"] = width
    if height is not None: params["height"] = height
    if title: params["title"] = title
    return await runtime.send_command(
        "game_window", params, timeout=5.0)


async def game_gamepad(runtime: DirectRuntime, type: str = "button",
                        index: int = 0, value: float = 0.0,
                        device: int = 0) -> dict:
    """Simulate gamepad button or axis input at runtime."""
    return await runtime.send_command(
        "game_gamepad", {"type": type, "index": index, "value": value,
                         "device": device}, timeout=5.0)


async def game_mouse_drag(runtime: DirectRuntime, from_x: float = 0.0,
                           from_y: float = 0.0, to_x: float = 0.0,
                           to_y: float = 0.0, button: int = 1) -> dict:
    """Simulate mouse drag from one position to another at runtime."""
    return await runtime.send_command(
        "game_mouse_drag", {"from_x": from_x, "from_y": from_y,
                            "to_x": to_x, "to_y": to_y, "button": button},
        timeout=10.0)


async def game_ui_debug(runtime: DirectRuntime, node_path: str = "",
                          action: str = "get", visible: bool | None = None,
                          text: str = "", position: dict | None = None,
                          size: dict | None = None) -> dict:
    """Get/set UI Control properties (visible, position, size, text) at runtime."""
    params: dict = {"node_path": node_path, "action": action}
    if visible is not None: params["visible"] = visible
    if text and action == "text": params["text"] = text
    if position: params["position"] = position
    if size: params["size"] = size
    return await runtime.send_command(
        "game_ui_debug", params, timeout=5.0)


async def game_debug_draw(runtime: DirectRuntime, action: str = "line",
                           color: dict | None = None, from_: dict | None = None,
                           to: dict | None = None, center: dict | None = None,
                           radius: float = 0.5, size: dict | None = None,
                           duration: int = 0) -> dict:
    """Draw debug lines/spheres/boxes at runtime for visualization."""
    params: dict = {"action": action}
    if color: params["color"] = color
    if from_: params["from"] = from_
    if to: params["to"] = to
    if center: params["center"] = center
    if action == "sphere": params["radius"] = radius
    if size: params["size"] = size
    if duration: params["duration"] = duration
    return await runtime.send_command(
        "game_debug_draw", params, timeout=10.0)


async def game_input_state(runtime: DirectRuntime, action: str = "query",
                            x: float = 0.0, y: float = 0.0,
                            mouse_mode: str = "visible") -> dict:
    """Query input state or warp mouse at runtime."""
    params: dict = {"action": action}
    if action == "warp_mouse": params |= {"x": x, "y": y}
    if action == "mouse_mode": params["mouse_mode"] = mouse_mode
    return await runtime.send_command(
        "game_input_state", params, timeout=5.0)


async def game_create_timer(runtime: DirectRuntime, parent_path: str = "/root",
                              wait_time: float = 1.0, one_shot: bool = False,
                              autostart: bool = False, name: str = "") -> dict:
    """Create a Timer node at runtime."""
    params: dict = {"parent_path": parent_path, "wait_time": wait_time,
                    "one_shot": one_shot, "autostart": autostart}
    if name: params["name"] = name
    return await runtime.send_command(
        "game_create_timer", params, timeout=10.0)


async def game_tween_property(runtime: DirectRuntime, node_path: str = "",
                                property: str = "", final_value=None,
                                duration: float = 1.0) -> dict:
    """Animate a property with a tween at runtime."""
    return await runtime.send_command(
        "game_tween_property", {"node_path": node_path, "property": property,
                                "final_value": final_value, "duration": duration},
        timeout=10.0)

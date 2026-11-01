"""Shared handlers for AnimationPlayer authoring (tracks, keyframes, autoplay)."""

from __future__ import annotations

from typing import Any

from godot_ai.handlers._readiness import require_writable_async
from godot_ai.runtime.direct import DirectRuntime


async def animation_player_create(
    runtime: DirectRuntime,
    parent_path: str,
    name: str = "AnimationPlayer",
) -> dict:
    await require_writable_async(runtime)
    return await runtime.send_command(
        "animation_player_create",
        {"parent_path": parent_path, "name": name},
    )


async def animation_create(
    runtime: DirectRuntime,
    player_path: str,
    name: str,
    length: float,
    loop_mode: str = "none",
    overwrite: bool = False,
) -> dict:
    await require_writable_async(runtime)
    params: dict = {
        "player_path": player_path,
        "name": name,
        "length": length,
        "loop_mode": loop_mode,
    }
    if overwrite:
        params["overwrite"] = True
    return await runtime.send_command("animation_create", params)


async def animation_add_property_track(
    runtime: DirectRuntime,
    player_path: str,
    animation_name: str,
    track_path: str,
    keyframes: list[dict],
    interpolation: str = "linear",
) -> dict:
    await require_writable_async(runtime)
    return await runtime.send_command(
        "animation_add_property_track",
        {
            "player_path": player_path,
            "animation_name": animation_name,
            "track_path": track_path,
            "keyframes": keyframes,
            "interpolation": interpolation,
        },
    )


async def animation_add_method_track(
    runtime: DirectRuntime,
    player_path: str,
    animation_name: str,
    target_node_path: str,
    keyframes: list[dict],
) -> dict:
    await require_writable_async(runtime)
    return await runtime.send_command(
        "animation_add_method_track",
        {
            "player_path": player_path,
            "animation_name": animation_name,
            "target_node_path": target_node_path,
            "keyframes": keyframes,
        },
    )


async def animation_set_autoplay(
    runtime: DirectRuntime,
    player_path: str,
    animation_name: str = "",
) -> dict:
    await require_writable_async(runtime)
    return await runtime.send_command(
        "animation_set_autoplay",
        {"player_path": player_path, "animation_name": animation_name},
    )


async def animation_play(
    runtime: DirectRuntime,
    player_path: str,
    animation_name: str = "",
) -> dict:
    return await runtime.send_command(
        "animation_play",
        {"player_path": player_path, "animation_name": animation_name},
    )


async def animation_stop(
    runtime: DirectRuntime,
    player_path: str,
) -> dict:
    return await runtime.send_command(
        "animation_stop",
        {"player_path": player_path},
    )


async def animation_list(
    runtime: DirectRuntime,
    player_path: str,
) -> dict:
    return await runtime.send_command(
        "animation_list",
        {"player_path": player_path},
    )


async def animation_get(
    runtime: DirectRuntime,
    player_path: str,
    animation_name: str,
) -> dict:
    return await runtime.send_command(
        "animation_get",
        {"player_path": player_path, "animation_name": animation_name},
    )


async def animation_delete(
    runtime: DirectRuntime,
    player_path: str,
    animation_name: str,
) -> dict:
    await require_writable_async(runtime)
    return await runtime.send_command(
        "animation_delete",
        {"player_path": player_path, "animation_name": animation_name},
    )


async def animation_validate(
    runtime: DirectRuntime,
    player_path: str,
    animation_name: str,
) -> dict:
    # Read-only — no require_writable.
    return await runtime.send_command(
        "animation_validate",
        {"player_path": player_path, "animation_name": animation_name},
    )


async def animation_create_simple(
    runtime: DirectRuntime,
    player_path: str,
    name: str,
    tweens: list[dict[str, Any]],
    length: float | None = None,
    loop_mode: str = "none",
    overwrite: bool = False,
) -> dict:
    await require_writable_async(runtime)
    params: dict[str, Any] = {
        "player_path": player_path,
        "name": name,
        "tweens": tweens,
        "loop_mode": loop_mode,
    }
    if length is not None:
        params["length"] = length
    if overwrite:
        params["overwrite"] = True
    return await runtime.send_command("animation_create_simple", params)


async def animation_preset_fade(
    runtime: DirectRuntime,
    player_path: str,
    target_path: str,
    mode: str = "in",
    duration: float = 0.5,
    animation_name: str = "",
    overwrite: bool = False,
) -> dict:
    await require_writable_async(runtime)
    params: dict[str, Any] = {
        "player_path": player_path,
        "target_path": target_path,
        "mode": mode,
        "duration": duration,
    }
    if animation_name:
        params["animation_name"] = animation_name
    if overwrite:
        params["overwrite"] = True
    return await runtime.send_command("animation_preset_fade", params)


async def animation_preset_slide(
    runtime: DirectRuntime,
    player_path: str,
    target_path: str,
    direction: str = "left",
    mode: str = "in",
    distance: float | None = None,
    duration: float = 0.4,
    animation_name: str = "",
    overwrite: bool = False,
) -> dict:
    await require_writable_async(runtime)
    params: dict[str, Any] = {
        "player_path": player_path,
        "target_path": target_path,
        "direction": direction,
        "mode": mode,
        "duration": duration,
    }
    if distance is not None:
        params["distance"] = distance
    if animation_name:
        params["animation_name"] = animation_name
    if overwrite:
        params["overwrite"] = True
    return await runtime.send_command("animation_preset_slide", params)


async def animation_preset_shake(
    runtime: DirectRuntime,
    player_path: str,
    target_path: str,
    intensity: float | None = None,
    duration: float = 0.3,
    frequency: float = 30.0,
    seed: int = 0,
    animation_name: str = "",
    overwrite: bool = False,
) -> dict:
    await require_writable_async(runtime)
    params: dict[str, Any] = {
        "player_path": player_path,
        "target_path": target_path,
        "duration": duration,
        "frequency": frequency,
        "seed": seed,
    }
    if intensity is not None:
        params["intensity"] = intensity
    if animation_name:
        params["animation_name"] = animation_name
    if overwrite:
        params["overwrite"] = True
    return await runtime.send_command("animation_preset_shake", params)


async def animation_preset_pulse(
    runtime: DirectRuntime,
    player_path: str,
    target_path: str,
    from_scale: float = 1.0,
    to_scale: float = 1.1,
    duration: float = 0.4,
    animation_name: str = "",
    overwrite: bool = False,
) -> dict:
    await require_writable_async(runtime)
    params: dict[str, Any] = {
        "player_path": player_path,
        "target_path": target_path,
        "from_scale": from_scale,
        "to_scale": to_scale,
        "duration": duration,
    }
    if animation_name:
        params["animation_name"] = animation_name
    if overwrite:
        params["overwrite"] = True
    return await runtime.send_command("animation_preset_pulse", params)


async def animation_library_add(
    runtime: DirectRuntime,
    player_path: str,
    resource_path: str,
    library_name: str = "",
) -> dict:
    await require_writable_async(runtime)
    return await runtime.send_command(
        "animation_library_add",
        {"player_path": player_path, "resource_path": resource_path, "library_name": library_name},
    )


async def animation_library_remove(
    runtime: DirectRuntime,
    player_path: str,
    library_name: str = "",
) -> dict:
    await require_writable_async(runtime)
    return await runtime.send_command(
        "animation_library_remove",
        {"player_path": player_path, "library_name": library_name},
    )


async def animation_library_list(runtime: DirectRuntime, player_path: str) -> dict:
    return await runtime.send_command("animation_library_list", {"player_path": player_path})


async def animation_tree_create(
    runtime: DirectRuntime,
    parent_path: str,
    player_path: str,
    name: str = "AnimationTree",
    root_type: str = "state_machine",
) -> dict:
    await require_writable_async(runtime)
    return await runtime.send_command(
        "animation_tree_create",
        {
            "parent_path": parent_path,
            "player_path": player_path,
            "name": name,
            "root_type": root_type,
        },
    )


async def animation_tree_get(runtime: DirectRuntime, tree_path: str, graph_path: str = "") -> dict:
    return await runtime.send_command(
        "animation_tree_get", {"tree_path": tree_path, "graph_path": graph_path}
    )


async def animation_tree_node_add(
    runtime: DirectRuntime,
    tree_path: str,
    name: str,
    node_type: str = "AnimationNodeAnimation",
    properties: dict | None = None,
    position: dict | None = None,
    graph_path: str = "",
) -> dict:
    await require_writable_async(runtime)
    return await runtime.send_command(
        "animation_tree_node_add",
        {
            "tree_path": tree_path,
            "name": name,
            "node_type": node_type,
            "properties": properties or {},
            "position": position or {"x": 0, "y": 0},
            "graph_path": graph_path,
        },
    )


async def animation_tree_node_remove(
    runtime: DirectRuntime, tree_path: str, name: str, graph_path: str = ""
) -> dict:
    await require_writable_async(runtime)
    return await runtime.send_command(
        "animation_tree_node_remove",
        {"tree_path": tree_path, "name": name, "graph_path": graph_path},
    )


async def animation_tree_node_set(
    runtime: DirectRuntime, tree_path: str, properties: dict, graph_path: str = ""
) -> dict:
    await require_writable_async(runtime)
    return await runtime.send_command(
        "animation_tree_node_set",
        {"tree_path": tree_path, "properties": properties, "graph_path": graph_path},
    )


async def animation_tree_connect(
    runtime: DirectRuntime,
    tree_path: str,
    input_node: str,
    input_index: int,
    output_node: str,
    graph_path: str = "",
) -> dict:
    await require_writable_async(runtime)
    return await runtime.send_command(
        "animation_tree_connect",
        {
            "tree_path": tree_path,
            "input_node": input_node,
            "input_index": input_index,
            "output_node": output_node,
            "graph_path": graph_path,
        },
    )


async def animation_tree_disconnect(
    runtime: DirectRuntime, tree_path: str, input_node: str, input_index: int, graph_path: str = ""
) -> dict:
    await require_writable_async(runtime)
    return await runtime.send_command(
        "animation_tree_disconnect",
        {
            "tree_path": tree_path,
            "input_node": input_node,
            "input_index": input_index,
            "graph_path": graph_path,
        },
    )


async def animation_tree_transition_add(
    runtime: DirectRuntime,
    tree_path: str,
    from_state: str,
    to_state: str,
    graph_path: str = "",
    properties: dict | None = None,
) -> dict:
    await require_writable_async(runtime)
    return await runtime.send_command(
        "animation_tree_transition_add",
        {
            "tree_path": tree_path,
            "from_state": from_state,
            "to_state": to_state,
            "graph_path": graph_path,
            "properties": properties or {},
        },
    )


async def animation_tree_transition_remove(
    runtime: DirectRuntime, tree_path: str, from_state: str, to_state: str, graph_path: str = ""
) -> dict:
    await require_writable_async(runtime)
    return await runtime.send_command(
        "animation_tree_transition_remove",
        {
            "tree_path": tree_path,
            "from_state": from_state,
            "to_state": to_state,
            "graph_path": graph_path,
        },
    )


async def animation_tree_transition_set(
    runtime: DirectRuntime,
    tree_path: str,
    from_state: str,
    to_state: str,
    graph_path: str = "",
    properties: dict | None = None,
) -> dict:
    await require_writable_async(runtime)
    return await runtime.send_command(
        "animation_tree_transition_set",
        {
            "tree_path": tree_path,
            "from_state": from_state,
            "to_state": to_state,
            "graph_path": graph_path,
            "properties": properties or {},
        },
    )


async def animation_tree_point_add(
    runtime: DirectRuntime,
    tree_path: str,
    name: str,
    position: float | dict,
    node_type: str = "AnimationNodeAnimation",
    properties: dict | None = None,
    at_index: int = -1,
    graph_path: str = "",
) -> dict:
    await require_writable_async(runtime)
    return await runtime.send_command(
        "animation_tree_point_add",
        {
            "tree_path": tree_path,
            "name": name,
            "position": position,
            "node_type": node_type,
            "properties": properties or {},
            "at_index": at_index,
            "graph_path": graph_path,
        },
    )


async def animation_tree_point_remove(
    runtime: DirectRuntime, tree_path: str, name: str, graph_path: str = ""
) -> dict:
    await require_writable_async(runtime)
    return await runtime.send_command(
        "animation_tree_point_remove",
        {"tree_path": tree_path, "name": name, "graph_path": graph_path},
    )


async def animation_tree_point_set(
    runtime: DirectRuntime, tree_path: str, name: str, position: float | dict, graph_path: str = ""
) -> dict:
    await require_writable_async(runtime)
    return await runtime.send_command(
        "animation_tree_point_set",
        {"tree_path": tree_path, "name": name, "position": position, "graph_path": graph_path},
    )

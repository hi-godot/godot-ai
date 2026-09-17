"""Shared handlers for navigation authoring (regions, agents, obstacles, paths)."""

from __future__ import annotations

from typing import Any

from godot_ai.handlers._readiness import require_writable_async
from godot_ai.runtime.direct import DirectRuntime


async def navigation_region_create(
    runtime: DirectRuntime,
    parent_path: str = "",
    dimension: str = "3d",
    name: str = "",
    scene_file: str = "",
) -> dict:
    """Create a NavigationRegion2D/3D with a fresh mesh/polygon resource."""
    await require_writable_async(runtime)
    params: dict[str, Any] = {"parent_path": parent_path, "dimension": dimension}
    if name:
        params["name"] = name
    if scene_file:
        params["scene_file"] = scene_file
    return await runtime.send_command("navigation_region_create", params)


async def navigation_mesh_configure(
    runtime: DirectRuntime,
    path: str,
    scene_file: str = "",
    **properties: Any,
) -> dict:
    """Set navigation mesh/polygon parameters in one undo action.

    Mesh properties are flat params alongside ``path`` (the manage rollup
    unpacks ``params`` as keyword arguments), e.g.
    ``mesh_configure(path="/Main/Region", agent_radius=0.75, cell_size=0.5)``.
    """
    await require_writable_async(runtime)
    params: dict[str, Any] = dict(properties)
    params["path"] = path
    if scene_file:
        params["scene_file"] = scene_file
    return await runtime.send_command("navigation_mesh_configure", params)


async def navigation_bake(
    runtime: DirectRuntime,
    path: str,
    scene_file: str = "",
) -> dict:
    """Bake a region's navigation mesh synchronously from its source geometry."""
    await require_writable_async(runtime)
    params: dict[str, Any] = {"path": path}
    if scene_file:
        params["scene_file"] = scene_file
    return await runtime.send_command("navigation_bake", params)


async def navigation_agent_create(
    runtime: DirectRuntime,
    parent_path: str = "",
    dimension: str = "3d",
    name: str = "",
    scene_file: str = "",
) -> dict:
    """Create a NavigationAgent2D/3D."""
    await require_writable_async(runtime)
    params: dict[str, Any] = {"parent_path": parent_path, "dimension": dimension}
    if name:
        params["name"] = name
    if scene_file:
        params["scene_file"] = scene_file
    return await runtime.send_command("navigation_agent_create", params)


async def navigation_agent_configure(
    runtime: DirectRuntime,
    path: str,
    scene_file: str = "",
    **properties: Any,
) -> dict:
    """Configure a NavigationAgent2D/3D in one undo action.

    Agent properties are flat params alongside ``path``.
    """
    await require_writable_async(runtime)
    params: dict[str, Any] = dict(properties)
    params["path"] = path
    if scene_file:
        params["scene_file"] = scene_file
    return await runtime.send_command("navigation_agent_configure", params)


async def navigation_obstacle_create(
    runtime: DirectRuntime,
    parent_path: str = "",
    dimension: str = "3d",
    name: str = "",
    scene_file: str = "",
) -> dict:
    """Create a NavigationObstacle2D/3D."""
    await require_writable_async(runtime)
    params: dict[str, Any] = {"parent_path": parent_path, "dimension": dimension}
    if name:
        params["name"] = name
    if scene_file:
        params["scene_file"] = scene_file
    return await runtime.send_command("navigation_obstacle_create", params)


async def navigation_obstacle_configure(
    runtime: DirectRuntime,
    path: str,
    scene_file: str = "",
    **properties: Any,
) -> dict:
    """Configure a NavigationObstacle2D/3D in one undo action.

    Obstacle properties are flat params alongside ``path``.
    """
    await require_writable_async(runtime)
    params: dict[str, Any] = dict(properties)
    params["path"] = path
    if scene_file:
        params["scene_file"] = scene_file
    return await runtime.send_command("navigation_obstacle_configure", params)


async def navigation_path_get(
    runtime: DirectRuntime,
    from_point: dict[str, Any] | list[Any],
    to_point: dict[str, Any] | list[Any],
    dimension: str = "3d",
    optimize: bool = True,
    navigation_layers: int = 1,
) -> dict:
    """Query a path on the edited scene's navigation map (read-only)."""
    return await runtime.send_command(
        "navigation_path_get",
        {
            "from_point": from_point,
            "to_point": to_point,
            "dimension": dimension,
            "optimize": optimize,
            "navigation_layers": navigation_layers,
        },
    )

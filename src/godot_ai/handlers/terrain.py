"""Shared handlers for terrain authoring tools."""

from __future__ import annotations

from godot_ai.handlers._readiness import require_writable_async
from godot_ai.runtime.direct import DirectRuntime


async def terrain_create(
    runtime: DirectRuntime,
    parent_path: str,
    name: str = "",
    size: int = 48,
    cell_size: float = 2.0,
    seed: int = 1337,
    noise_type: str = "simplex",
    frequency: float = 0.05,
    octaves: int = 3,
    height_scale: float = 8.0,
    base_height: float = 0.0,
    generate_collision: bool = True,
) -> dict:
    """Create a deterministic heightmap terrain node (FastNoiseLite) with
    optional trimesh collision. Same seed + params => identical mesh.
    """
    await require_writable_async(runtime)
    return await runtime.send_command(
        "terrain_create",
        {
            "parent_path": parent_path,
            "name": name,
            "size": size,
            "cell_size": cell_size,
            "seed": seed,
            "noise_type": noise_type,
            "frequency": frequency,
            "octaves": octaves,
            "height_scale": height_scale,
            "base_height": base_height,
            "generate_collision": generate_collision,
        },
    )


async def terrain_regenerate(
    runtime: DirectRuntime,
    path: str,
    size: int = 48,
    cell_size: float = 2.0,
    seed: int = 1337,
    noise_type: str = "simplex",
    frequency: float = 0.05,
    octaves: int = 3,
    height_scale: float = 8.0,
    base_height: float = 0.0,
    generate_collision: bool = True,
) -> dict:
    """Rebuild an existing terrain container in place with new params; one
    undo action restores the previous mesh/collision state.
    """
    await require_writable_async(runtime)
    return await runtime.send_command(
        "terrain_regenerate",
        {
            "path": path,
            "size": size,
            "cell_size": cell_size,
            "seed": seed,
            "noise_type": noise_type,
            "frequency": frequency,
            "octaves": octaves,
            "height_scale": height_scale,
            "base_height": base_height,
            "generate_collision": generate_collision,
        },
    )

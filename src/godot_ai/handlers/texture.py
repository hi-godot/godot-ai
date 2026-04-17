"""Shared handlers for procedural texture tools."""

from __future__ import annotations

from godot_ai.handlers._readiness import require_writable
from godot_ai.runtime.interface import Runtime


def _target_params(
    path: str,
    property: str,
    resource_path: str,
    overwrite: bool,
) -> dict:
    params: dict = {}
    if path:
        params["path"] = path
    if property:
        params["property"] = property
    if resource_path:
        params["resource_path"] = resource_path
    if overwrite:
        params["overwrite"] = overwrite
    return params


async def gradient_texture_create(
    runtime: Runtime,
    stops: list,
    width: int = 256,
    height: int = 1,
    fill: str = "linear",
    path: str = "",
    property: str = "",
    resource_path: str = "",
    overwrite: bool = False,
) -> dict:
    require_writable(runtime)
    params = {"stops": stops, "width": width, "height": height, "fill": fill}
    params.update(_target_params(path, property, resource_path, overwrite))
    return await runtime.send_command("gradient_texture_create", params)


async def noise_texture_create(
    runtime: Runtime,
    noise_type: str = "simplex_smooth",
    width: int = 512,
    height: int = 512,
    frequency: float = 0.01,
    seed: int = 0,
    fractal_octaves: int = 0,
    path: str = "",
    property: str = "",
    resource_path: str = "",
    overwrite: bool = False,
) -> dict:
    require_writable(runtime)
    params: dict = {
        "noise_type": noise_type,
        "width": width,
        "height": height,
        "frequency": frequency,
        "seed": seed,
    }
    if fractal_octaves > 0:
        params["fractal_octaves"] = fractal_octaves
    params.update(_target_params(path, property, resource_path, overwrite))
    return await runtime.send_command("noise_texture_create", params)

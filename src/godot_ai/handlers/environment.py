"""Shared handlers for environment tools."""

from __future__ import annotations

from godot_ai.handlers._readiness import require_writable
from godot_ai.runtime.interface import Runtime


async def environment_create(
    runtime: Runtime,
    path: str = "",
    preset: str = "default",
    properties: dict | None = None,
    sky: bool | None = None,
    resource_path: str = "",
    overwrite: bool = False,
) -> dict:
    require_writable(runtime)
    params: dict = {"preset": preset}
    if path:
        params["path"] = path
    if resource_path:
        params["resource_path"] = resource_path
    if properties:
        params["properties"] = properties
    if sky is not None:
        params["sky"] = sky
    if overwrite:
        params["overwrite"] = overwrite
    return await runtime.send_command("environment_create", params)

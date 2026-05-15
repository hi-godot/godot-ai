"""Shared handlers for environment tools."""

from __future__ import annotations

from godot_ai.handlers._readiness import require_writable_async
from godot_ai.handlers._target import target_params
from godot_ai.runtime.direct import DirectRuntime


async def environment_create(
    runtime: DirectRuntime,
    path: str = "",
    preset: str = "default",
    properties: dict | None = None,
    sky: bool | dict | None = None,
    resource_path: str = "",
    overwrite: bool = False,
) -> dict:
    await require_writable_async(runtime)
    params: dict = {"preset": preset}
    # environment_create has no `property` param (path targets the whole
    # WorldEnvironment node) — pass "" to the shared helper.
    params.update(target_params(path, "", resource_path, overwrite))
    if properties:
        params["properties"] = properties
    if sky is not None:
        params["sky"] = sky
    return await runtime.send_command("environment_create", params)

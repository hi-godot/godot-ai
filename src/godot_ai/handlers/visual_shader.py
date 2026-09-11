"""Resource-only, stage-aware VisualShader graph creation, reading, and editing."""

from __future__ import annotations

from typing import Any

from godot_ai.handlers._readiness import require_writable_async
from godot_ai.runtime.direct import DirectRuntime

VISUAL_SHADER_CREATE_TIMEOUT_SECONDS = 30.0
VISUAL_SHADER_EDIT_TIMEOUT_SECONDS = 30.0


async def create_graph(
    runtime: DirectRuntime,
    resource_path: str,
    stages: list,
    shader_type: str = "spatial",
    overwrite: bool = False,
    varyings: list | None = None,
) -> dict:
    """Validate and atomically save a VisualShader; assign materials separately."""
    await require_writable_async(runtime)
    params: dict[str, Any] = {
        "resource_path": resource_path,
        "stages": stages,
        "shader_type": shader_type,
        "overwrite": overwrite,
    }
    if varyings:
        params["varyings"] = varyings
    return await runtime.send_command(
        "visual_shader_create_graph",
        params,
        timeout=VISUAL_SHADER_CREATE_TIMEOUT_SECONDS,
    )


async def get_graph(runtime: DirectRuntime, path: str) -> dict:
    """Read a VisualShader graph's stages, nodes, connections, and varyings."""
    return await runtime.send_command("visual_shader_get", {"path": path})


async def node_catalog(
    runtime: DirectRuntime,
    filter: str = "",
    offset: int = 0,
    limit: int = 100,
) -> dict:
    """List instantiable VisualShaderNode classes and their supported params."""
    params: dict[str, Any] = {"offset": offset, "limit": limit}
    if filter:
        params["filter"] = filter
    return await runtime.send_command("visual_shader_node_catalog", params)


async def edit_graph(
    runtime: DirectRuntime,
    resource_path: str,
    operations: list,
) -> dict:
    """Apply a validated operation list to an existing VisualShader resource."""
    await require_writable_async(runtime)
    return await runtime.send_command(
        "visual_shader_edit",
        {"resource_path": resource_path, "operations": operations},
        timeout=VISUAL_SHADER_EDIT_TIMEOUT_SECONDS,
    )

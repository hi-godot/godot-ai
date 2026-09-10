"""Resource-only, stage-aware VisualShader graph creation."""

from godot_ai.handlers._readiness import require_writable_async
from godot_ai.runtime.direct import DirectRuntime


async def create_graph(
    runtime: DirectRuntime,
    resource_path: str,
    stages: list,
    shader_type: str = "spatial",
    overwrite: bool = False,
) -> dict:
    """Validate and atomically save a VisualShader; assign materials separately."""
    await require_writable_async(runtime)
    return await runtime.send_command(
        "visual_shader_create_graph",
        {
            "resource_path": resource_path,
            "stages": stages,
            "shader_type": shader_type,
            "overwrite": overwrite,
        },
    )

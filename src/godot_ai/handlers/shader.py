"""Shared handlers for raw shader authoring — create, read, validate, patch."""

from __future__ import annotations

from godot_ai.handlers._readiness import require_writable_async
from godot_ai.runtime.direct import DirectRuntime


async def shader_create(
    runtime: DirectRuntime,
    resource_path: str,
    code: str,
    overwrite: bool = False,
    shader_type: str = "spatial",
) -> dict:
    """Compile-check and atomically write a .gdshader / .gdshaderinc file."""
    await require_writable_async(runtime)
    return await runtime.send_command(
        "shader_create",
        {
            "resource_path": resource_path,
            "code": code,
            "overwrite": overwrite,
            "shader_type": shader_type,
        },
    )


async def shader_get(runtime: DirectRuntime, path: str) -> dict:
    """Read a raw shader's source and parsed metadata."""
    return await runtime.send_command("shader_get", {"path": path})


async def shader_validate(
    runtime: DirectRuntime,
    code: str,
    kind: str = "shader",
    shader_type: str = "spatial",
) -> dict:
    """Compile shader source without writing anything."""
    return await runtime.send_command(
        "shader_validate",
        {"code": code, "kind": kind, "shader_type": shader_type},
    )


async def shader_list(runtime: DirectRuntime, root: str = "res://") -> dict:
    """List .gdshader / .gdshaderinc files under a project directory."""
    return await runtime.send_command("shader_list", {"root": root})


async def shader_patch(
    runtime: DirectRuntime,
    path: str,
    old_text: str,
    new_text: str,
    replace_all: bool = False,
    shader_type: str = "spatial",
) -> dict:
    """Anchor-edit a shader file and revalidate before replacing it."""
    await require_writable_async(runtime)
    return await runtime.send_command(
        "shader_patch",
        {
            "path": path,
            "old_text": old_text,
            "new_text": new_text,
            "replace_all": replace_all,
            "shader_type": shader_type,
        },
    )

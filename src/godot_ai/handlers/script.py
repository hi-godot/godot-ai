"""Shared handlers for script tools."""

from __future__ import annotations

from godot_ai.handlers._readiness import require_writable
from godot_ai.runtime.interface import Runtime


async def script_create(runtime: Runtime, path: str, content: str = "") -> dict:
    require_writable(runtime)
    return await runtime.send_command(
        "create_script",
        {"path": path, "content": content},
    )


async def script_patch(
    runtime: Runtime,
    path: str,
    old_text: str,
    new_text: str,
    replace_all: bool = False,
) -> dict:
    require_writable(runtime)
    return await runtime.send_command(
        "patch_script",
        {
            "path": path,
            "old_text": old_text,
            "new_text": new_text,
            "replace_all": replace_all,
        },
    )


async def script_read(runtime: Runtime, path: str) -> dict:
    return await runtime.send_command("read_script", {"path": path})


async def script_attach(runtime: Runtime, path: str, script_path: str) -> dict:
    require_writable(runtime)
    return await runtime.send_command(
        "attach_script",
        {"path": path, "script_path": script_path},
    )


async def script_detach(runtime: Runtime, path: str) -> dict:
    require_writable(runtime)
    return await runtime.send_command("detach_script", {"path": path})


async def script_find_symbols(runtime: Runtime, path: str) -> dict:
    return await runtime.send_command("find_symbols", {"path": path})

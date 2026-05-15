"""Shared handlers for autoload tools."""

from __future__ import annotations

from godot_ai.handlers._readiness import require_writable_async
from godot_ai.runtime.direct import DirectRuntime


async def autoload_list(runtime: DirectRuntime) -> dict:
    return await runtime.send_command("list_autoloads")


async def autoload_add(
    runtime: DirectRuntime,
    name: str,
    path: str,
    singleton: bool = True,
) -> dict:
    await require_writable_async(runtime)
    return await runtime.send_command(
        "add_autoload",
        {"name": name, "path": path, "singleton": singleton},
    )


async def autoload_remove(runtime: DirectRuntime, name: str) -> dict:
    await require_writable_async(runtime)
    return await runtime.send_command("remove_autoload", {"name": name})

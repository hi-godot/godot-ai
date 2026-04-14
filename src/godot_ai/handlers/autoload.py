"""Shared handlers for autoload tools."""

from __future__ import annotations

from godot_ai.handlers._readiness import require_writable
from godot_ai.runtime.interface import Runtime


async def autoload_list(runtime: Runtime) -> dict:
    return await runtime.send_command("list_autoloads")


async def autoload_add(
    runtime: Runtime,
    name: str,
    path: str,
    singleton: bool = True,
) -> dict:
    require_writable(runtime)
    return await runtime.send_command(
        "add_autoload",
        {"name": name, "path": path, "singleton": singleton},
    )


async def autoload_remove(runtime: Runtime, name: str) -> dict:
    require_writable(runtime)
    return await runtime.send_command("remove_autoload", {"name": name})

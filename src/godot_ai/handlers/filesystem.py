"""Shared handlers for filesystem tools."""

from __future__ import annotations

from godot_ai.handlers._readiness import require_writable
from godot_ai.runtime.interface import Runtime


async def filesystem_read_text(runtime: Runtime, path: str) -> dict:
    return await runtime.send_command("read_file", {"path": path})


async def filesystem_write_text(runtime: Runtime, path: str, content: str = "") -> dict:
    require_writable(runtime)
    return await runtime.send_command(
        "write_file",
        {"path": path, "content": content},
    )


async def import_reimport(runtime: Runtime, paths: list[str]) -> dict:
    require_writable(runtime)
    return await runtime.send_command("reimport", {"paths": paths})

"""Shared handlers for filesystem tools."""

from __future__ import annotations

from godot_ai.handlers._readiness import require_writable
from godot_ai.runtime.direct import DirectRuntime
from godot_ai.tools._pagination import paginate


async def filesystem_read_text(runtime: DirectRuntime, path: str) -> dict:
    return await runtime.send_command("read_file", {"path": path})


async def filesystem_write_text(runtime: DirectRuntime, path: str, content: str = "") -> dict:
    require_writable(runtime)
    return await runtime.send_command(
        "write_file",
        {"path": path, "content": content},
    )


async def filesystem_reimport(runtime: DirectRuntime, paths: list[str]) -> dict:
    require_writable(runtime)
    return await runtime.send_command("reimport", {"paths": paths})


async def filesystem_search(
    runtime: DirectRuntime,
    name: str = "",
    type: str = "",
    path: str = "",
    offset: int = 0,
    limit: int = 100,
) -> dict:
    params: dict[str, str] = {}
    if name:
        params["name"] = name
    if type:
        params["type"] = type
    if path:
        params["path"] = path
    result = await runtime.send_command("search_filesystem", params)
    return paginate(result.get("files", []), offset, limit, key="files")

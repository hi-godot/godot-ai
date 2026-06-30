"""Shared handlers for filesystem tools."""

from __future__ import annotations

from godot_ai.handlers._readiness import require_writable_async
from godot_ai.runtime.direct import DirectRuntime
from godot_ai.tools._pagination import paginate


async def filesystem_read_text(runtime: DirectRuntime, path: str) -> dict:
    return await runtime.send_command("read_file", {"path": path})


async def filesystem_write_text(runtime: DirectRuntime, path: str, content: str = "") -> dict:
    await require_writable_async(runtime)
    return await runtime.send_command(
        "write_file",
        {"path": path, "content": content},
    )


async def filesystem_reimport(runtime: DirectRuntime, paths: list[str]) -> dict:
    await require_writable_async(runtime)
    return await runtime.send_command("reimport", {"paths": paths})


async def filesystem_scan(runtime: DirectRuntime) -> dict:
    """Force a full editor filesystem scan and wait for it to settle.

    Registers ``class_name`` scripts added since the last scan into the global
    class table — the headless equivalent of the editor regaining window focus.

    Deliberately not ``require_writable``-gated: a scan is a refresh and must
    run even while the editor reports ``"importing"`` (a scan already in
    flight), where the plugin's single-flight handler simply awaits the running
    scan. A full scan can exceed the default command timeout on large projects,
    and the plugin caps its own wait at 28s, so a 35s command timeout leaves
    headroom.
    """
    return await runtime.send_command("scan_filesystem", {}, timeout=35.0)


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

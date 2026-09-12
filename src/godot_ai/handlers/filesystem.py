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


## Move/rename/remove walk the whole editor filesystem tree calling
## ``ResourceLoader.get_dependencies`` on every resource file to find owners
## of the affected paths (the same owner search the FileSystemDock runs). On
## a large project that can exceed the default command timeout, so give it
## the same headroom as ``filesystem_scan``.
_REORGANIZE_TIMEOUT = 30.0


async def filesystem_move(runtime: DirectRuntime, path: str, new_path: str) -> dict:
    """Move a file or directory inside ``res://`` with editor-side fixups.

    Routes through the plugin so ``.uid``/``.import`` sidecars travel with the
    file, ``uid://`` references keep resolving, and dependent ``.tscn``/
    ``.tres`` files get their ``path=`` references rewritten (#907).
    """
    await require_writable_async(runtime)
    return await runtime.send_command(
        "move_file",
        {"path": path, "new_path": new_path},
        timeout=_REORGANIZE_TIMEOUT,
    )


async def filesystem_rename(runtime: DirectRuntime, path: str, new_name: str) -> dict:
    """Rename a file or directory in place (``new_name`` is a bare name)."""
    await require_writable_async(runtime)
    return await runtime.send_command(
        "rename_file",
        {"path": path, "new_name": new_name},
        timeout=_REORGANIZE_TIMEOUT,
    )


async def filesystem_remove(
    runtime: DirectRuntime,
    path: str,
    force: bool = False,
    permanent: bool = False,
) -> dict:
    """Remove a file or directory, refusing referenced targets unless forced.

    Defaults to the OS trash (what the editor's own Delete does) so a mistaken
    removal is recoverable; ``permanent=True`` deletes outright.
    """
    await require_writable_async(runtime)
    return await runtime.send_command(
        "remove_file",
        {"path": path, "force": force, "permanent": permanent},
        timeout=_REORGANIZE_TIMEOUT,
    )


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

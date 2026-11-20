"""Shared handlers for script tools."""

from __future__ import annotations

from godot_ai.handlers._readiness import require_writable_async
from godot_ai.runtime.direct import DirectRuntime


async def script_create(runtime: DirectRuntime, path: str, content: str = "") -> dict:
    await require_writable_async(runtime)
    return await runtime.send_command(
        "create_script",
        {"path": path, "content": content},
    )


async def script_patch(
    runtime: DirectRuntime,
    path: str,
    old_text: str,
    new_text: str,
    replace_all: bool = False,
) -> dict:
    await require_writable_async(runtime)
    return await runtime.send_command(
        "patch_script",
        {
            "path": path,
            "old_text": old_text,
            "new_text": new_text,
            "replace_all": replace_all,
        },
    )


async def script_read(runtime: DirectRuntime, path: str) -> dict:
    return await runtime.send_command("read_script", {"path": path})


async def script_attach(runtime: DirectRuntime, path: str, script_path: str) -> dict:
    await require_writable_async(runtime)
    return await runtime.send_command(
        "attach_script",
        {"path": path, "script_path": script_path},
    )


async def script_detach(runtime: DirectRuntime, path: str) -> dict:
    await require_writable_async(runtime)
    return await runtime.send_command("detach_script", {"path": path})


async def script_find_symbols(runtime: DirectRuntime, path: str) -> dict:
    return await runtime.send_command("find_symbols", {"path": path})


## Server-side wait for ``build_csharp``: the plugin's own build timeout plus
## headroom for its kill-and-report path and the dispatcher's deferred grace,
## so the build's ``timed_out`` result arrives before the transport gives up.
SCRIPT_BUILD_TIMEOUT_GRACE_SECONDS = 15.0
SCRIPT_BUILD_DEFAULT_TIMEOUT_SECONDS = 180


async def script_build(
    runtime: DirectRuntime,
    timeout_sec: int = SCRIPT_BUILD_DEFAULT_TIMEOUT_SECONDS,
    include_warnings: bool = True,
    max_diagnostics: int = 200,
) -> dict:
    await require_writable_async(runtime)
    return await runtime.send_command(
        "build_csharp",
        {
            "timeout_sec": timeout_sec,
            "include_warnings": include_warnings,
            "max_diagnostics": max_diagnostics,
        },
        timeout=float(timeout_sec) + SCRIPT_BUILD_TIMEOUT_GRACE_SECONDS,
    )

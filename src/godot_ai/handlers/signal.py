"""Shared handlers for signal tools."""

from __future__ import annotations

from godot_ai.handlers._readiness import require_writable
from godot_ai.runtime.interface import Runtime


async def signal_list(runtime: Runtime, path: str) -> dict:
    return await runtime.send_command("list_signals", {"path": path})


async def signal_connect(
    runtime: Runtime,
    path: str,
    signal: str,
    target: str,
    method: str,
) -> dict:
    require_writable(runtime)
    return await runtime.send_command(
        "connect_signal",
        {"path": path, "signal": signal, "target": target, "method": method},
    )


async def signal_disconnect(
    runtime: Runtime,
    path: str,
    signal: str,
    target: str,
    method: str,
) -> dict:
    require_writable(runtime)
    return await runtime.send_command(
        "disconnect_signal",
        {"path": path, "signal": signal, "target": target, "method": method},
    )

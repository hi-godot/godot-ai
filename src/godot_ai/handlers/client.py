"""Shared handlers for client configuration tools."""

from __future__ import annotations

from godot_ai.runtime.direct import DirectRuntime

CLIENT_STATUS_TIMEOUT_SECONDS = 30.0


async def client_configure(runtime: DirectRuntime, client: str) -> dict:
    return await runtime.send_command("configure_client", {"client": client})


async def client_remove(runtime: DirectRuntime, client: str) -> dict:
    return await runtime.send_command("remove_client", {"client": client})


async def client_status(runtime: DirectRuntime) -> dict:
    # The editor aggregates every client and permits an individual CLI status
    # probe up to six seconds. Match the dock's 30-second aggregate worker
    # budget instead of applying DirectRuntime's five-second single-command
    # default, which can expire before one legitimate probe finishes.
    return await runtime.send_command(
        "check_client_status", timeout=CLIENT_STATUS_TIMEOUT_SECONDS
    )

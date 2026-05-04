"""Shared handlers for client configuration tools."""

from __future__ import annotations

from godot_ai.runtime.direct import DirectRuntime


async def client_configure(runtime: DirectRuntime, client: str) -> dict:
    return await runtime.send_command("configure_client", {"client": client})


async def client_remove(runtime: DirectRuntime, client: str) -> dict:
    return await runtime.send_command("remove_client", {"client": client})


async def client_status(runtime: DirectRuntime) -> dict:
    return await runtime.send_command("check_client_status")

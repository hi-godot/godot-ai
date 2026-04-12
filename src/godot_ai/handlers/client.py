"""Shared handlers for client configuration tools."""

from __future__ import annotations

from godot_ai.runtime.interface import Runtime


async def client_configure(runtime: Runtime, client: str) -> dict:
    return await runtime.send_command("configure_client", {"client": client})


async def client_status(runtime: Runtime) -> dict:
    return await runtime.send_command("check_client_status")


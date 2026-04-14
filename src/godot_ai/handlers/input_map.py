"""Shared handlers for input map tools."""

from __future__ import annotations

from typing import Any

from godot_ai.handlers._readiness import require_writable
from godot_ai.runtime.interface import Runtime


async def input_map_list(runtime: Runtime, include_builtin: bool = False) -> dict:
    params: dict[str, Any] = {}
    if include_builtin:
        params["include_builtin"] = True
    return await runtime.send_command("list_actions", params)


async def input_map_add_action(
    runtime: Runtime,
    action: str,
    deadzone: float = 0.5,
) -> dict:
    require_writable(runtime)
    return await runtime.send_command(
        "add_action",
        {"action": action, "deadzone": deadzone},
    )


async def input_map_remove_action(runtime: Runtime, action: str) -> dict:
    require_writable(runtime)
    return await runtime.send_command("remove_action", {"action": action})


async def input_map_bind_event(
    runtime: Runtime,
    action: str,
    event_type: str,
    **kwargs: Any,
) -> dict:
    require_writable(runtime)
    params: dict[str, Any] = {"action": action, "event_type": event_type}
    params.update(kwargs)
    return await runtime.send_command("bind_event", params)

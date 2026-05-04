"""Shared handlers for the batch_execute tool."""

from __future__ import annotations

from godot_ai.handlers._readiness import require_writable
from godot_ai.runtime.direct import DirectRuntime


async def batch_execute(
    runtime: DirectRuntime,
    commands: list[dict],
    undo: bool = True,
) -> dict:
    require_writable(runtime)
    if not isinstance(commands, list) or not commands:
        return {
            "succeeded": 0,
            "stopped_at": None,
            "results": [],
            "undo": undo,
            "rolled_back": False,
            "undoable": False,
            "error": {
                "code": "INVALID_PARAMS",
                "message": "commands must be a non-empty list",
            },
        }
    return await runtime.send_command(
        "batch_execute",
        {"commands": commands, "undo": undo},
        timeout=30.0,
    )

"""Shared handlers for Godot API introspection."""

from __future__ import annotations

from typing import Any

from godot_ai.runtime.direct import DirectRuntime


async def api_get_class(
    runtime: DirectRuntime,
    class_name: str,
    sections: list[str] | str | None = None,
    include_inherited: bool = False,
    include_inheritors: bool = False,
    offset: int = 0,
    limit: int = 100,
) -> dict:
    params: dict[str, Any] = {
        "class_name": class_name,
        "include_inherited": include_inherited,
        "include_inheritors": include_inheritors,
        "offset": offset,
        "limit": limit,
    }
    if sections is not None:
        params["sections"] = sections
    return await runtime.send_command("get_class_info", params)

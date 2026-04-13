"""Shared handlers for editor tools and resources."""

from __future__ import annotations

import logging

from godot_ai.runtime.interface import Runtime
from godot_ai.sessions.registry import Session
from godot_ai.tools._pagination import paginate

logger = logging.getLogger(__name__)


async def editor_state(runtime: Runtime) -> dict:
    return await runtime.send_command("get_editor_state")


async def editor_selection_get(runtime: Runtime) -> dict:
    return await runtime.send_command("get_selection")


async def logs_read(runtime: Runtime, count: int = 50, offset: int = 0) -> dict:
    result = await runtime.send_command("get_logs", {"count": 500})
    lines = result.get("lines", [])
    return paginate(lines, offset, count, key="lines")


def _find_replacement_session(
    sessions: list[Session],
    known_ids: set[str],
    project_path: str,
) -> Session | None:
    for session in sessions:
        if session.session_id in known_ids:
            continue
        if session.project_path != project_path:
            continue
        return session
    return None


async def reload_plugin(runtime: Runtime) -> dict:
    active = runtime.get_active_session()
    if active is None:
        raise ConnectionError("No active Godot session")
    old_id = active.session_id
    known_ids = {session.session_id for session in runtime.list_sessions()}

    try:
        await runtime.send_command("reload_plugin", timeout=2.0)
    except (ConnectionError, TimeoutError) as exc:
        logger.debug("Expected disconnect during reload: %s", exc)

    # Check if a replacement session already appeared during the reload command
    # (handles the race where the new session registers before we start waiting)
    new_session = _find_replacement_session(
        list(runtime.list_sessions()),
        known_ids=known_ids,
        project_path=active.project_path,
    )
    if new_session is None:
        new_session = await runtime.wait_for_session(exclude_id=old_id, timeout=15.0)

    runtime.set_active_session(new_session.session_id)
    return {
        "status": "reloaded",
        "old_session_id": old_id,
        "new_session_id": new_session.session_id,
    }


async def selection_resource_data(runtime: Runtime) -> dict:
    return await editor_selection_get(runtime)


async def logs_resource_data(runtime: Runtime) -> dict:
    return await runtime.send_command("get_logs", {"count": 100})

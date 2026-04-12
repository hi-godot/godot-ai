"""Shared handlers for session tools and resources."""

from __future__ import annotations

from godot_ai.runtime.interface import Runtime


def session_list(runtime: Runtime) -> dict:
    sessions = runtime.list_sessions()
    active_id = runtime.active_session_id
    return {
        "sessions": [{**s.to_dict(), "is_active": s.session_id == active_id} for s in sessions],
        "count": len(sessions),
    }


def session_activate(runtime: Runtime, session_id: str) -> dict:
    try:
        runtime.set_active_session(session_id)
        return {"status": "ok", "active_session_id": session_id}
    except KeyError:
        return {"status": "error", "message": f"Session {session_id} not found"}


def session_resource_data(runtime: Runtime) -> dict:
    return session_list(runtime)


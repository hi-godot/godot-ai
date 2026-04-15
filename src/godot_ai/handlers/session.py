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
    """Activate a session by exact id or a substring hint.

    The `session_id` argument accepts three forms, in priority order:
    1. An exact session_id — always wins if it matches.
    2. A substring of the session's short name (project basename),
       project_path, or session_id. Must match exactly one session.

    This lets callers activate by a human-friendly fragment like a project
    folder name instead of copying opaque UUIDs from session_list.
    """
    sessions = list(runtime.list_sessions())

    ## Priority 1: exact session_id match.
    for session in sessions:
        if session.session_id == session_id:
            runtime.set_active_session(session.session_id)
            return {
                "status": "ok",
                "active_session_id": session.session_id,
                "matched": "exact_id",
            }

    ## Priority 2: substring match on name / project_path / session_id.
    if session_id:
        lowered = session_id.lower()
        matches = [
            session
            for session in sessions
            if lowered in session.name.lower()
            or lowered in session.project_path.lower()
            or lowered in session.session_id.lower()
        ]
        if len(matches) == 1:
            runtime.set_active_session(matches[0].session_id)
            return {
                "status": "ok",
                "active_session_id": matches[0].session_id,
                "matched": "hint",
                "matched_name": matches[0].name,
            }
        if len(matches) > 1:
            return {
                "status": "error",
                "message": (
                    f"Hint '{session_id}' matched {len(matches)} sessions; "
                    "provide a more specific substring or an exact session_id"
                ),
                "candidates": [
                    {
                        "session_id": match.session_id,
                        "name": match.name,
                        "project_path": match.project_path,
                    }
                    for match in matches
                ],
            }

    return {
        "status": "error",
        "message": f"No session matches '{session_id}'",
        "available": [
            {
                "session_id": session.session_id,
                "name": session.name,
                "project_path": session.project_path,
            }
            for session in sessions
        ],
    }


def session_resource_data(runtime: Runtime) -> dict:
    return session_list(runtime)


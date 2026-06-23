"""Actionable diagnostics for missing Godot editor sessions."""

from __future__ import annotations

from typing import Any

NO_ACTIVE_SESSION_MESSAGE = (
    "No active Godot session — this MCP server has no connected Godot editor. "
    "Open the project in the Godot editor with the Godot AI plugin enabled, "
    "and verify the editor and this MCP server share the same loopback/network "
    "namespace. In Docker or remote-agent setups, do not point the agent at a "
    "different server than the one the editor connects to."
)

NO_ACTIVE_SESSION_HINT = (
    "Run session_manage(op='list') to confirm whether this server has any editor "
    "sessions. If it returns count=0, start or reconnect the Godot editor to this "
    "same server. For Docker, run the MCP server on the host or put the editor and "
    "server in the same network namespace; container localhost is not host localhost."
)


def no_active_session_data(**extra: Any) -> dict[str, Any]:
    """Structured payload shared by tools/resources that need an editor session."""

    data: dict[str, Any] = {
        "connected": False,
        "retryable": True,
        "reason": "no_active_session",
        "hint": NO_ACTIVE_SESSION_HINT,
        "diagnostics": {
            "check_sessions": "session_manage(op='list')",
            "expected_bridge": "Godot editor plugin WebSocket -> this MCP server",
            "docker_note": (
                "127.0.0.1/localhost is scoped to each container/host namespace; "
                "the editor and MCP server must be reachable in the same namespace."
            ),
        },
    }
    data.update(extra)
    return data


def session_not_found_message(session_id: str) -> str:
    """Actionable message for calls pinned to a missing editor session."""

    return (
        f"Godot session '{session_id}' not found — it may have disconnected or "
        "belong to a different MCP server/network namespace. Run "
        "session_manage(op='list') for live sessions."
    )


def session_not_found_data(session_id: str, **extra: Any) -> dict[str, Any]:
    """Structured payload for calls pinned to a missing editor session."""

    data: dict[str, Any] = {
        "connected": False,
        "retryable": True,
        "reason": "session_not_found",
        "session_id": session_id,
        "hint": (
            f"Session '{session_id}' is not connected to this MCP server. Run "
            "session_manage(op='list') to see live sessions, then retry with "
            "one of those session_id values or omit session_id to use the "
            "active session. In Docker or remote-agent setups, make sure the "
            "agent is talking to the same MCP server the Godot editor connected to."
        ),
        "diagnostics": {
            "check_sessions": "session_manage(op='list')",
            "requested_session_id": session_id,
            "expected_bridge": "Godot editor plugin WebSocket -> this MCP server",
            "docker_note": (
                "127.0.0.1/localhost is scoped to each container/host namespace; "
                "a session_id from one MCP server will not exist on another."
            ),
        },
    }
    data.update(extra)
    return data

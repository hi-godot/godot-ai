"""Readiness gating for write operations."""

from __future__ import annotations

from godot_ai.godot_client.client import GodotCommandError
from godot_ai.protocol.errors import ErrorCode
from godot_ai.runtime.interface import Runtime

_READINESS_MESSAGES = {
    "importing": "Editor is importing resources — try again shortly",
    "playing": "Editor is in play mode — stop the game first",
}


def require_writable(runtime: Runtime) -> None:
    """Check that the active session is in a writable state.

    Raises GodotCommandError with EDITOR_NOT_READY if the editor is
    importing or playing.  The ``ready`` and ``no_scene`` states are
    allowed through — individual handlers already reject when no scene
    is open.  If no session exists, this is a no-op; the downstream
    ``send_command`` will raise on its own.
    """
    session = runtime.get_active_session()
    if session is None:
        return

    readiness = session.readiness
    message = _READINESS_MESSAGES.get(readiness)
    if message is not None:
        raise GodotCommandError(code=ErrorCode.EDITOR_NOT_READY, message=message)

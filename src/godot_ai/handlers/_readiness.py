"""Readiness gating for write operations."""

from __future__ import annotations

from godot_ai.godot_client.client import GodotCommandError
from godot_ai.protocol.errors import ErrorCode
from godot_ai.runtime.interface import Runtime

# (message, retryable). Retryable means the condition clears on its own
# (Godot finishes reimporting); non-retryable requires the caller to change
# state (stop the game).
_READINESS_INFO: dict[str, tuple[str, bool]] = {
    "importing": ("Editor is importing resources — try again shortly", True),
    "playing": ("Editor is in play mode — stop the game first", False),
}


def require_writable(runtime: Runtime) -> None:
    """Check that the active session is in a writable state.

    Raises GodotCommandError with EDITOR_NOT_READY if the editor is
    importing or playing.  The ``ready`` and ``no_scene`` states are
    allowed through — individual handlers already reject when no scene
    is open.  If no session exists, this is a no-op; the downstream
    ``send_command`` will raise on its own.

    The raised error carries ``data={"retryable": bool, "state": str}`` so
    callers can distinguish a transient ``importing`` window (retry with
    backoff) from a terminal ``playing`` state (stop the game first).
    """
    session = runtime.get_active_session()
    if session is None:
        return

    readiness = session.readiness
    info = _READINESS_INFO.get(readiness)
    if info is not None:
        message, retryable = info
        raise GodotCommandError(
            code=ErrorCode.EDITOR_NOT_READY,
            message=message,
            data={"retryable": retryable, "state": readiness},
        )

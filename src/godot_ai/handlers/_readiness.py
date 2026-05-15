"""Readiness gating for write operations."""

from __future__ import annotations

from typing import TYPE_CHECKING

from godot_ai.protocol.errors import ErrorCode
from godot_ai.sessions.registry import Session

if TYPE_CHECKING:
    from godot_ai.runtime.direct import DirectRuntime

# (message, retryable). Retryable means the condition clears on its own
# (Godot finishes reimporting); non-retryable requires the caller to change
# state (stop the game).
_READINESS_INFO: dict[str, tuple[str, bool]] = {
    "importing": ("Editor is importing resources — try again shortly", True),
    "playing": ("Editor is in play mode — call project_stop to stop the game, then retry", False),
}

# Every readiness value the plugin can emit. Derived from the blocking-state
# table plus "ready" / "no_scene" so the canonical list can't drift. Used by
# handlers that copy a live readiness snapshot (editor_state's response,
# project_stop's readiness_after) onto session.readiness — guards against
# the plugin inventing an unknown state and the cache trusting it.
KNOWN_READINESS: frozenset[str] = frozenset(_READINESS_INFO) | {"ready", "no_scene"}


def sync_readiness_for_session(session: Session | None, value: object) -> bool:
    """Copy an authoritative readiness snapshot onto a specific session.

    Returns True if the cache was updated, False if the session is None or
    the snapshot wasn't a recognized readiness value (forward-compat: a
    newer plugin sending an unknown state is ignored, not propagated).

    Used by the WebSocket transport to heal `Session.readiness` from the
    `readiness` envelope field stamped on every command response by the
    plugin's dispatcher — without that, a single dropped `readiness_changed`
    event would leave the server convinced the editor is still `playing`
    long after the game has stopped.
    """
    if session is None or value not in KNOWN_READINESS:
        return False
    session.readiness = value  # type: ignore[assignment]
    return True


def sync_readiness_from_snapshot(runtime: "DirectRuntime", value: object) -> bool:
    """Copy an authoritative readiness snapshot onto the active session.

    Used by handlers that receive a live readiness from the plugin
    (`editor_state`'s reply, `project_stop`'s `readiness_after`). Now
    largely redundant with the per-response envelope sync that the
    transport layer applies to every command reply, but kept so the
    `data.readiness` / `data.readiness_after` payload paths still heal
    the cache for callers that bypass the envelope (in-process tests
    that wire a custom client without going through the WebSocket).
    """
    return sync_readiness_for_session(runtime.get_active_session(), value)


def require_writable(runtime: "DirectRuntime") -> None:
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
        ## Lazy import — `godot_client.client` pulls in the WS transport,
        ## which now imports `sync_readiness_for_session` from this module.
        ## Hoisting the import to module top would re-establish the cycle.
        from godot_ai.godot_client.client import GodotCommandError

        message, retryable = info
        raise GodotCommandError(
            code=ErrorCode.EDITOR_NOT_READY,
            message=message,
            data={"retryable": retryable, "state": readiness},
        )

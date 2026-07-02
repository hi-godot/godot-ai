"""Readiness gating for write operations."""

from __future__ import annotations

from typing import TYPE_CHECKING

from godot_ai.protocol.errors import ErrorCode
from godot_ai.sessions.registry import Session

if TYPE_CHECKING:
    from godot_ai.runtime.direct import DirectRuntime

# (message, retryable, hint). Retryable means the condition clears on its own
# (Godot finishes reimporting); non-retryable requires the caller to change
# state (stop the game). The ``hint`` is a one-line, action-oriented sentence
# surfaced to AI callers via the error ``data`` payload — its job is to tell
# an LLM exactly which tool call (or wait) breaks the stall, so it stops
# looping the failing write. See PR for the F-EDITOR-NOT-READY-LOOP fix
# (telemetry showed two users alone producing 89% of EDITOR_NOT_READY
# errors on plugin v2.5.6, all from caller-side retry loops during
# ``playing``).
_READINESS_INFO: dict[str, tuple[str, bool, str]] = {
    "importing": (
        "Editor is importing resources — try again shortly",
        True,
        (
            "Editor is importing assets. Wait briefly and retry — "
            "readiness will update via the response envelope."
        ),
    ),
    "playing": (
        'Editor is in play mode — call project_manage(op="stop") to stop the game, then retry',
        False,
        (
            'Editor is playing the scene. Call project_manage(op="stop") '
            "(or wait for the user to stop the game) before retrying writes."
        ),
    ),
}

# Every readiness value the plugin can emit. Derived from the blocking-state
# table plus "ready" / "no_scene" so the canonical list can't drift. Used by
# handlers that copy a live readiness snapshot (editor_state's response,
# project_stop's readiness_after) onto session.readiness — guards against
# the plugin inventing an unknown state and the cache trusting it.
KNOWN_READINESS: frozenset[str] = frozenset(_READINESS_INFO) | {"ready", "no_scene"}


def sync_readiness_for_session(session: Session | None, value: object) -> bool:
    """Copy an authoritative readiness snapshot onto a specific session.

    Returns True if the cache was updated, False if the session is None,
    the snapshot wasn't a recognized readiness value (forward-compat: a
    newer plugin sending an unknown state is ignored, not propagated),
    or the value already matches the cache (no-op transition).

    Used by the WebSocket transport to heal `Session.readiness` from the
    `readiness` envelope field stamped on every command response by the
    plugin's dispatcher — without that, a single dropped `readiness_changed`
    event would leave the server convinced the editor is still `playing`
    long after the game has stopped.
    """
    if session is None or value not in KNOWN_READINESS:
        return False
    if session.readiness == value:
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


async def require_writable_async(runtime: "DirectRuntime") -> None:
    """Check that the active session is in a writable state, with a live
    readiness probe to defeat a stale cache.

    Fast path (cache says ``ready`` / ``no_scene``): no probe, no network.

    Slow path (cache says ``importing`` / ``playing``): the cache may be
    stale because a `readiness_changed` event was lost in transit (a brief
    WebSocket disconnect), or coalesced inside the plugin's
    ``pause_processing`` window around save/play frames. Before rejecting
    a write, fire one ``get_editor_state`` round trip — production replies
    self-heal the cache via the WebSocket transport's envelope sync; the
    explicit ``sync_readiness_for_session`` call below covers in-process
    tests that wire a custom client and bypass the transport. If the
    editor really is busy, the probe confirms the cache and we raise as
    before. If the plugin is unreachable, the actual write would fail
    anyway — trust the cached value and raise the gating error so the
    caller gets a clean ``EDITOR_NOT_READY`` instead of a connection error.

    Raises GodotCommandError with EDITOR_NOT_READY if the editor is
    importing or playing.  The ``ready`` and ``no_scene`` states are
    allowed through — individual handlers already reject when no scene
    is open.  If no session exists, this is a no-op; the downstream
    ``send_command`` will raise on its own.

    The raised error carries ``data={"editor_state": str, "retryable": bool,
    "hint": str}`` so callers can distinguish a transient ``importing`` window
    (retry with backoff) from a terminal ``playing`` state (stop the game
    first) AND get an explicit one-line recovery instruction. The hint is
    what stops the EDITOR_NOT_READY-loop pattern: without it, AI callers
    just retry the failing write until the user notices.
    """
    session = runtime.get_active_session()
    if session is None:
        return
    if _READINESS_INFO.get(session.readiness) is None:
        return  # cache says writable — fast path, no probe

    try:
        result = await runtime.send_command(
            "get_editor_state",
            timeout=2.0,
            surface_error_hints=False,
        )
        sync_readiness_for_session(session, result.get("readiness"))
    except Exception:
        ## Probe failed (timeout, disconnect, plugin error). Fall through
        ## to enforcement against the cached value — at worst the caller
        ## sees a stale rejection, but we don't escalate the failure mode
        ## from "blocked" to "connection error".
        pass

    _enforce_blocking_state(session)


def _enforce_blocking_state(session: "Session | None") -> None:
    if session is None:
        return
    info = _READINESS_INFO.get(session.readiness)
    if info is None:
        return
    ## Lazy import — `godot_client.client` pulls in the WS transport,
    ## which now imports `sync_readiness_for_session` from this module.
    ## Hoisting the import to module top would re-establish the cycle.
    from godot_ai.godot_client.client import GodotCommandError

    message, retryable, hint = info
    raise GodotCommandError(
        code=ErrorCode.EDITOR_NOT_READY,
        message=message,
        data={
            "editor_state": session.readiness,
            "retryable": retryable,
            "hint": hint,
        },
    )

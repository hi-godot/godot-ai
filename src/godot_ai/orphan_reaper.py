"""Self-terminate a plugin-spawned server once its owning editor is gone.

The Godot plugin spawns the MCP server as a *detached* child (so the server
can survive a plugin reload and be re-adopted). The clean teardown path is the
editor's ``_exit_tree`` calling ``stop_server``. When the editor instead
crashes or is hard-killed, ``_exit_tree`` never runs and the detached server is
orphaned — squatting on the HTTP/WS ports until a human or the next session's
port reconciliation kills it. (That's how a fresh session inherits a stale
``v2.5.9`` server on port 8000.)

When the plugin auto-spawns the server it passes ``--owner-pid <editor_pid>``.
This watchdog polls that pid: once the owner editor process is gone AND no
editor session is currently connected, it shuts the server down. The
"no session connected" guard preserves adoption — if a *different* editor
adopted this server it holds a live WebSocket session, so the watchdog leaves
it running; that adopter's own clean exit (or its later crash, by which point
sessions are again zero) reaps it.

Servers started without ``--owner-pid`` (CI's ci-start-server, manual
``--reload`` dev runs, ``uvx`` one-shots) never enable the watchdog and behave
exactly as before.
"""

from __future__ import annotations

import asyncio
import logging
import os
import signal
import sys
from collections.abc import Callable

logger = logging.getLogger(__name__)

DEFAULT_POLL_SECONDS = 5.0
POLL_SECONDS_ENV = "GODOT_AI_REAPER_POLL_SECONDS"


def poll_seconds_from_env() -> float:
    """Reaper poll interval, overridable via ``GODOT_AI_REAPER_POLL_SECONDS``.

    Defaults to :data:`DEFAULT_POLL_SECONDS`. The override exists so the
    subprocess integration test can drive a fast (<1s) reap instead of waiting
    the production 5s; a malformed value falls back to the default.
    """
    raw = os.environ.get(POLL_SECONDS_ENV, "").strip()
    if not raw:
        return DEFAULT_POLL_SECONDS
    try:
        value = float(raw)
    except ValueError:
        return DEFAULT_POLL_SECONDS
    return value if value > 0 else DEFAULT_POLL_SECONDS


def should_arm_reaper(owner_pid: int | None) -> bool:
    """Whether the orphan reaper should run for ``owner_pid``.

    Disabled on Windows: the liveness/self-shutdown primitives here are only
    live-validated on POSIX, and ``os.kill`` semantics differ sharply on
    Windows (no signal-0 probe — any non-CTRL signal calls ``TerminateProcess``).
    Rather than ship process-control code we can't exercise, Windows keeps its
    prior behavior (the editor's clean ``_exit_tree`` still stops the server;
    an orphan from a hard crash lingers until the next session's port
    reconciliation, exactly as before this change). Tracked as a follow-up.
    """
    return bool(owner_pid and owner_pid > 0) and not sys.platform.startswith("win")


def pid_alive(pid: int) -> bool:
    """True if a process with ``pid`` currently exists. POSIX-only; never kills it.

    Uses signal 0 — the kernel's permission/existence check with no signal
    delivered. Windows is intentionally unsupported: ``os.kill(pid, 0)`` there
    would call ``TerminateProcess`` and kill the very process we're probing, and
    the reaper is disabled on Windows anyway (see ``should_arm_reaper``), so this
    is never reached. It raises rather than silently mis-probing, so a future
    Windows enablement must add a real, access-denied-conservative liveness check
    (e.g. OpenProcess + GetExitCodeProcess via WinDLL with proper signatures)
    rather than inheriting an untested one.

    Known limitation: this is a bare-pid check with no identity proof (no start
    time, no cmdline brand — unlike the plugin's ``_pid_cmdline_is_godot_ai``
    kill-target gating). If the owner editor's pid is recycled to an unrelated
    process, this reports it alive and the reaper never fires — a (rare) missed
    reap, not a wrong kill. The server still falls back to the pre-existing
    behavior (clean editor shutdown stops it; the next session's port
    reconciliation reclaims a true orphan), so a missed reap degrades to the
    status quo rather than leaking unboundedly.
    """
    if pid <= 0:
        return False
    if sys.platform.startswith("win"):
        raise NotImplementedError(
            "pid_alive is POSIX-only; the orphan reaper is disabled on Windows "
            "(see should_arm_reaper). Implement a Windows liveness probe before "
            "enabling it there."
        )
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        # Exists but owned by another user — still "alive" for our purposes.
        return True
    except OSError:
        # Unexpected errno: be conservative and treat as alive so we never
        # reap a server whose owner might still be around.
        return True
    return True


def _request_self_shutdown() -> None:
    """Ask our own process to shut down gracefully.

    SIGTERM is what uvicorn / the FastMCP HTTP runner already handle as a
    graceful shutdown (drain + lifespan teardown), so this reuses the exact
    path a ``kill <pid>`` from the plugin would trigger — no abrupt exit.
    """
    os.kill(os.getpid(), signal.SIGTERM)


async def watch_owner(
    owner_pid: int,
    session_count: Callable[[], int],
    *,
    poll_seconds: float = DEFAULT_POLL_SECONDS,
    grace_seconds: float | None = None,
    is_alive: Callable[[int], bool] = pid_alive,
    shutdown: Callable[[], None] = _request_self_shutdown,
) -> None:
    """Poll until the owner editor is gone with no sessions, then shut down.

    Runs until it triggers a shutdown or is cancelled on lifespan teardown.
    The injectable ``is_alive`` / ``shutdown`` / ``session_count`` seams keep
    it unit-testable without spawning real processes.

    A reap requires the "owner dead AND zero sessions" condition to hold on two
    samples ``grace_seconds`` apart (default: one poll interval). This guards
    the adoption hand-off race: when an adopter editor's WebSocket briefly drops
    — a plugin reload, a GC pause, a transient blip — ``session_count()`` dips to
    zero for that instant, and a single-sample reap would SIGTERM the server out
    from under the still-live adopter. The re-check lets the reconnect re-register
    before we act. The cost is bounded extra reap latency for a genuine orphan
    (poll + grace), which is fine for a cleanup watchdog.
    """
    if grace_seconds is None:
        grace_seconds = poll_seconds
    while True:
        await asyncio.sleep(poll_seconds)
        if is_alive(owner_pid) or session_count() > 0:
            continue
        # Looks orphaned. Re-confirm after a grace window so a transient
        # zero-session blip (adopter reconnecting) can't trigger a wrong reap.
        await asyncio.sleep(grace_seconds)
        if is_alive(owner_pid) or session_count() > 0:
            continue
        logger.info(
            "Owner editor pid %d is gone and no sessions are connected; "
            "shutting down orphaned server.",
            owner_pid,
        )
        shutdown()
        return

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
    """True if a process with ``pid`` currently exists. Never kills ``pid``.

    POSIX uses signal 0 — the kernel's permission/existence check with no
    signal delivered. Windows can't use ``os.kill(pid, 0)`` (that would call
    ``TerminateProcess`` and kill the very process we're probing), so it opens a
    SYNCHRONIZE handle and asks ``WaitForSingleObject`` whether the process is
    still running. A surviving-but-unrelated pid (after reuse) is an accepted,
    vanishingly-rare false-positive — it only delays a reap, never causes a
    wrong one.
    """
    if pid <= 0:
        return False
    if sys.platform.startswith("win"):
        return _pid_alive_windows(pid)
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


def _pid_alive_windows(pid: int) -> bool:
    """Non-destructive Windows liveness probe via OpenProcess/WaitForSingleObject.

    Defensive only — the reaper is not armed on Windows (see
    ``should_arm_reaper``), so this never runs in production today. Kept correct
    so a future Windows enablement (or a manual ``--owner-pid`` run) is safe.
    """
    import ctypes

    SYNCHRONIZE = 0x00100000
    WAIT_TIMEOUT = 0x00000102  # still running
    kernel32 = ctypes.windll.kernel32  # type: ignore[attr-defined]
    handle = kernel32.OpenProcess(SYNCHRONIZE, False, pid)
    if not handle:
        return False  # no such process (or no access) — treat as gone
    try:
        return kernel32.WaitForSingleObject(handle, 0) == WAIT_TIMEOUT
    finally:
        kernel32.CloseHandle(handle)


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
    is_alive: Callable[[int], bool] = pid_alive,
    shutdown: Callable[[], None] = _request_self_shutdown,
) -> None:
    """Poll until the owner editor is gone with no sessions, then shut down.

    Runs until it triggers a shutdown or is cancelled on lifespan teardown.
    The injectable ``is_alive`` / ``shutdown`` / ``session_count`` seams keep
    it unit-testable without spawning real processes.
    """
    while True:
        await asyncio.sleep(poll_seconds)
        if is_alive(owner_pid):
            continue
        if session_count() > 0:
            # Owner died but another editor adopted us — stay up for it.
            continue
        logger.info(
            "Owner editor pid %d is gone and no sessions are connected; "
            "shutting down orphaned server.",
            owner_pid,
        )
        shutdown()
        return

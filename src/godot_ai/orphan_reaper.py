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
from collections.abc import Callable

logger = logging.getLogger(__name__)

DEFAULT_POLL_SECONDS = 5.0


def pid_alive(pid: int) -> bool:
    """True if a process with ``pid`` currently exists.

    Uses signal 0, which performs the kernel's permission/existence check
    without delivering a signal. A surviving-but-unrelated pid (after reuse)
    is an accepted, vanishingly-rare false-positive — it only delays a reap,
    never causes a wrong one.
    """
    if pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        # Exists but owned by another user — still "alive" for our purposes.
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

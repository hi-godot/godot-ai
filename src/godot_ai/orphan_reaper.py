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

Alongside the owner-PID watchdog, ``watch_idle`` implements the session-idle
self-terminate backstop (#498): a plugin-spawned server with zero connected
sessions for a full grace window exits on its own. Being pure session-count +
monotonic-clock, it also runs on Windows, where the owner-PID reaper is
disabled — the first orphan coverage there (#497).
"""

from __future__ import annotations

import asyncio
import logging
import os
import signal
import sys
import time
from collections.abc import Callable

from godot_ai.protocol.attach import ATTACH_SPAWNED_ENV

logger = logging.getLogger(__name__)

DEFAULT_POLL_SECONDS = 5.0
POLL_SECONDS_ENV = "GODOT_AI_REAPER_POLL_SECONDS"

## ---- Idle self-terminate backstop (#498; Windows coverage for #497) ----
##
## The owner-PID watchdog above is POSIX-only and depends on the editor PID
## surviving env plumbing. The idle backstop is a second, independent line of
## defense: a plugin-spawned server that has had ZERO connected editor sessions
## for a full grace window exits on its own. It needs no process probing at
## all — just the session registry count and a monotonic clock — so it works
## identically on Windows, where the owner-PID reaper is disabled.

## Marker set by the plugin (server_lifecycle.gd) around OS.create_process,
## exactly like GODOT_AI_OWNER_PID. Only plugin-spawned servers may idle-exit;
## manually launched dev servers (`python -m godot_ai`, serve-this-worktree)
## never see this marker and are never idle-killed.
PLUGIN_SPAWNED_ENV = "GODOT_AI_PLUGIN_SPAWNED"

## Opt-out escape hatch: a user who wants a plugin-spawned server to outlive
## all editors (e.g. debugging the server itself) sets this truthy.
NO_IDLE_EXIT_ENV = "GODOT_AI_NO_IDLE_EXIT"

## Grace before the FIRST-ever session connects (server boot → plugin
## handshake), and grace after the LAST session disconnects. The observed
## plugin-reload reconnect gap is ~6s; 120s is a wide safety margin over that
## while still reclaiming a truly orphaned server within minutes.
DEFAULT_IDLE_GRACE_SECONDS = 120.0
BOOT_GRACE_ENV = "GODOT_AI_IDLE_BOOT_GRACE_SECONDS"
IDLE_GRACE_ENV = "GODOT_AI_IDLE_GRACE_SECONDS"

## Set by asgi.run_with_reload for the uvicorn reload supervisor + worker.
## Duplicated string (not imported from godot_ai.asgi) to keep this module
## free of the uvicorn/fastmcp import chain.
_DEV_TRANSPORT_ENV = "GODOT_AI_DEV_TRANSPORT"


def _env_truthy(name: str) -> bool:
    ## Same truthiness contract as telemetry's opt-out vars ("1"/"true"/...).
    return os.environ.get(name, "").strip().lower() in ("1", "true", "yes", "on")


def _grace_from_env(name: str) -> float:
    """Grace window in seconds from ``name``, defaulting to 120s.

    Malformed or non-positive values fall back to the default — a bad env var
    must never turn the backstop into an instant kill.
    """
    raw = os.environ.get(name, "").strip()
    if not raw:
        return DEFAULT_IDLE_GRACE_SECONDS
    try:
        value = float(raw)
    except ValueError:
        return DEFAULT_IDLE_GRACE_SECONDS
    return value if value > 0 else DEFAULT_IDLE_GRACE_SECONDS


def boot_grace_from_env() -> float:
    return _grace_from_env(BOOT_GRACE_ENV)


def idle_grace_from_env() -> float:
    return _grace_from_env(IDLE_GRACE_ENV)


def should_arm_idle_exit(owner_pid: int | None) -> bool:
    """Whether the idle self-terminate backstop (#498) should run.

    Arms only for plugin-spawned servers: either the explicit
    ``GODOT_AI_PLUGIN_SPAWNED`` marker is present (set by server_lifecycle.gd on
    every platform, including Windows where owner-PID is skipped — that's the
    #497 coverage), or an owner pid was plumbed through (older plugin builds
    that predate the marker). Never arms for:

    - manual dev servers / CI (neither marker nor owner pid in the env);
    - ``--reload`` dev runs (detected via the reload runner's
      ``GODOT_AI_DEV_TRANSPORT`` env, inherited by uvicorn's reload worker) —
      an idle reloading server is a dev convenience, not an orphan;
    - explicit opt-out via ``GODOT_AI_NO_IDLE_EXIT``.

    Unlike ``should_arm_reaper`` there is no Windows gate: this path does no
    process probing, only session counts + monotonic time.
    """
    if _env_truthy(NO_IDLE_EXIT_ENV):
        return False
    if os.environ.get(_DEV_TRANSPORT_ENV, "").strip():
        return False
    return _env_truthy(PLUGIN_SPAWNED_ENV) or bool(owner_pid and owner_pid > 0)


def should_arm_attach_idle_exit() -> bool:
    """Whether the lease-aware idle policy should run for an attach backend."""

    if _env_truthy(NO_IDLE_EXIT_ENV):
        return False
    if os.environ.get(_DEV_TRANSPORT_ENV, "").strip():
        return False
    return _env_truthy(ATTACH_SPAWNED_ENV)


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

    On Windows (reachable via the idle backstop, #498/#497 — the owner-PID
    reaper stays POSIX-only) ``os.kill(pid, SIGTERM)`` would be
    ``TerminateProcess`` — an abrupt kill that skips lifespan teardown. Use
    ``signal.raise_signal`` there instead: it invokes uvicorn's installed
    Python-level SIGTERM handler in-process, giving the same graceful
    drain; with no handler installed the default disposition still exits.
    """
    if sys.platform.startswith("win"):
        signal.raise_signal(signal.SIGTERM)
    else:
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


async def watch_idle(
    session_count: Callable[[], int],
    *,
    lease_count: Callable[[], int] | None = None,
    poll_seconds: float = DEFAULT_POLL_SECONDS,
    boot_grace_seconds: float = DEFAULT_IDLE_GRACE_SECONDS,
    idle_grace_seconds: float = DEFAULT_IDLE_GRACE_SECONDS,
    clock: Callable[[], float] = time.monotonic,
    shutdown: Callable[[], None] = _request_self_shutdown,
) -> None:
    """Exit once ZERO sessions have been connected for a full grace window.

    The idle self-terminate backstop from #498 (and the Windows orphan story
    for #497). Runs alongside — never instead of — the owner-PID watchdog:
    owner-PID reaps fast when the editor demonstrably died; this backstop
    reaps eventually with no process probing at all, so it also covers
    platforms/paths where owner-PID can't run.

    Two windows, both measured on the injectable monotonic ``clock``:

    - boot grace (``boot_grace_seconds``): from task start until the
      first-ever session connects. Covers a spawn whose editor dies before
      the plugin's WebSocket handshake lands.
    - idle grace (``idle_grace_seconds``): restarts every poll that observes
      a live session, so it effectively measures time since the last
      disconnect. Sized well above the ~6s plugin-reload reconnect gap, so a
      reload's brief zero-session dip can never trigger an exit.

    Runs until it triggers a shutdown or is cancelled on lifespan teardown.
    """
    idle_since = clock()
    ever_connected = False
    while True:
        await asyncio.sleep(poll_seconds)
        now = clock()
        active = session_count() > 0 or (lease_count is not None and lease_count() > 0)
        if active:
            ever_connected = True
            ## Restart the idle window at the last poll that saw a session or
            ## bridge lease —
            ## the true disconnect happened somewhere in the following poll
            ## interval, so this under-counts idle time by at most one poll.
            idle_since = now
            continue
        grace = idle_grace_seconds if ever_connected else boot_grace_seconds
        if now - idle_since < grace:
            continue
        logger.info(
            "No editor session or bridge lease for %.0fs (%s grace %.0fs); "
            "idle backstop shutting down managed server.",
            now - idle_since,
            "idle" if ever_connected else "boot",
            grace,
        )
        shutdown()
        return

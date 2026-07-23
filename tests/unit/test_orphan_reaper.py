"""Tests for the orphaned-server reaper (src/godot_ai/orphan_reaper.py)."""

from __future__ import annotations

import asyncio
import os
import subprocess
import sys

import pytest

from godot_ai import orphan_reaper
from godot_ai.orphan_reaper import (
    DEFAULT_IDLE_GRACE_SECONDS,
    pid_alive,
    should_arm_attach_idle_exit,
    should_arm_idle_exit,
    should_arm_reaper,
    watch_idle,
    watch_owner,
)

POSIX_ONLY_PID_ALIVE = pytest.mark.skipif(
    sys.platform.startswith("win"),
    reason="pid_alive is POSIX-only; orphan reaper is disabled on Windows",
)


def test_should_arm_requires_valid_pid():
    assert should_arm_reaper(None) is False
    assert should_arm_reaper(0) is False
    assert should_arm_reaper(-1) is False


def test_should_arm_true_on_posix(monkeypatch):
    monkeypatch.setattr(orphan_reaper.sys, "platform", "darwin")
    assert should_arm_reaper(1234) is True
    monkeypatch.setattr(orphan_reaper.sys, "platform", "linux")
    assert should_arm_reaper(1234) is True


def test_should_arm_false_on_windows(monkeypatch):
    ## Windows process-control semantics (os.kill == TerminateProcess) make the
    ## POSIX liveness probe destructive; the reaper must stay disabled there.
    monkeypatch.setattr(orphan_reaper.sys, "platform", "win32")
    assert should_arm_reaper(1234) is False


@POSIX_ONLY_PID_ALIVE
def test_pid_alive_for_self():
    assert pid_alive(os.getpid()) is True


def test_pid_alive_false_for_nonpositive():
    assert pid_alive(0) is False
    assert pid_alive(-1) is False


def test_pid_alive_raises_on_windows(monkeypatch):
    ## Must NOT fall through to os.kill on Windows (that would TerminateProcess
    ## the probed pid). The reaper is gated off Windows, so this is unreachable
    ## in practice, but it fails loud rather than mis-probing.
    monkeypatch.setattr(orphan_reaper.sys, "platform", "win32")
    with pytest.raises(NotImplementedError):
        pid_alive(12345)


@POSIX_ONLY_PID_ALIVE
def test_pid_alive_false_for_dead_process():
    proc = subprocess.Popen([sys.executable, "-c", "pass"])
    proc.wait()
    ## Reaped child: pid no longer maps to a live process (modulo immediate
    ## reuse, which an instant check after wait() does not hit in practice).
    assert pid_alive(proc.pid) is False


async def test_reaps_when_owner_dead_and_no_sessions():
    calls: list[bool] = []
    await watch_owner(
        4242,
        lambda: 0,
        poll_seconds=0.005,
        is_alive=lambda _pid: False,
        shutdown=lambda: calls.append(True),
    )
    assert calls == [True]


async def test_no_reap_while_owner_alive():
    calls: list[bool] = []
    task = asyncio.create_task(
        watch_owner(
            4242,
            lambda: 0,
            poll_seconds=0.005,
            is_alive=lambda _pid: True,
            shutdown=lambda: calls.append(True),
        )
    )
    await asyncio.sleep(0.05)  # many poll cycles
    task.cancel()
    with pytest.raises(asyncio.CancelledError):
        await task
    assert calls == []


async def test_no_reap_when_owner_dead_but_adopted():
    ## Owner gone, but another editor holds a live session — must stay up.
    calls: list[bool] = []
    task = asyncio.create_task(
        watch_owner(
            4242,
            lambda: 1,
            poll_seconds=0.005,
            is_alive=lambda _pid: False,
            shutdown=lambda: calls.append(True),
        )
    )
    await asyncio.sleep(0.05)
    task.cancel()
    with pytest.raises(asyncio.CancelledError):
        await task
    assert calls == []


async def test_owner_reaper_honors_live_lease_then_reaps_after_expiry():
    calls: list[bool] = []
    state = {"leases": 1}
    task = asyncio.create_task(
        watch_owner(
            4242,
            lambda: 0,
            lease_count=lambda: state["leases"],
            poll_seconds=0.005,
            is_alive=lambda _pid: False,
            shutdown=lambda: calls.append(True),
        )
    )
    await asyncio.sleep(0.05)
    assert calls == []

    state["leases"] = 0
    await asyncio.wait_for(task, timeout=1)
    assert calls == [True]


async def test_reaps_once_adopter_disconnects():
    ## Sessions present for a few polls, then drop to zero with the owner dead.
    calls: list[bool] = []
    counts = iter([1, 1, 0])

    def session_count() -> int:
        try:
            return next(counts)
        except StopIteration:
            return 0

    await asyncio.wait_for(
        watch_owner(
            4242,
            session_count,
            poll_seconds=0.005,
            is_alive=lambda _pid: False,
            shutdown=lambda: calls.append(True),
        ),
        timeout=2.0,
    )
    assert calls == [True]


async def test_grace_recheck_prevents_reap_on_transient_zero():
    ## Adoption hand-off race: owner is dead, but the adopter's session dips to
    ## zero for one sample (a WebSocket reconnect across a plugin reload) and
    ## then comes back. The grace re-check must NOT reap in that window.
    calls: list[bool] = []
    counts = iter([0])  # first sample: transient zero; thereafter: adopter back

    def session_count() -> int:
        return next(counts, 1)

    task = asyncio.create_task(
        watch_owner(
            4242,
            session_count,
            poll_seconds=0.005,
            is_alive=lambda _pid: False,
            shutdown=lambda: calls.append(True),
        )
    )
    await asyncio.sleep(0.1)  # many poll+grace cycles
    task.cancel()
    with pytest.raises(asyncio.CancelledError):
        await task
    assert calls == [], "must not reap when a transient zero recovers within the grace window"


## ---- Idle self-terminate backstop (#498 / #497) -------------------------


@pytest.fixture
def _clean_idle_env(monkeypatch):
    for name in (
        orphan_reaper.PLUGIN_SPAWNED_ENV,
        orphan_reaper.ATTACH_SPAWNED_ENV,
        orphan_reaper.NO_IDLE_EXIT_ENV,
        orphan_reaper.BOOT_GRACE_ENV,
        orphan_reaper.IDLE_GRACE_ENV,
        "GODOT_AI_DEV_TRANSPORT",
        "GODOT_AI_OWNER_PID",
    ):
        monkeypatch.delenv(name, raising=False)
    return monkeypatch


def test_idle_exit_not_armed_without_marker(_clean_idle_env):
    ## Manual dev servers / CI have neither the marker nor an owner pid — they
    ## must NEVER be idle-killed (#498's hard constraint).
    assert should_arm_idle_exit(None) is False
    assert should_arm_idle_exit(0) is False


def test_idle_exit_armed_by_plugin_spawned_marker(_clean_idle_env):
    _clean_idle_env.setenv(orphan_reaper.PLUGIN_SPAWNED_ENV, "1")
    assert should_arm_idle_exit(None) is True


def test_attach_idle_exit_armed_only_by_attach_marker(_clean_idle_env):
    assert should_arm_attach_idle_exit() is False
    _clean_idle_env.setenv(orphan_reaper.ATTACH_SPAWNED_ENV, "1")
    assert should_arm_attach_idle_exit() is True
    assert should_arm_idle_exit(None) is False


def test_attach_idle_exit_honors_opt_out_and_reload(_clean_idle_env):
    _clean_idle_env.setenv(orphan_reaper.ATTACH_SPAWNED_ENV, "1")
    _clean_idle_env.setenv(orphan_reaper.NO_IDLE_EXIT_ENV, "1")
    assert should_arm_attach_idle_exit() is False
    _clean_idle_env.delenv(orphan_reaper.NO_IDLE_EXIT_ENV)
    _clean_idle_env.setenv("GODOT_AI_DEV_TRANSPORT", "streamable-http")
    assert should_arm_attach_idle_exit() is False


def test_idle_exit_armed_by_owner_pid(_clean_idle_env):
    ## Older plugin builds that predate the marker still plumb an owner pid;
    ## that is proof enough of a plugin spawn.
    assert should_arm_idle_exit(4242) is True


def test_idle_exit_armed_on_windows(_clean_idle_env):
    ## Unlike should_arm_reaper there is NO platform gate — this is the #497
    ## Windows orphan coverage.
    _clean_idle_env.setattr(orphan_reaper.sys, "platform", "win32")
    _clean_idle_env.setenv(orphan_reaper.PLUGIN_SPAWNED_ENV, "1")
    assert should_arm_idle_exit(None) is True


def test_idle_exit_opt_out_disables(_clean_idle_env):
    _clean_idle_env.setenv(orphan_reaper.PLUGIN_SPAWNED_ENV, "1")
    _clean_idle_env.setenv(orphan_reaper.NO_IDLE_EXIT_ENV, "1")
    assert should_arm_idle_exit(4242) is False
    ## Falsey opt-out value does not disable.
    _clean_idle_env.setenv(orphan_reaper.NO_IDLE_EXIT_ENV, "0")
    assert should_arm_idle_exit(4242) is True


def test_idle_exit_disabled_in_reload_mode(_clean_idle_env):
    ## --reload dev runs export GODOT_AI_DEV_TRANSPORT for the uvicorn worker;
    ## an idle reloading server is a dev convenience, not an orphan.
    _clean_idle_env.setenv(orphan_reaper.PLUGIN_SPAWNED_ENV, "1")
    _clean_idle_env.setenv("GODOT_AI_DEV_TRANSPORT", "streamable-http")
    assert should_arm_idle_exit(4242) is False


def test_idle_grace_env_defaults_and_fallbacks(_clean_idle_env):
    assert orphan_reaper.boot_grace_from_env() == DEFAULT_IDLE_GRACE_SECONDS
    assert orphan_reaper.idle_grace_from_env() == DEFAULT_IDLE_GRACE_SECONDS
    _clean_idle_env.setenv(orphan_reaper.BOOT_GRACE_ENV, "7.5")
    _clean_idle_env.setenv(orphan_reaper.IDLE_GRACE_ENV, "9")
    assert orphan_reaper.boot_grace_from_env() == 7.5
    assert orphan_reaper.idle_grace_from_env() == 9.0
    ## Malformed / non-positive values must never become an instant kill.
    _clean_idle_env.setenv(orphan_reaper.BOOT_GRACE_ENV, "banana")
    _clean_idle_env.setenv(orphan_reaper.IDLE_GRACE_ENV, "-3")
    assert orphan_reaper.boot_grace_from_env() == DEFAULT_IDLE_GRACE_SECONDS
    assert orphan_reaper.idle_grace_from_env() == DEFAULT_IDLE_GRACE_SECONDS


class _FakeClock:
    """Monotonic fake advanced by the test, so no real sleeps beyond the
    sub-millisecond asyncio poll ticks."""

    def __init__(self) -> None:
        self.now = 0.0

    def __call__(self) -> float:
        return self.now


async def test_idle_exits_after_boot_grace_with_no_session_ever():
    calls: list[bool] = []
    clock = _FakeClock()

    def session_count() -> int:
        clock.now += 4.0  # each poll "takes" 4s on the fake clock
        return 0

    await asyncio.wait_for(
        watch_idle(
            session_count,
            poll_seconds=0.001,
            boot_grace_seconds=10.0,
            idle_grace_seconds=1000.0,
            clock=clock,
            shutdown=lambda: calls.append(True),
        ),
        timeout=2.0,
    )
    assert calls == [True]
    assert clock.now >= 10.0, "must not exit before the boot grace elapses"


async def test_idle_boot_grace_honored_before_expiry():
    ## Clock advances but stays inside the boot grace — no shutdown.
    calls: list[bool] = []
    clock = _FakeClock()

    def session_count() -> int:
        clock.now = min(clock.now + 1.0, 9.0)  # never reaches the 10s grace
        return 0

    task = asyncio.create_task(
        watch_idle(
            session_count,
            poll_seconds=0.001,
            boot_grace_seconds=10.0,
            idle_grace_seconds=10.0,
            clock=clock,
            shutdown=lambda: calls.append(True),
        )
    )
    await asyncio.sleep(0.05)  # many poll cycles
    task.cancel()
    with pytest.raises(asyncio.CancelledError):
        await task
    assert calls == []


async def test_idle_clock_resets_on_session_connect_and_starts_on_disconnect():
    ## Sessions connected well past the boot grace, then disconnect: the exit
    ## must come one idle grace after the LAST poll that saw a session, not
    ## relative to boot.
    calls: list[bool] = []
    clock = _FakeClock()
    state = {"last_seen": None}

    def auto_advancing_clock() -> float:
        clock.now += 5.0  # each poll "takes" 5s on the fake clock
        return clock.now

    def session_count() -> int:
        if clock.now < 100.0:  # connected far beyond the 10s boot grace
            state["last_seen"] = clock.now
            return 1
        return 0

    await asyncio.wait_for(
        watch_idle(
            session_count,
            poll_seconds=0.001,
            boot_grace_seconds=10.0,
            idle_grace_seconds=30.0,
            clock=auto_advancing_clock,
            shutdown=lambda: calls.append(True),
        ),
        timeout=2.0,
    )
    assert calls == [True]
    ## Connected phase outlived the boot grace many times over without a reap,
    ## and the exit happened only after a full idle grace after the last poll
    ## that observed a session (watch_idle's documented disconnect anchor).
    assert state["last_seen"] is not None
    assert clock.now - state["last_seen"] >= 30.0


async def test_idle_transient_zero_dip_does_not_exit():
    ## Plugin-reload reconnect gap: one zero-session poll inside the grace,
    ## then the session is back. Must not exit.
    calls: list[bool] = []
    clock = _FakeClock()
    counts = iter([1, 1, 0])  # transient dip, then 1 forever

    def session_count() -> int:
        clock.now += 1.0
        return next(counts, 1)

    task = asyncio.create_task(
        watch_idle(
            session_count,
            poll_seconds=0.001,
            boot_grace_seconds=10.0,
            idle_grace_seconds=10.0,
            clock=clock,
            shutdown=lambda: calls.append(True),
        )
    )
    await asyncio.sleep(0.05)
    task.cancel()
    with pytest.raises(asyncio.CancelledError):
        await task
    assert calls == []


async def test_attach_idle_requires_no_sessions_and_no_leases():
    calls: list[bool] = []
    clock = _FakeClock()
    lease_counts = iter([1, 1, 0, 0, 0])

    def advancing_clock() -> float:
        clock.now += 5
        return clock.now

    await asyncio.wait_for(
        watch_idle(
            lambda: 0,
            lease_count=lambda: next(lease_counts, 0),
            poll_seconds=0.001,
            boot_grace_seconds=10,
            idle_grace_seconds=10,
            clock=advancing_clock,
            shutdown=lambda: calls.append(True),
        ),
        timeout=2,
    )

    assert calls == [True]
    assert clock.now >= 20, "active leases must keep resetting the idle window"


async def test_plugin_idle_reaper_honors_live_lease_then_reaps_after_expiry():
    calls: list[bool] = []
    clock = _FakeClock()
    lease_counts = iter([1, 1, 0, 0, 0])

    def advancing_clock() -> float:
        clock.now += 5
        return clock.now

    await asyncio.wait_for(
        watch_idle(
            lambda: 0,
            lease_count=lambda: next(lease_counts, 0),
            poll_seconds=0.001,
            boot_grace_seconds=10,
            idle_grace_seconds=10,
            clock=advancing_clock,
            shutdown=lambda: calls.append(True),
        ),
        timeout=2,
    )

    assert calls == [True]
    assert clock.now >= 20


# ----- pid_alive conservative errno branches (audit backlog) -----


@POSIX_ONLY_PID_ALIVE
def test_pid_alive_true_on_permission_error(monkeypatch):
    """Exists-but-foreign (EPERM) must read as alive — never-wrong-reap."""

    def _raise(_pid, _sig):
        raise PermissionError

    monkeypatch.setattr(orphan_reaper.os, "kill", _raise)
    assert orphan_reaper.pid_alive(12345) is True


@POSIX_ONLY_PID_ALIVE
def test_pid_alive_true_on_unexpected_oserror(monkeypatch):
    """Unknown errno must be conservative (treat as alive), not reap."""
    import errno

    def _raise(_pid, _sig):
        raise OSError(errno.EINVAL, "unexpected")

    monkeypatch.setattr(orphan_reaper.os, "kill", _raise)
    assert orphan_reaper.pid_alive(12345) is True


# ----- _request_self_shutdown (audit backlog: zero coverage) -----


def test_request_self_shutdown_posix_signals_own_pid(monkeypatch):
    monkeypatch.setattr(orphan_reaper.sys, "platform", "linux")
    calls: list[tuple[int, int]] = []
    monkeypatch.setattr(orphan_reaper.os, "kill", lambda pid, sig: calls.append((pid, sig)))
    orphan_reaper._request_self_shutdown()
    import signal as _signal

    assert calls == [(os.getpid(), _signal.SIGTERM)]


def test_request_self_shutdown_windows_raises_signal_in_process(monkeypatch):
    """Windows must use raise_signal (graceful in-process handler), never
    os.kill, which is TerminateProcess there and skips lifespan teardown."""
    monkeypatch.setattr(orphan_reaper.sys, "platform", "win32")
    raised: list[int] = []
    monkeypatch.setattr(orphan_reaper.signal, "raise_signal", lambda sig: raised.append(sig))

    def _forbidden(*_a):
        raise AssertionError("os.kill must not be used on Windows")

    monkeypatch.setattr(orphan_reaper.os, "kill", _forbidden)
    orphan_reaper._request_self_shutdown()
    import signal as _signal

    assert raised == [_signal.SIGTERM]

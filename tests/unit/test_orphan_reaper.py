"""Tests for the orphaned-server reaper (src/godot_ai/orphan_reaper.py)."""

from __future__ import annotations

import asyncio
import os
import subprocess
import sys

import pytest

from godot_ai import orphan_reaper
from godot_ai.orphan_reaper import pid_alive, should_arm_reaper, watch_owner

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

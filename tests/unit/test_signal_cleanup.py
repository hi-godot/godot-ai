"""Signal ownership and exception preservation at the synchronous HTTP boundary."""
from __future__ import annotations

import signal
import threading
from types import SimpleNamespace

import pytest

from godot_ai import _signals
from godot_ai._signals import unwind_before_sigterm


@pytest.fixture
def handlers(monkeypatch):
    monkeypatch.setattr(_signals, "os", SimpleNamespace(name="posix"))
    state = {"handler": signal.SIG_DFL, "replayed": []}
    monkeypatch.setattr(signal, "getsignal", lambda _sig: state["handler"])

    def install(_sig, handler):
        previous = state["handler"]
        state["handler"] = handler
        return previous

    def replay(sig):
        state["replayed"].append((sig, state["handler"]))

    monkeypatch.setattr(signal, "signal", install)
    monkeypatch.setattr(signal, "raise_signal", replay)
    return state


def test_sigterm_unwinds_before_restoring_and_replaying(handlers):
    order = []
    with unwind_before_sigterm():
        try:
            handlers["handler"](signal.SIGTERM, None)
        finally:
            order.append("cleanup")
            assert handlers["replayed"] == []
    assert order == ["cleanup"]
    assert handlers["handler"] == signal.SIG_DFL
    assert handlers["replayed"] == [(signal.SIGTERM, signal.SIG_DFL)]


def test_normal_exit_restores_without_replay(handlers):
    with unwind_before_sigterm():
        assert callable(handlers["handler"])
    assert handlers["handler"] == signal.SIG_DFL
    assert handlers["replayed"] == []


def test_unrelated_startup_error_is_not_replaced(handlers):
    failure = RuntimeError("startup failed")
    with pytest.raises(RuntimeError) as caught, unwind_before_sigterm():
        raise failure
    assert caught.value is failure
    assert handlers["handler"] == signal.SIG_DFL
    assert handlers["replayed"] == []


def test_cleanup_error_is_not_replaced_with_sigterm(handlers):
    failure = RuntimeError("cleanup failed")
    with pytest.raises(RuntimeError) as caught, unwind_before_sigterm():
        try:
            handlers["handler"](signal.SIGTERM, None)
        finally:
            raise failure
    assert caught.value is failure
    assert handlers["handler"] == signal.SIG_DFL
    assert handlers["replayed"] == []


@pytest.mark.parametrize("original", [signal.SIG_IGN, lambda _sig, _frame: None])
def test_caller_sigterm_disposition_is_untouched(handlers, original):
    handlers["handler"] = original
    with unwind_before_sigterm():
        assert handlers["handler"] is original
    assert handlers["handler"] is original
    assert handlers["replayed"] == []


def test_non_main_thread_never_installs_signal_handler(handlers, monkeypatch):
    monkeypatch.setattr(threading, "current_thread", lambda: object())
    with unwind_before_sigterm():
        assert handlers["handler"] == signal.SIG_DFL
    assert handlers["replayed"] == []


def test_nested_guard_does_not_replace_outer_owner(handlers):
    with unwind_before_sigterm():
        outer = handlers["handler"]
        with unwind_before_sigterm():
            assert handlers["handler"] is outer
    assert handlers["handler"] == signal.SIG_DFL
    assert handlers["replayed"] == []

def test_non_posix_runner_is_unchanged(handlers, monkeypatch):
    monkeypatch.setattr(_signals, "os", SimpleNamespace(name="nt"))
    with unwind_before_sigterm():
        assert handlers["handler"] == signal.SIG_DFL
    assert handlers["replayed"] == []


def test_first_signal_restores_default_before_cleanup(handlers):
    with unwind_before_sigterm():
        try:
            handlers["handler"](signal.SIGTERM, None)
        finally:
            assert handlers["handler"] == signal.SIG_DFL


def test_keyboard_interrupt_is_not_consumed(handlers):
    failure = KeyboardInterrupt()
    with pytest.raises(KeyboardInterrupt) as caught, unwind_before_sigterm():
        raise failure
    assert caught.value is failure
    assert handlers["handler"] == signal.SIG_DFL
    assert handlers["replayed"] == []

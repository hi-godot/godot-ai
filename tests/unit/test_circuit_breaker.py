"""Unit tests for EditorBridgeCircuitBreaker (F-006 death-spiral guard)."""

from __future__ import annotations

import pytest

from godot_ai.godot_client.circuit_breaker import EditorBridgeCircuitBreaker


class _FakeClock:
    """Deterministic monotonic clock for circuit-breaker timing tests."""

    def __init__(self, start: float = 1000.0):
        self.now = start

    def __call__(self) -> float:
        return self.now

    def advance(self, seconds: float) -> None:
        self.now += seconds


@pytest.fixture
def clock() -> _FakeClock:
    return _FakeClock()


@pytest.fixture
def cb(clock: _FakeClock) -> EditorBridgeCircuitBreaker:
    return EditorBridgeCircuitBreaker(
        threshold=5,
        initial_open_ms=1000,
        max_open_ms=30_000,
        time_fn=clock,
    )


class TestThresholdAndOpen:
    def test_closed_when_no_failures(self, cb: EditorBridgeCircuitBreaker) -> None:
        assert cb.check_open("sess-a") is None
        assert cb.snapshot("sess-a") == {"consecutive_failures": 0, "circuit_open": False}

    def test_does_not_open_before_threshold(self, cb: EditorBridgeCircuitBreaker) -> None:
        for _ in range(4):
            opened = cb.record_failure("sess-a", kind="TimeoutError")
            assert opened is False
        assert cb.check_open("sess-a") is None
        assert cb.snapshot("sess-a")["circuit_open"] is False

    def test_opens_on_threshold_failure(self, cb: EditorBridgeCircuitBreaker) -> None:
        for _ in range(4):
            cb.record_failure("sess-a", kind="TimeoutError")
        ## 5th failure trips the breaker.
        opened = cb.record_failure("sess-a", kind="TimeoutError")
        assert opened is True
        remaining = cb.check_open("sess-a")
        assert remaining is not None
        assert 900 <= remaining <= 1000  # ~1000ms window

    def test_check_open_returns_none_after_window_elapses(
        self, cb: EditorBridgeCircuitBreaker, clock: _FakeClock
    ) -> None:
        for _ in range(5):
            cb.record_failure("sess-a", kind="TimeoutError")
        assert cb.check_open("sess-a") is not None
        clock.advance(1.5)
        assert cb.check_open("sess-a") is None


class TestRecovery:
    def test_success_resets_count_and_circuit(
        self, cb: EditorBridgeCircuitBreaker, clock: _FakeClock
    ) -> None:
        for _ in range(5):
            cb.record_failure("sess-a", kind="TimeoutError")
        clock.advance(1.5)  # let the window elapse
        cb.record_success("sess-a")
        ## After success, the count starts fresh — five more failures
        ## are needed to re-open.
        for _ in range(4):
            assert cb.record_failure("sess-a", kind="TimeoutError") is False
        assert cb.check_open("sess-a") is None
        assert cb.record_failure("sess-a", kind="TimeoutError") is True

    def test_success_on_a_real_session_clears_no_session_circuit(
        self, cb: EditorBridgeCircuitBreaker
    ) -> None:
        ## The death-spiral source #1 is "no active session" hammering.
        ## Once a real session comes up and serves a call, the global
        ## no-session circuit should also clear.
        for _ in range(5):
            cb.record_failure(None, kind="no_active_session")
        assert cb.check_open(None) is not None
        cb.record_success("sess-a")
        assert cb.check_open(None) is None


class TestEscalation:
    def test_backoff_doubles_on_reopen(
        self, cb: EditorBridgeCircuitBreaker, clock: _FakeClock
    ) -> None:
        for _ in range(5):
            cb.record_failure("sess-a", kind="TimeoutError")
        first = cb.check_open("sess-a")
        assert first is not None and 900 <= first <= 1000

        clock.advance(1.5)
        ## Single extra failure while count is above threshold immediately
        ## triggers another open with doubled window.
        opened_again = cb.record_failure("sess-a", kind="TimeoutError")
        assert opened_again is True
        second = cb.check_open("sess-a")
        assert second is not None and 1900 <= second <= 2000

    def test_backoff_caps_at_max(self, clock: _FakeClock) -> None:
        cb = EditorBridgeCircuitBreaker(
            threshold=1, initial_open_ms=10_000, max_open_ms=15_000, time_fn=clock
        )
        cb.record_failure("sess-a", kind="TimeoutError")
        assert cb.check_open("sess-a") == pytest.approx(10_000, abs=20)
        clock.advance(11.0)
        cb.record_failure("sess-a", kind="TimeoutError")
        ## next_open_ms would be 20_000 but is clamped to 15_000.
        capped = cb.check_open("sess-a")
        assert capped is not None and 14_000 <= capped <= 15_000


class TestPerSessionIsolation:
    def test_sessions_track_independently(self, cb: EditorBridgeCircuitBreaker) -> None:
        for _ in range(5):
            cb.record_failure("sess-a", kind="TimeoutError")
        ## sess-b is unaffected.
        assert cb.check_open("sess-b") is None
        cb.record_success("sess-b")
        ## And sess-a's open state survives sess-b's reset.
        assert cb.check_open("sess-a") is not None

    def test_no_session_key_isolated_from_real_sessions(
        self, cb: EditorBridgeCircuitBreaker
    ) -> None:
        for _ in range(5):
            cb.record_failure(None, kind="no_active_session")
        assert cb.check_open(None) is not None
        assert cb.check_open("sess-a") is None


class TestSnapshot:
    def test_snapshot_includes_failure_kind(self, cb: EditorBridgeCircuitBreaker) -> None:
        cb.record_failure("sess-a", kind="TimeoutError")
        snap = cb.snapshot("sess-a")
        assert snap["consecutive_failures"] == 1
        assert snap["circuit_open"] is False
        assert snap["last_failure_kind"] == "TimeoutError"

    def test_snapshot_with_kind_overwritten(self, cb: EditorBridgeCircuitBreaker) -> None:
        cb.record_failure("sess-a", kind="TimeoutError")
        cb.record_failure("sess-a", kind="ConnectionError")
        assert cb.snapshot("sess-a")["last_failure_kind"] == "ConnectionError"

    def test_snapshot_reflects_open_state(
        self, cb: EditorBridgeCircuitBreaker, clock: _FakeClock
    ) -> None:
        for _ in range(5):
            cb.record_failure("sess-a", kind="TimeoutError")
        assert cb.snapshot("sess-a")["circuit_open"] is True
        clock.advance(1.5)
        assert cb.snapshot("sess-a")["circuit_open"] is False


class TestValidation:
    def test_threshold_must_be_at_least_one(self) -> None:
        with pytest.raises(ValueError, match="threshold"):
            EditorBridgeCircuitBreaker(threshold=0)

    def test_initial_open_must_be_positive(self) -> None:
        with pytest.raises(ValueError, match="initial_open_ms"):
            EditorBridgeCircuitBreaker(initial_open_ms=0)

    def test_max_must_be_at_least_initial(self) -> None:
        with pytest.raises(ValueError, match="max_open_ms"):
            EditorBridgeCircuitBreaker(initial_open_ms=2000, max_open_ms=1000)

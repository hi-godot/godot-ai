"""Per-session circuit breaker for editor-bridge transport failures.

Background — F-006 (telemetry-driven). When the WebSocket bridge to a
Godot editor goes unresponsive (editor crashed, plugin reload mid-flight,
network hiccup), tool calls fail with ``TimeoutError`` (~5–120s) or
``ConnectionError`` (~0ms). LLM clients with no built-in backoff
hot-retry these, generating death-spirals — one observed install
sustained ~200 errors/min for 7 minutes (≈1,400 failures) with no
self-correction.

This module's job is to give those clients a clear "back off" signal.
After ``threshold`` consecutive transport failures on a given session,
the breaker opens for an exponentially-growing window. While open,
``check_open`` returns the remaining backoff in milliseconds; the
caller short-circuits with a structured ``PLUGIN_DISCONNECTED`` error
carrying ``retry_after_ms`` so the next would-be hot-retry is instead
told exactly when to try again.

State persists across reconnects intentionally — a flapping editor
that briefly returns only to fail again should escalate the backoff,
not reset it. The canonical reset signal is a *successful* command
call; that's the only thing that proves the bridge actually works.

Threading: all callers run on the single asyncio event loop driving
the WS transport, so the dict is mutated without locking (same model
as ``SessionRegistry``).
"""

from __future__ import annotations

import time
from dataclasses import dataclass
from typing import Callable

## Sentinel key for the "no active session" failure path — the LLM is
## hammering without a session at all (death-spiral source #1 in the
## F-006 finding). Tracked independently from per-session circuits so a
## working session B can't be poisoned by a hammering no-session client.
_NO_SESSION_KEY = "__no_session__"


@dataclass
class _CircuitState:
    consecutive_failures: int = 0
    open_until_monotonic: float = 0.0
    next_open_ms: int = 0  # filled in by tracker on first use
    last_failure_kind: str = ""


class EditorBridgeCircuitBreaker:
    """Per-session circuit breaker for editor-bridge transport failures.

    Defaults (5 failures → 1s..30s exponential) chosen so a single
    transient blip (one timeout) never trips the breaker, but a
    sustained hot-retry storm is short-circuited well before it can
    saturate the dashboard.
    """

    def __init__(
        self,
        threshold: int = 5,
        initial_open_ms: int = 1000,
        max_open_ms: int = 30_000,
        *,
        time_fn: Callable[[], float] | None = None,
    ):
        if threshold < 1:
            raise ValueError("threshold must be >= 1")
        if initial_open_ms <= 0:
            raise ValueError("initial_open_ms must be > 0")
        if max_open_ms < initial_open_ms:
            raise ValueError("max_open_ms must be >= initial_open_ms")
        self._threshold = threshold
        self._initial_open_ms = initial_open_ms
        self._max_open_ms = max_open_ms
        self._time = time_fn or time.monotonic
        self._states: dict[str, _CircuitState] = {}

    @staticmethod
    def _key(session_id: str | None) -> str:
        return session_id if session_id else _NO_SESSION_KEY

    def _state(self, session_id: str | None) -> _CircuitState:
        key = self._key(session_id)
        state = self._states.get(key)
        if state is None:
            state = _CircuitState(next_open_ms=self._initial_open_ms)
            self._states[key] = state
        return state

    def check_open(self, session_id: str | None) -> int | None:
        """If the circuit is open for ``session_id``, return remaining ms.

        Returns ``None`` if the circuit is closed (either never opened
        or the open window has elapsed). The returned ms count is the
        ``retry_after_ms`` hint to surface to the caller.
        """
        state = self._states.get(self._key(session_id))
        if state is None or state.open_until_monotonic == 0.0:
            return None
        now = self._time()
        if now >= state.open_until_monotonic:
            return None
        return max(1, int((state.open_until_monotonic - now) * 1000))

    def record_failure(
        self,
        session_id: str | None,
        *,
        kind: str = "",
    ) -> bool:
        """Record a transport failure. Returns True if this call opened the circuit.

        ``kind`` is a short tag for the failure category (e.g.
        ``"TimeoutError"``, ``"no_session"``) used for diagnostic
        payloads only — never user input, so no sanitization needed.
        """
        state = self._state(session_id)
        state.consecutive_failures += 1
        if kind:
            state.last_failure_kind = kind
        if state.consecutive_failures < self._threshold:
            return False
        was_open = state.open_until_monotonic > self._time()
        state.open_until_monotonic = self._time() + state.next_open_ms / 1000.0
        state.next_open_ms = min(state.next_open_ms * 2, self._max_open_ms)
        return not was_open

    def record_success(self, session_id: str | None) -> None:
        """A successful command — the bridge works. Reset state.

        Also clears the ``_NO_SESSION_KEY`` state, because a successful
        per-session call proves there IS an active session, fixing the
        condition the no-session circuit was guarding against.
        """
        self._states.pop(self._key(session_id), None)
        if session_id:
            self._states.pop(_NO_SESSION_KEY, None)

    def snapshot(self, session_id: str | None) -> dict[str, int | bool | str]:
        """Diagnostic snapshot for inclusion in error payloads."""
        state = self._states.get(self._key(session_id))
        if state is None:
            return {"consecutive_failures": 0, "circuit_open": False}
        is_open = state.open_until_monotonic > self._time()
        snap: dict[str, int | bool | str] = {
            "consecutive_failures": state.consecutive_failures,
            "circuit_open": is_open,
        }
        if state.last_failure_kind:
            snap["last_failure_kind"] = state.last_failure_kind
        return snap

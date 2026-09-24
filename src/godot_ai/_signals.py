"""Keep default POSIX termination outside the HTTP runner's lifespan teardown."""
from __future__ import annotations

import os
import signal
import threading
from collections.abc import Iterator
from contextlib import contextmanager
from types import FrameType


class _SigtermUnwind(BaseException):
    pass


@contextmanager
def unwind_before_sigterm() -> Iterator[None]:
    if (
        os.name != "posix"
        or threading.current_thread() is not threading.main_thread()
        or signal.getsignal(signal.SIGTERM) != signal.SIG_DFL
    ):
        yield
        return

    def terminate(_signal: int, _frame: FrameType | None) -> None:
        # A second SIGTERM can still force termination during cleanup.
        signal.signal(signal.SIGTERM, signal.SIG_DFL)
        raise _SigtermUnwind

    original = signal.signal(signal.SIGTERM, terminate)
    try:
        try:
            yield
        except _SigtermUnwind:
            pass
        else:
            return
    finally:
        signal.signal(signal.SIGTERM, original)
    # Uvicorn replays SIGTERM before FastMCP's outer lifespan exits. Unwind
    # that lifespan first, then preserve the original signal exit status.
    signal.raise_signal(signal.SIGTERM)

"""GodotWebSocketServer.start() port-bind error handling."""

from __future__ import annotations

import asyncio
import errno
import logging
from contextlib import asynccontextmanager
from unittest.mock import patch

import pytest

from godot_ai.sessions.registry import SessionRegistry
from godot_ai.transport.websocket import GodotWebSocketServer


def _make_server() -> GodotWebSocketServer:
    return GodotWebSocketServer(SessionRegistry(), port=19999)


def _serve_raising(errno_value: int):
    @asynccontextmanager
    async def _cm(*_args, **_kwargs):
        raise OSError(errno_value, "fake bind failure")
        yield  # pragma: no cover - unreachable

    return _cm


async def test_start_swallows_address_in_use(caplog: pytest.LogCaptureFixture) -> None:
    caplog.set_level(logging.WARNING)
    with patch(
        "godot_ai.transport.websocket.websockets.serve",
        _serve_raising(errno.EADDRINUSE),
    ):
        await asyncio.wait_for(_make_server().start(), timeout=1.0)

    assert any("already in use" in r.getMessage() for r in caplog.records)


async def test_start_propagates_other_oserrors() -> None:
    with patch(
        "godot_ai.transport.websocket.websockets.serve",
        _serve_raising(errno.EACCES),
    ):
        with pytest.raises(OSError) as exc_info:
            await asyncio.wait_for(_make_server().start(), timeout=1.0)

    assert exc_info.value.errno == errno.EACCES

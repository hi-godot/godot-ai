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
        yield  # pragma: no cover

    return _cm


## Python tests run on Ubuntu only in CI, so a host-native check would let
## a re-hardcoded `errno == <single platform value>` regression escape on
## the other two OSes. Patching the production-side EADDRINUSE alongside
## the simulated OSError exercises every platform from one runner — any
## single-value hardcode fails ≥2 of these rows.
@pytest.mark.parametrize(
    "platform_errno",
    [
        pytest.param(48, id="macOS"),
        pytest.param(98, id="Linux"),
        pytest.param(10048, id="Windows"),
    ],
)
async def test_start_swallows_address_in_use_per_platform(
    platform_errno: int, caplog: pytest.LogCaptureFixture
) -> None:
    caplog.set_level(logging.WARNING)
    with (
        patch("godot_ai.transport.websocket.errno.EADDRINUSE", platform_errno),
        patch(
            "godot_ai.transport.websocket.websockets.serve",
            _serve_raising(platform_errno),
        ),
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
